// Lists stored reports for the maintainer. Requires the admin token.
import { pipeline, storeConfigured, REPORTS_KEY } from "../lib/store.js";

export default async function handler(request, response) {
  if (request.method !== "GET") return response.status(405).json({ error: "GET only" });
  const token = process.env.GOBY_ADMIN_TOKEN;
  if (!token || request.headers.authorization !== `Bearer ${token}`) {
    return response.status(401).json({ error: "admin token required" });
  }
  if (!storeConfigured()) return response.status(503).json({ error: "storage not configured" });
  const limit = Math.min(Math.max(parseInt(request.query.limit ?? "500", 10) || 500, 1), 5000);
  const [{ result }] = await pipeline([["LRANGE", REPORTS_KEY, 0, limit - 1]]);
  const reports = (result ?? []).map((value) => { try { return JSON.parse(value); } catch { return null; } }).filter(Boolean);
  response.setHeader("Cache-Control", "no-store");
  return response.status(200).json({ reports });
}
