// Launch one Omnara back-office agent with a sample report, to check the Omnara setup.
// Usage: npm run check:omnara      (reads OMNARA_* from .env)
import { launchBackOffice, omnaraConfigured } from "../src/omnara.ts";
import type { Report } from "../src/wrapup.ts";

try {
  process.loadEnvFile();
} catch {}

if (!omnaraConfigured()) {
  console.error("Set OMNARA_TOKEN, OMNARA_ORG and OMNARA_PROJECT in .env first.");
  process.exit(1);
}

// Preflight: can this token see the project? (Omnara answers 404 for anything outside its access.)
const api = process.env.OMNARA_API ?? "https://api.omnara.com/v1";
const auth = { Authorization: `Bearer ${process.env.OMNARA_TOKEN}` };
const orgsRes = await fetch(`${api}/orgs`, { headers: auth });
const orgs: any = await orgsRes.json().catch(() => ({}));
const orgIds: string[] = (orgs.items ?? orgs.orgs ?? orgs.data ?? []).map((o: any) => o.id);
console.log(`orgs visible to token (${orgsRes.status}):`, orgIds.length ? orgIds : orgs);
const projRes = await fetch(`${api}/orgs/${process.env.OMNARA_ORG}/projects`, { headers: auth });
const projs: any = await projRes.json().catch(() => ({}));
const projIds: string[] = (projs.items ?? projs.projects ?? projs.data ?? []).map((p: any) => p.id);
console.log(`projects visible in OMNARA_ORG (${projRes.status}):`, projIds.length ? projIds : projs);
if (!projIds.includes(process.env.OMNARA_PROJECT!)) {
  console.error(
    "\nThe token can't see OMNARA_PROJECT. In the Omnara dashboard: select 'All projects' > Access > API Tokens >\n" +
      "open this key > give it a role on the project (one that can launch agents), or give the key the admin org role.",
  );
  process.exit(1);
}
console.log("project visible: yes\n");

const sample: Report = {
  job_id: `check-${Date.now()}`,
  date: new Date().toISOString().slice(0, 10),
  customer: { company: "Hackathon Venue", contact_name: "Front Desk", email: "facilities@hackathon-venue.example", address: "Demo Hall, 1st floor kitchen" },
  equipment: { make: "Jura", model: "E8", location: "Main kitchen counter", serial: "VN-24-0117" },
  issue: "Slow, lukewarm brewing from scale buildup",
  fix: "Descaled the machine and replaced the overdue water filter.",
  lines: [
    { sku: "DSC-KIT-01", name: "Descaling kit", qty: 1, unit_price: 34, amount: 34 },
    { sku: "WF-CART-BTC", name: "Water filter cartridge (bean-to-cup)", qty: 1, unit_price: 42, amount: 42 },
  ],
  labor: { hours: 0.5, rate: 95, amount: 47.5 },
  total: 123.5,
};

const result = await launchBackOffice(sample, "check");
if (result) {
  console.log(`OK: launched Omnara agent ${result.agent_id}. Open ${result.dashboard_url} to watch it draft the follow-up.`);
} else {
  console.error("Launch failed; see the omnara.failed log line above for the status and error.");
  process.exit(1);
}
