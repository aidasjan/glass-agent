// Data-access module. The only place that touches storage.
// Seed data (customers, equipment, history, catalog) is read-only from data/seed.json.
// Jobs created at runtime persist to $DATA_DIR/jobs.json (atomic write: temp file + rename).
// Swap this file for a Postgres implementation of DataStore later.

import { readFile, writeFile, rename, mkdir } from "node:fs/promises";
import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";

export interface MachineModel {
  make: string;
  model: string;
  type: string;
  descale_interval_months?: number;
  water_filter_interval_months?: number;
}
export interface Customer { id: string; company: string; contact_name: string; email: string; address: string }
export interface Equipment {
  id: string; customer_id: string; model_key: string; serial: string; location: string; installed: string;
  make: string; model: string; type: string; descale_interval_months?: number; water_filter_interval_months?: number;
}
export interface Part { sku: string; name: string; price: number; compatible_models: string[] }
export interface HistoryEntry {
  id: string; equipment_id: string | null; customer_id: string; date: string;
  issue: string; fix: string; parts_used: string[];
}
export interface JobLine { sku: string; name: string; qty: number; unit_price: number }
export interface Job {
  id: string;
  customer_id: string;
  equipment_id: string | null;
  status: "open" | "completed";
  started_at: string;
  completed_at?: string;
  issue?: string;
  fix?: string;
  wrapup_text?: string;
  notes:{ at: string; question: string; answer: string }[];
  parts: JobLine[];
  labor_hours: number;
  labor_rate: number;
  total?: number;
}

export interface DataStore {
  listCustomers(): Promise<Customer[]>;
  getCustomer(id: string): Promise<Customer | null>;
  getEquipment(customerId: string): Promise<Equipment[]>;
  getJobHistory(filter: { customerId?: string; equipmentId?: string }): Promise<HistoryEntry[]>;
  searchParts(filter: { query?: string; modelKey?: string }): Promise<Part[]>;
  getJob(id: string): Promise<Job | null>;
  createJob(input: { customerId: string; equipmentId?: string | null }): Promise<Job>;
  updateJob(id: string, patch: Partial<Omit<Job, "id">>): Promise<Job | null>;
  laborRate(): number;
}

interface Seed {
  models: Record<string, MachineModel>;
  labor_rate_per_hour: number;
  customers: Customer[];
  equipment: Omit<Equipment, keyof MachineModel>[];
  service_history: HistoryEntry[];
  catalog: Part[];
}

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

export function createJsonStore(opts: { seedPath?: string; dataDir?: string } = {}): DataStore {
  const seed: Seed = JSON.parse(readFileSync(opts.seedPath ?? join(ROOT, "data", "seed.json"), "utf8"));
  const jobsPath = join(opts.dataDir ?? process.env.DATA_DIR ?? join(ROOT, "data"), "jobs.json");

  const equipment: Equipment[] = seed.equipment.map((e) => {
    const m = seed.models[e.model_key];
    if (!m) throw new Error(`seed: equipment ${e.id} references unknown model_key ${e.model_key}`);
    return { ...e, ...m };
  });

  let jobs: Job[] | null = null;
  let writeChain: Promise<void> = Promise.resolve();

  async function loadJobs(): Promise<Job[]> {
    if (jobs) return jobs;
    try {
      jobs = JSON.parse(await readFile(jobsPath, "utf8")) as Job[];
    } catch (err: any) {
      if (err.code !== "ENOENT") console.error(`[data] could not read ${jobsPath}, starting empty:`, err.message);
      jobs = [];
    }
    return jobs;
  }

  // Serialize writes so concurrent requests never interleave temp files.
  function persist(): Promise<void> {
    const snapshot = JSON.stringify(jobs, null, 2);
    writeChain = writeChain.then(async () => {
      await mkdir(dirname(jobsPath), { recursive: true });
      const tmp = `${jobsPath}.${process.pid}.${Date.now()}.tmp`;
      await writeFile(tmp, snapshot);
      await rename(tmp, jobsPath);
    });
    return writeChain;
  }

  // Completed jobs count as service history for later visits.
  function jobToHistory(j: Job): HistoryEntry {
    return {
      id: j.id, equipment_id: j.equipment_id, customer_id: j.customer_id,
      date: (j.completed_at ?? j.started_at).slice(0, 10),
      issue: j.issue ?? "", fix: j.fix ?? "", parts_used: j.parts.map((p) => p.sku),
    };
  }

  return {
    async listCustomers() {
      return seed.customers;
    },
    async getCustomer(id) {
      return seed.customers.find((c) => c.id === id) ?? null;
    },
    async getEquipment(customerId) {
      return equipment.filter((e) => e.customer_id === customerId);
    },
    async getJobHistory({ customerId, equipmentId }) {
      const done = (await loadJobs()).filter((j) => j.status === "completed").map(jobToHistory);
      return [...seed.service_history, ...done]
        .filter((h) => (!customerId || h.customer_id === customerId) && (!equipmentId || h.equipment_id === equipmentId))
        .sort((a, b) => a.date.localeCompare(b.date));
    },
    async searchParts({ query, modelKey }) {
      const words = (query ?? "").toLowerCase().split(/\s+/).filter(Boolean);
      return seed.catalog.filter((p) => {
        const hay = `${p.sku} ${p.name}`.toLowerCase();
        const textOk = words.length === 0 || words.some((w) => hay.includes(w));
        const modelOk = !modelKey || p.compatible_models.includes("*") || p.compatible_models.includes(modelKey);
        return textOk && modelOk;
      });
    },
    async getJob(id) {
      return (await loadJobs()).find((j) => j.id === id) ?? null;
    },
    async createJob({ customerId, equipmentId = null }) {
      const list = await loadJobs();
      const job: Job = {
        id: `job_${randomUUID().slice(0, 8)}`, customer_id: customerId, equipment_id: equipmentId,
        status: "open", started_at: new Date().toISOString(), notes: [], parts: [],
        labor_hours: 0, labor_rate: seed.labor_rate_per_hour,
      };
      list.push(job);
      await persist();
      return job;
    },
    async updateJob(id, patch) {
      const list = await loadJobs();
      const i = list.findIndex((j) => j.id === id);
      if (i < 0) return null;
      list[i] = { ...list[i], ...patch, id };
      await persist();
      return list[i];
    },
    laborRate() {
      return seed.labor_rate_per_hour;
    },
  };
}
