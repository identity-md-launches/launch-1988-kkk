import { settings, localUrl, json } from "../shared/config.ts";
import { reconcile } from "../shared/reconcile.ts";
const config = settings();
const url = process.argv[2] ?? `http://127.0.0.1:${config.apiPort}`;
localUrl(url);
try {
  const response = await fetch(`${url}/snapshot`, {
    signal: AbortSignal.timeout(6000),
  });
  if (!response.ok) throw new Error(`API HTTP ${response.status}`);
  const snapshot = await response.json();
  // Lag is acceptable for same-block reconciliation, but an orphaned or disconnected view is not.
  if (snapshot.status.connectionError)
    throw new Error(snapshot.status.connectionError);
  console.log(json(await reconcile(snapshot.data, config)));
} catch (e) {
  console.error(e instanceof Error ? e.message : e);
  process.exitCode = 1;
}
