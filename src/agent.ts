// Glass Agent: Claude vision + tool use over our company data.
// The job's customer context is preloaded so most answers need a single round trip;
// tools cover anything beyond that (parts catalog, other history lookups).

import Anthropic from "@anthropic-ai/sdk";
import type { DataStore, Equipment, HistoryEntry, Job } from "./data.ts";
import { log } from "./log.ts";

export const MODEL = "claude-opus-5-5";
const REQUEST_TIMEOUT_MS = 20_000;
const ASK_DEADLINE_MS = 35_000;
const MAX_TURNS = 4;

export const FALLBACK_ANSWER =
  "Sorry, I can't reach the assistant right now. Give it a few seconds and ask again.";

export type ImageMediaType = "image/jpeg" | "image/png" | "image/webp" | "image/gif";

export interface AskResult {
  answer: string;
  equipment_id: string | null;
  suspected_issue: string | null;
  recommended_skus: string[];
  fallback: boolean;
}

let client: Anthropic | null = null;
export function getClient(): Anthropic {
  client ??= new Anthropic({ timeout: REQUEST_TIMEOUT_MS, maxRetries: 1 });
  return client;
}

const SYSTEM = `You are Glass Agent, the voice copilot for technicians at Northside Coffee Service, a company that installs and services coffee equipment in offices.

The technician wears smart glasses with a camera but no display. Your answer is read aloud through the glasses speakers, so write for listening:
- At most three short sentences. No lists, markdown, SKUs, or serial numbers.
- Say dates naturally ("back in March"), and name parts in plain words ("a descaling kit").
- Lead with the most useful thing: what this machine is, what is likely wrong, and what to do.

How to answer:
- Identify the machine in the photo and match it to the customer's installed equipment listed in the job context (by make, model, and look). Mention that you recognise it as their machine.
- Ground the diagnosis in our service history and the maintenance status we computed, for example a descale or water filter that is overdue. This company knowledge is the point; generic advice alone is not enough.
- If the photo does not match any installed equipment, or no photo was sent, say so briefly and answer from the history.
- Use the tools only when the provided context is not enough, for example to check which parts fit and what they cost.

Reply with JSON matching the schema: "answer" is the spoken reply; "equipment_id" is the matched equipment id or "" if none; "suspected_issue" is a few words or ""; "recommended_skus" lists catalog SKUs the tech will likely need (can be empty).`;

const OUTPUT_SCHEMA = {
  type: "object",
  properties: {
    answer: { type: "string" },
    equipment_id: { type: "string" },
    suspected_issue: { type: "string" },
    recommended_skus: { type: "array", items: { type: "string" } },
  },
  required: ["answer", "equipment_id", "suspected_issue", "recommended_skus"],
  additionalProperties: false,
} as const;

const TOOLS: Anthropic.Beta.BetaTool[] = [
  {
    name: "get_customer_history",
    description: "Past service jobs for the current customer, optionally limited to one piece of equipment. Returns date, issue, fix, and parts used.",
    input_schema: {
      type: "object",
      properties: { equipment_id: { type: "string", description: "Limit to this equipment id. Omit for all of the customer's equipment." } },
      additionalProperties: false,
    },
  },
  {
    name: "get_equipment",
    description: "All equipment installed at the current customer: id, make, model, type, location, serial, install date, service intervals.",
    input_schema: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "search_parts_catalog",
    description: "Search Northside's parts and services catalog. Returns SKU, name, and price. Pass equipment_id to only get parts compatible with that machine.",
    input_schema: {
      type: "object",
      properties: {
        query: { type: "string", description: "Words to match in the part name or SKU, e.g. 'filter' or 'brew group'. Empty returns all." },
        equipment_id: { type: "string" },
      },
      additionalProperties: false,
    },
  },
];

// --- context ---------------------------------------------------------------

function addMonths(date: string, months: number): string {
  const d = new Date(`${date}T00:00:00Z`);
  d.setUTCMonth(d.getUTCMonth() + months);
  return d.toISOString().slice(0, 10);
}

function maintenanceStatus(e: Equipment, history: HistoryEntry[], today: string) {
  const mine = history.filter((h) => h.equipment_id === e.id);
  const lastWith = (match: (sku: string) => boolean) =>
    mine.filter((h) => h.parts_used.some(match)).at(-1)?.date ?? null;
  const item = (last: string | null, months?: number) => {
    if (!months) return undefined;
    const since = last ?? e.installed;
    const due = addMonths(since, months);
    return { last_done: last, interval_months: months, due, overdue: today > due };
  };
  return {
    descale: item(lastWith((s) => s.startsWith("DSC-")), e.descale_interval_months),
    water_filter: item(lastWith((s) => s.startsWith("WF-")), e.water_filter_interval_months),
  };
}

async function buildContext(db: DataStore, job: Job): Promise<string> {
  const today = new Date().toISOString().slice(0, 10);
  const customer = await db.getCustomer(job.customer_id);
  const equipment = await db.getEquipment(job.customer_id);
  const history = await db.getJobHistory({ customerId: job.customer_id });
  const ctx = {
    today,
    customer,
    equipment: equipment.map((e) => ({
      id: e.id, make: e.make, model: e.model, type: e.type, location: e.location,
      installed: e.installed, maintenance: maintenanceStatus(e, history, today),
    })),
    service_history: history.map(({ id, customer_id, ...h }) => h),
    earlier_questions_this_visit: job.notes.map((n) => ({ question: n.question, answer: n.answer })),
  };
  return JSON.stringify(ctx, null, 1);
}

// --- tools -----------------------------------------------------------------

async function runTool(db: DataStore, job: Job, name: string, input: any): Promise<string> {
  const equipment = await db.getEquipment(job.customer_id);
  switch (name) {
    case "get_customer_history":
      return JSON.stringify(await db.getJobHistory({ customerId: job.customer_id, equipmentId: input?.equipment_id || undefined }));
    case "get_equipment":
      return JSON.stringify(equipment);
    case "search_parts_catalog": {
      const eq = equipment.find((e) => e.id === input?.equipment_id);
      const parts = await db.searchParts({ query: input?.query, modelKey: eq?.model_key });
      return JSON.stringify(parts.map(({ sku, name, price }) => ({ sku, name, price })));
    }
    default:
      throw new Error(`unknown tool ${name}`);
  }
}

// --- main entry ------------------------------------------------------------

export async function ask(
  db: DataStore,
  job: Job,
  question: string,
  photo: { data: Buffer; mediaType: ImageMediaType } | null,
  reqId: string,
): Promise<AskResult> {
  const fallback = (why: string): AskResult => {
    log("ask.fallback", { reqId, why });
    return { answer: FALLBACK_ANSWER, equipment_id: null, suspected_issue: null, recommended_skus: [], fallback: true };
  };

  const content: Anthropic.Beta.BetaContentBlockParam[] = [
    { type: "text", text: `Job context:\n${await buildContext(db, job)}` },
  ];
  if (photo) {
    content.push({ type: "image", source: { type: "base64", media_type: photo.mediaType, data: photo.data.toString("base64") } });
  }
  content.push({ type: "text", text: `Technician asks: ${question || "What is this and is anything wrong with it?"}` });
  const messages: Anthropic.Beta.BetaMessageParam[] = [{ role: "user", content }];

  const signal = AbortSignal.timeout(ASK_DEADLINE_MS);
  const started = Date.now();

  try {
    for (let turn = 1; turn <= MAX_TURNS; turn++) {
      const res = await getClient().beta.messages.create(
        {
          model: MODEL,
          max_tokens: 4000,
          system: SYSTEM,
          tools: TOOLS,
          messages,
          output_config: { effort: "low", format: { type: "json_schema", schema: OUTPUT_SCHEMA } },
          betas: ["server-side-fallback-2026-07-01"],
          fallbacks: "default",
        },
        { signal },
      );
      log("claude.response", {
        reqId, turn, model: res.model, stop: res.stop_reason, ms: Date.now() - started,
        in: res.usage.input_tokens, out: res.usage.output_tokens,
      });

      if (res.stop_reason === "refusal") return fallback("refusal");

      if (res.stop_reason === "tool_use") {
        messages.push({ role: "assistant", content: res.content });
        const results: Anthropic.Beta.BetaToolResultBlockParam[] = [];
        for (const block of res.content) {
          if (block.type !== "tool_use") continue;
          try {
            const out = await runTool(db, job, block.name, block.input);
            log("tool.call", { reqId, tool: block.name, input: block.input, bytes: out.length });
            results.push({ type: "tool_result", tool_use_id: block.id, content: out });
          } catch (err: any) {
            log("tool.error", { reqId, tool: block.name, error: err.message });
            results.push({ type: "tool_result", tool_use_id: block.id, content: err.message, is_error: true });
          }
        }
        messages.push({ role: "user", content: results });
        continue;
      }

      const text = res.content.flatMap((b) => (b.type === "text" ? [b.text] : [])).join("").trim();
      if (!text) return fallback(`empty response (${res.stop_reason})`);
      return parseResult(text);
    }
    return fallback("too many tool turns");
  } catch (err) {
    if (err instanceof Anthropic.AuthenticationError) return fallback("invalid ANTHROPIC_API_KEY");
    if (err instanceof Anthropic.RateLimitError) return fallback("rate limited");
    if (err instanceof Anthropic.APIConnectionTimeoutError) return fallback("timeout");
    if (err instanceof Anthropic.APIUserAbortError) return fallback(`deadline ${ASK_DEADLINE_MS}ms exceeded`);
    if (err instanceof Anthropic.APIError) return fallback(`API ${err.status}: ${err.message}`);
    return fallback(`unexpected: ${(err as Error).message}`);
  }
}

function parseResult(text: string): AskResult {
  try {
    const j = JSON.parse(text);
    return {
      answer: String(j.answer ?? "").trim() || FALLBACK_ANSWER,
      equipment_id: j.equipment_id || null,
      suspected_issue: j.suspected_issue || null,
      recommended_skus: Array.isArray(j.recommended_skus) ? j.recommended_skus.map(String) : [],
      fallback: false,
    };
  } catch {
    // Not JSON: still speak whatever Claude said.
    return { answer: text, equipment_id: null, suspected_issue: null, recommended_skus: [], fallback: false };
  }
}
