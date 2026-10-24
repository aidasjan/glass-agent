# Glass Agent

Hands-free copilot for Northside Coffee Service technicians wearing Meta glasses.
Look at a machine, tap, ask; the agent answers through the glasses using our customer
history and parts catalog. Say "wrap it up …" to log the job and get a priced report.

## Backend (TypeScript/Node)

```bash
npm install
echo "ANTHROPIC_API_KEY=sk-ant-..." > .env   # gitignored
npm run dev                                   # http://localhost:3000 (web fallback page)
scripts/demo.sh                               # job -> ask with sample photo -> wrap up
```

| Endpoint | |
|---|---|
| `GET /` | Web fallback page (photo + question + wrap-up, works without glasses) |
| `GET /health` | `{ ok, model, anthropic_key }` |
| `GET /customers` | Customers with their installed equipment |
| `POST /jobs` | `{ customer_id }` → new open job |
| `POST /ask` | multipart: `job_id`, `text`, `photo` (JPEG/PNG) → `{ answer, equipment, suspected_issue, recommended_parts }` |
| `POST /jobs/:id/wrapup` | `{ text: "descaling kit, new filter, half an hour" }` → `{ report, spoken }` (idempotent) |
| `GET /jobs/:id`, `GET /jobs/:id/report` | Job and report |

- Seed data: `data/seed.json`. **Machine makes/models live only in its `models` block**; `VENUE_MACHINE` is the demo machine.
- Jobs persist to `$DATA_DIR/jobs.json` (default `./data`), written atomically.
- All storage goes through `src/data.ts` (`DataStore` interface), swappable for Postgres.
- Every Claude call has a timeout and a spoken fallback; every request and tool call logs one JSON line to stdout.
- Production: `npm run build && npm start` (env: `ANTHROPIC_API_KEY`, `PORT`, `DATA_DIR`).

### Deploy to Freestyle

Add `FREESTYLE_API_KEY=...` to `.env`, then:

```bash
scripts/deploy.sh my-name        # -> https://my-name.style.dev (re-run to ship updates)
scripts/logs.sh                  # follow live logs
```

Creates VM `glass-agent` (Ubuntu, 2 vCPU), runs the server under systemd (restarts on crash/reboot),
keeps jobs in `/var/lib/glass-agent`, and pauses after 15 idle minutes (next request wakes it).

## iOS app (`ios/CameraAccess`)

Built on Meta's DAT `CameraAccess` sample; Glass Agent code is in `CameraAccess/GlassAgent/`.

1. Open `ios/CameraAccess/CameraAccess.xcodeproj` in Xcode 26.4+ (Xcode resolves the
   `meta-wearables-dat-ios` Swift package on first open).
2. Signing: create `ios/CameraAccess/Signing.local.xcconfig` (gitignored) containing
   `DEVELOPMENT_TEAM = <your Apple Team ID>`, and set a unique bundle identifier.
3. Run on an iPhone. In the app's settings (gear), set the backend URL
   (for local testing: `http://<your-mac-LAN-IP>:3000`).
4. Without glasses: use the ladybug debug button (Debug builds) for MockDeviceKit.
   With glasses: enable Developer Mode in the Meta AI app, then "Connect my glasses".

Flow: pick customer → camera connects → tap **Tap to ask** → speak (auto-sends when you pause)
→ answer plays on the glasses → say "wrap it up: descaling kit, new filter, half an hour of labor"
→ report appears. A text field is there if voice isn't working.
