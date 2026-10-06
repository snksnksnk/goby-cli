// Upstash Redis over its REST API (what Vercel's "Upstash for Redis"
// integration provides). No SDK: one fetch per pipeline.
const URL_ENV = process.env.KV_REST_API_URL || process.env.UPSTASH_REDIS_REST_URL;
const TOKEN_ENV = process.env.KV_REST_API_TOKEN || process.env.UPSTASH_REDIS_REST_TOKEN;

export const REPORTS_KEY = "goby:reports";
export const MAX_STORED = 5000;

export function storeConfigured() {
  return Boolean(URL_ENV && TOKEN_ENV);
}

export async function pipeline(commands) {
  const response = await fetch(`${URL_ENV}/pipeline`, {
    method: "POST",
    headers: { Authorization: `Bearer ${TOKEN_ENV}`, "Content-Type": "application/json" },
    body: JSON.stringify(commands),
  });
  if (!response.ok) throw new Error(`store ${response.status}`);
  return response.json();
}
