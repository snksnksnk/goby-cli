// Receives redacted error reports from goby. Accepts only the documented
// fields, bounds every size, and rate-limits each anonymous installation.
import { pipeline, storeConfigured, REPORTS_KEY, MAX_STORED } from "../lib/store.js";

const MAX_BODY = 64 * 1024;
const MAX_EVENTS = 50;
const PER_INSTALL_PER_HOUR = 100;
const KINDS = new Set(["error", "run-failed"]);

const text = (value, limit) =>
  typeof value === "string" ? value.slice(0, limit) : value == null ? null : undefined;

function clean(event) {
  if (!event || typeof event !== "object" || !KINDS.has(event.kind)) return null;
  const installationID = text(event.installationID, 64);
  if (!installationID || !/^[0-9a-f-]{8,64}$/.test(installationID)) return null;
  const fields = {
    id: text(event.id, 64),
    installationID,
    timestamp: text(event.timestamp, 40),
    version: text(event.version, 40),
    macOS: text(event.macOS, 80),
    architecture: text(event.architecture, 20),
    kind: event.kind,
    command: text(event.command, 30),
    provider: text(event.provider, 20),
    message: text(event.message, 2000),
    exitCode: Number.isInteger(event.exitCode) ? event.exitCode : null,
  };
  if (Object.values(fields).some((value) => value === undefined)) return null;
  return fields;
}

export default async function handler(request, response) {
  if (request.method !== "POST") return response.status(405).json({ error: "POST only" });
  if (request.headers["x-goby-key"] !== process.env.GOBY_INGEST_KEY) {
    return response.status(401).json({ error: "unknown client" });
  }
  if (!storeConfigured()) return response.status(503).json({ error: "storage not configured" });

  const raw = typeof request.body === "string" ? request.body : JSON.stringify(request.body ?? null);
  if (raw.length > MAX_BODY) return response.status(413).json({ error: "too large" });
  let events;
  try { events = typeof request.body === "string" ? JSON.parse(request.body) : request.body; }
  catch { return response.status(400).json({ error: "invalid JSON" }); }
  if (!Array.isArray(events) || events.length === 0 || events.length > MAX_EVENTS) {
    return response.status(400).json({ error: "expected 1-50 events" });
  }

  const accepted = events.map(clean).filter(Boolean);
  if (accepted.length === 0) return response.status(400).json({ error: "no valid events" });

  // One rate counter per installation per hour.
  const hour = new Date().toISOString().slice(0, 13);
  const rateKey = `goby:rate:${accepted[0].installationID}:${hour}`;
  const [{ result: count }] = await pipeline([["INCRBY", rateKey, accepted.length], ["EXPIRE", rateKey, 3600]]);
  if (count > PER_INSTALL_PER_HOUR) return response.status(429).json({ error: "rate limited" });

  const receivedAt = new Date().toISOString();
  const values = accepted.map((event) => JSON.stringify({ ...event, receivedAt }));
  await pipeline([["LPUSH", REPORTS_KEY, ...values], ["LTRIM", REPORTS_KEY, 0, MAX_STORED - 1]]);
  return response.status(202).json({ accepted: accepted.length });
}
