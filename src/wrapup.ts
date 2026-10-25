// Wrap-up: turn the tech's spoken summary ("descaling kit, new filter, half an hour of labor")
// into catalog line items with Claude, then price, log, and close the job deterministically.
// If Claude is unavailable, a keyword parser takes over so wrap-up never blocks the demo.

import Anthropic from "@anthropic-ai/sdk";
import type { DataStore, Job, JobLine, Part } from "./data.ts";
import { getClient, MODEL } from "./agent.ts";
import { log } from "./log.ts";
import { launchBackOffice } from "./omnara.ts";

const WRAPUP_DEADLINE_MS = 25_000;

export interface Report {
  job_id: string;
  date: string;
  customer: { company: string; contact_name: string; email: string; address: string };
  equipment: { make: string; model: string; location: string; serial: string } | null;
  issue: string;
  fix: string;
  lines: (JobLine & { amount: number })[];
  labor: { hours: number; rate: number; amount: number };
  total: number;
}

interface Parsed {
  items: { sku: string; qty: number }[];
  labor_hours: number;
  fix_summary: string;
}

const SCHEMA = {
  type: "object",
  properties: {
    items: {
      type: "array",
      items: {
        type: "object",
        properties: { sku: { type: "string" }, qty: { type: "integer" } },
        required: ["sku", "qty"],
        additionalProperties: false,
      },
    },
    labor_hours: { type: "number" },
    fix_summary: { type: "string" },
  },
  required: ["items", "labor_hours", "fix_summary"],
  additionalProperties: false,
} as const;

async function parseWithClaude(summary: string, job: Job, parts: Part[], reqId: string): Promise<Parsed | null> {
  const prompt = `A coffee equipment technician is wrapping up a service job and said:
"${summary}"

Map what they used to SKUs from this catalog (only these SKUs; qty defaults to 1):
${JSON.stringify(parts.map(({ sku, name, price }) => ({ sku, name, price })))}

Issue diagnosed earlier this visit: ${job.issue || "unknown"}
Questions and answers this visit: ${JSON.stringify(job.notes.map(({ question, answer }) => ({ question, answer })))}

Return labor_hours as a number ("half an hour" is 0.5; 0 if not mentioned) and a one-sentence fix_summary in past tense for the job log, e.g. "Descaled the machine and replaced the water filter."`;

  const started = Date.now();
  try {
    const res = await getClient().beta.messages.create(
      {
        model: MODEL,
        max_tokens: 2000,
        messages: [{ role: "user", content: prompt }],
        output_config: { effort: "low", format: { type: "json_schema", schema: SCHEMA } },
        betas: ["server-side-fallback-2026-07-01"],
        fallbacks: "default",
      },
      { signal: AbortSignal.timeout(WRAPUP_DEADLINE_MS) },
    );
    log("claude.response", { reqId, kind: "wrapup", stop: res.stop_reason, ms: Date.now() - started, in: res.usage.input_tokens, out: res.usage.output_tokens });
    if (res.stop_reason === "refusal") return null;
    const text = res.content.flatMap((b) => (b.type === "text" ? [b.text] : [])).join("");
    return JSON.parse(text) as Parsed;
  } catch (err) {
    const why = err instanceof Anthropic.APIError ? `API ${err.status ?? ""} ${err.message}` : (err as Error).message;
    log("wrapup.claude_failed", { reqId, why, ms: Date.now() - started });
    return null;
  }
}

// Fallback: keyword match against the catalog plus simple labor phrases.
const KEYWORDS: [RegExp, string][] = [
  [/descal/, "DSC-"], [/filter/, "WF-"], [/brew ?group/, "BRW-GRP"], [/burr|grinder/, "BURR-"],
  [/gasket|o-?ring|seal/, "GSK-"], [/milk.*clean|clean.*milk/, "MLK-"], [/frother|wand/, "FRTH-"],
  [/pump/, "PUMP-"], [/drip ?tray/, "DRIP-"], [/spray ?head/, "SPRAY-"], [/maintenance|pm visit/, "SVC-PM"],
];

export function parseLocally(summary: string, parts: Part[]): Parsed {
  const s = summary.toLowerCase();
  const items: Parsed["items"] = [];
  for (const [re, prefix] of KEYWORDS) {
    const part = re.test(s) && parts.find((p) => p.sku.startsWith(prefix));
    if (part && !items.some((i) => i.sku === part.sku)) items.push({ sku: part.sku, qty: 1 });
  }
  let hours = 0;
  const num = s.match(/(\d+(?:\.\d+)?)\s*(hours?|hrs?|h\b)/);
  const min = s.match(/(\d+)\s*(minutes?|mins?)/);
  if (/hour and a half|one and a half hours?|1\.5 hours?/.test(s)) hours = 1.5;
  else if (num) hours = Number(num[1]);
  else if (min) hours = Number(min[1]) / 60;
  else if (/half (an )?hour/.test(s)) hours = 0.5;
  else if (/quarter (of an )?hour/.test(s)) hours = 0.25;
  else if (/\ban hour\b|one hour/.test(s)) hours = 1;
  const names = items.map((i) => parts.find((p) => p.sku === i.sku)!.name.toLowerCase());
  return { items, labor_hours: hours, fix_summary: names.length ? `Serviced the machine: ${names.join(", ")}.` : "Serviced the machine." };
}

function money(n: number): number {
  return Math.round(n * 100) / 100;
}

export function buildReport(job: Job, customer: Report["customer"], equipment: Report["equipment"]): Report {
  const lines = job.parts.map((l) => ({ ...l, amount: money(l.qty * l.unit_price) }));
  const labor = { hours: job.labor_hours, rate: job.labor_rate, amount: money(job.labor_hours * job.labor_rate) };
  return {
    job_id: job.id,
    date: (job.completed_at ?? job.started_at).slice(0, 10),
    customer: { company: customer.company, contact_name: customer.contact_name, email: customer.email, address: customer.address },
    equipment,
    issue: job.issue ?? "",
    fix: job.fix ?? "",
    lines,
    labor,
    total: money(lines.reduce((s, l) => s + l.amount, 0) + labor.amount),
  };
}

function hoursForSpeech(h: number): string {
  if (h === 0.5) return "half an hour of labor";
  if (h === 1) return "one hour of labor";
  if (h === 0.25) return "fifteen minutes of labor";
  return `${h} hours of labor`;
}

export function spokenSummary(r: Report): string {
  const items = r.lines.map((l) => {
    const name = l.name.replace(/\s*\(.*?\)/g, "").toLowerCase();
    return l.qty > 1 ? `${l.qty} × ${name}` : name;
  });
  if (r.labor.hours > 0) items.push(hoursForSpeech(r.labor.hours));
  const what = items.length ? items.join(", ") : "no parts or labor";
  return `Logged: ${what}, total $${r.total.toFixed(2)}.`;
}

export async function wrapUp(db: DataStore, job: Job, summary: string, reqId: string) {
  const equipment = await db.getEquipment(job.customer_id);
  const machine = equipment.find((e) => e.id === job.equipment_id) ?? null;
  const parts = await db.searchParts({ modelKey: machine?.model_key });

  let parsed = summary ? await parseWithClaude(summary, job, parts, reqId) : null;
  const usedFallback = Boolean(summary) && !parsed;
  parsed ??= parseLocally(summary, parts);

  const lines: JobLine[] = parsed.items.flatMap(({ sku, qty }) => {
    const p = parts.find((x) => x.sku === sku);
    return p ? [{ sku: p.sku, name: p.name, qty: Math.max(1, Math.round(qty)), unit_price: p.price }] : [];
  });
  const labor_hours = Math.max(0, Math.min(12, Number(parsed.labor_hours) || 0));
  log("tool.call", { reqId, tool: "log_job", jobId: job.id, lines: lines.map((l) => `${l.qty}x${l.sku}`), labor_hours, usedFallback });

  const completed = (await db.updateJob(job.id, {
    status: "completed",
    completed_at: new Date().toISOString(),
    parts: lines,
    labor_hours,
    fix: parsed.fix_summary,
    wrapup_text: summary,
  }))!;
  const customer = (await db.getCustomer(job.customer_id))!;
  const report = buildReport(completed, customer, machine && { make: machine.make, model: machine.model, location: machine.location, serial: machine.serial });
  const back_office = await launchBackOffice(report, reqId);
  await db.updateJob(job.id, { total: report.total, back_office: back_office ?? undefined });
  return { report, spoken: spokenSummary(report), fallback: usedFallback, back_office };
}
