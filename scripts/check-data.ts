// Smoke test for the data module: npx tsx scripts/check-data.ts
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createJsonStore } from "../src/data.ts";

const dir = mkdtempSync(join(tmpdir(), "fp-"));
const db = createJsonStore({ dataDir: dir });
const eq = await db.getEquipment("cust_venue");
console.log("venue equipment:", eq.map((e) => `${e.make} ${e.model}`));
console.log("venue history:", (await db.getJobHistory({ equipmentId: eq[0].id })).map((h) => `${h.date} ${h.fix}`));
console.log("parts 'filter descale' for venue:", (await db.searchParts({ query: "filter descal", modelKey: eq[0].model_key })).map((p) => p.sku));
const job = await db.createJob({ customerId: "cust_venue", equipmentId: eq[0].id });
await Promise.all([1, 2, 3].map((n) => db.updateJob(job.id, { labor_hours: n * 0.5 })));
await db.updateJob(job.id, { status: "completed", completed_at: new Date().toISOString(), issue: "slow", fix: "descaled", parts: [{ sku: "DSC-KIT-01", name: "Descaling kit", qty: 1, unit_price: 34 }] });
const reopened = createJsonStore({ dataDir: dir }); // simulates a restart
console.log("job after restart:", await reopened.getJob(job.id));
console.log("history now includes job:", (await reopened.getJobHistory({ equipmentId: eq[0].id })).length === 4);
console.log("unknown customer:", await db.getCustomer("nope"));
