// Back-office handoff: after wrap-up, launch an Omnara agent that drafts the customer follow-up
// (job summary email + next-visit plan). Optional: runs only when OMNARA_TOKEN, OMNARA_ORG and
// OMNARA_PROJECT are set. Never blocks or fails wrap-up; on any problem it logs and returns null.

import type { Report } from "./wrapup.ts";
import { log } from "./log.ts";

const API = process.env.OMNARA_API ?? "https://api.omnara.com/v1";
const TIMEOUT_MS = 6_000;

export interface BackOffice {
  agent_id: string;
  dashboard_url: string;
}

const INSTRUCTION = `You are the back-office assistant for Northside Coffee Service, a company that installs and services coffee equipment in offices.
A field technician has just finished a job. From the job report you are given:
1. Draft a short, friendly email to the customer contact summarizing what was wrong, what was done, parts and labor, and the total.
2. Write a next-visit plan: what will be due next for this machine and roughly when (descaling every 6 months, bean-to-cup water filters every 3 months).
Keep both brief and plain. Do not invent work that is not in the report.`;

export function omnaraConfigured(): boolean {
  return Boolean(process.env.OMNARA_TOKEN && process.env.OMNARA_ORG && process.env.OMNARA_PROJECT);
}

export async function launchBackOffice(report: Report, reqId: string): Promise<BackOffice | null> {
  if (!omnaraConfigured()) {
    log("omnara.skipped", { reqId, why: "OMNARA_TOKEN / OMNARA_ORG / OMNARA_PROJECT not set" });
    return null;
  }
  const { OMNARA_TOKEN, OMNARA_ORG, OMNARA_PROJECT } = process.env;
  const config = {
    version: "v1",
    instruction: INSTRUCTION,
    model: {
      provider_config: process.env.OMNARA_PROVIDER ?? "omnara-openrouter",
      name: process.env.OMNARA_MODEL ?? "anthropic/claude-fable-5.1",
    },
  };

  const started = Date.now();
  try {
    const res = await fetch(`${API}/orgs/${OMNARA_ORG}/projects/${OMNARA_PROJECT}/agents`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${OMNARA_TOKEN}`,
        "Content-Type": "application/json",
        // A retried wrap-up for the same job must not launch a second agent.
        "Idempotency-Key": `glass-agent-${report.job_id}`,
      },
      body: JSON.stringify({
        config_source: { source: JSON.stringify(config), source_format: "json" },
        name: `Follow-up ${report.customer.company} ${report.date}`.slice(0, 64),
        message: `Job report:\n${JSON.stringify(report, null, 2)}`,
      }),
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
    const body: any = await res.json().catch(() => ({}));
    if (!res.ok || !body?.agent?.id) {
      log("omnara.failed", { reqId, status: res.status, code: body?.code ?? null, error: body?.error ?? null, ms: Date.now() - started });
      return null;
    }
    const out = { agent_id: String(body.agent.id), dashboard_url: "https://app.omnara.com" };
    log("tool.call", { reqId, tool: "omnara_launch_back_office", agentId: out.agent_id, ms: Date.now() - started });
    return out;
  } catch (err) {
    log("omnara.failed", { reqId, error: (err as Error).message, ms: Date.now() - started });
    return null;
  }
}
