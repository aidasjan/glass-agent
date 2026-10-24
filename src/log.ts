// One JSON line per event on stdout, so `journalctl -f` is readable during the live demo.
export function log(event: string, fields: Record<string, unknown> = {}): void {
  console.log(JSON.stringify({ ts: new Date().toISOString(), event, ...fields }));
}
