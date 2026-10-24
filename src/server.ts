import express, { type NextFunction, type Request, type Response } from "express";
import multer from "multer";
import { randomUUID } from "node:crypto";
import { createJsonStore } from "./data.ts";
import { ask, MODEL, type ImageMediaType } from "./agent.ts";
import { buildReport, spokenSummary, wrapUp } from "./wrapup.ts";
import { log } from "./log.ts";
import { fileURLToPath } from "node:url";

try {
  process.loadEnvFile(); // local .env, if present; on the VM env comes from systemd
} catch {}

const db = createJsonStore();
const app = express();
const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: 10 * 1024 * 1024 } });
const MAX_IMAGE_BYTES = 5 * 1024 * 1024; // Claude's per-image limit

app.use(express.json({ limit: "1mb" }));
app.use(express.static(fileURLToPath(new URL("../public", import.meta.url))));

app.use((req: Request, res: Response, next: NextFunction) => {
  const reqId = randomUUID().slice(0, 8);
  res.locals.reqId = reqId;
  const started = Date.now();
  res.on("finish", () => log("http", { reqId, method: req.method, path: req.path, status: res.statusCode, ms: Date.now() - started }));
  next();
});

function sniffImage(buf: Buffer): ImageMediaType | "heic" | null {
  if (buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) return "image/jpeg";
  if (buf.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return "image/png";
  if (buf.toString("ascii", 0, 4) === "RIFF" && buf.toString("ascii", 8, 12) === "WEBP") return "image/webp";
  if (buf.toString("ascii", 0, 3) === "GIF") return "image/gif";
  if (buf.toString("ascii", 4, 8) === "ftyp" && /^(heic|heix|hevc|mif1|msf1)$/.test(buf.toString("ascii", 8, 12))) return "heic";
  return null;
}

app.get("/health", (_req, res) => {
  res.json({ ok: true, model: MODEL, anthropic_key: Boolean(process.env.ANTHROPIC_API_KEY), uptime_s: Math.round(process.uptime()) });
});

app.get("/customers", async (_req, res) => {
  const customers = await db.listCustomers();
  res.json(await Promise.all(customers.map(async (c) => ({ ...c, equipment: await db.getEquipment(c.id) }))));
});

app.post("/jobs", async (req, res) => {
  const { customer_id, equipment_id } = req.body ?? {};
  const customer = customer_id && (await db.getCustomer(customer_id));
  if (!customer) return void res.status(400).json({ error: "unknown customer_id" });
  const job = await db.createJob({ customerId: customer.id, equipmentId: equipment_id ?? null });
  log("job.created", { reqId: res.locals.reqId, jobId: job.id, customer: customer.company });
  res.status(201).json({ job, customer });
});

app.get("/jobs/:id", async (req, res) => {
  const job = await db.getJob(req.params.id);
  if (!job) return void res.status(404).json({ error: "job not found" });
  res.json({ job, customer: await db.getCustomer(job.customer_id) });
});

// multipart/form-data: photo (file, optional), text (question), job_id
app.post("/ask", upload.single("photo"), async (req, res) => {
  const reqId = res.locals.reqId as string;
  const question = String(req.body?.text ?? "").trim();
  const job = await db.getJob(String(req.body?.job_id ?? ""));
  if (!job) return void res.status(400).json({ error: "unknown job_id; start a job first" });
  if (job.status !== "open") return void res.status(409).json({ error: "job is already wrapped up" });
  if (!question && !req.file) return void res.status(400).json({ error: "send a question, a photo, or both" });

  let photo: { data: Buffer; mediaType: ImageMediaType } | null = null;
  if (req.file) {
    const kind = sniffImage(req.file.buffer);
    if (kind === "heic") return void res.status(415).json({ error: "HEIC is not supported; send JPEG or PNG" });
    if (!kind) return void res.status(415).json({ error: "photo must be JPEG, PNG, WebP or GIF" });
    if (req.file.size > MAX_IMAGE_BYTES) return void res.status(413).json({ error: "photo over 5 MB; resize to ~1568px JPEG" });
    photo = { data: req.file.buffer, mediaType: kind };
  }
  log("ask.start", { reqId, jobId: job.id, question, photoBytes: req.file?.size ?? 0 });

  const result = await ask(db, job, question, photo, reqId);

  const equipment = await db.getEquipment(job.customer_id);
  const matched = equipment.find((e) => e.id === result.equipment_id) ?? null;
  const catalog = await db.searchParts({});
  const parts = result.recommended_skus.flatMap((sku) => catalog.filter((p) => p.sku === sku)).map(({ sku, name, price }) => ({ sku, name, price }));

  if (!result.fallback) {
    await db.updateJob(job.id, {
      equipment_id: job.equipment_id ?? matched?.id ?? null,
      issue: result.suspected_issue ?? job.issue,
      notes: [...job.notes, { at: new Date().toISOString(), question, answer: result.answer }],
    });
  }
  log("ask.done", { reqId, jobId: job.id, fallback: result.fallback, equipment: matched?.id, answer: result.answer });

  res.json({
    answer: result.answer,
    fallback: result.fallback,
    equipment: matched && { id: matched.id, make: matched.make, model: matched.model, location: matched.location },
    suspected_issue: result.suspected_issue,
    recommended_parts: parts,
  });
});

// body: { text: "descaling kit, new water filter, half an hour of labor" }
// Idempotent: wrapping up a completed job returns its existing report.
app.post("/jobs/:id/wrapup", async (req, res) => {
  const reqId = res.locals.reqId as string;
  const job = await db.getJob(req.params.id);
  if (!job) return void res.status(404).json({ error: "job not found" });
  if (job.status === "completed") return void res.json(await reportFor(job.id));

  const text = String(req.body?.text ?? "").trim();
  log("wrapup.start", { reqId, jobId: job.id, text });
  const { report, spoken, fallback } = await wrapUp(db, job, text, reqId);
  log("wrapup.done", { reqId, jobId: job.id, total: report.total, fallback });
  res.json({ report, spoken, fallback });
});

app.get("/jobs/:id/report", async (req, res) => {
  const job = await db.getJob(req.params.id);
  if (!job) return void res.status(404).json({ error: "job not found" });
  if (job.status !== "completed") return void res.status(409).json({ error: "job is still open" });
  res.json(await reportFor(job.id));
});

async function reportFor(jobId: string) {
  const job = (await db.getJob(jobId))!;
  const customer = (await db.getCustomer(job.customer_id))!;
  const e = (await db.getEquipment(job.customer_id)).find((x) => x.id === job.equipment_id);
  const report = buildReport(job, customer, e ? { make: e.make, model: e.model, location: e.location, serial: e.serial } : null);
  return { report, spoken: spokenSummary(report), fallback: false };
}

app.use((err: any, _req: Request, res: Response, _next: NextFunction) => {
  log("http.error", { reqId: res.locals.reqId, error: err?.message });
  const status = err instanceof multer.MulterError ? 400 : 500;
  res.status(status).json({ error: status === 400 ? err.message : "internal error" });
});

const port = Number(process.env.PORT ?? 3000);
app.listen(port, () => log("server.listening", { port, model: MODEL, anthropic_key: Boolean(process.env.ANTHROPIC_API_KEY) }));
