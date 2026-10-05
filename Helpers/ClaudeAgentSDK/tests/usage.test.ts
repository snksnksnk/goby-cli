import assert from "node:assert/strict";
import test from "node:test";
import { planUsageFromResponse } from "../src/usage.js";

test("plan usage converts Claude's /usage windows to fractions and epoch seconds", () => {
  const usage = planUsageFromResponse({
    subscription_type: "max",
    rate_limits_available: true,
    rate_limits: {
      seven_day: { utilization: 41, resets_at: "2026-10-08T12:00:00Z" },
      five_hour: { utilization: 12.5, resets_at: "2026-10-04T17:00:00Z" },
      seven_day_opus: { utilization: null, resets_at: null },
    },
  });
  assert.deepEqual(usage, {
    subscriptionType: "max",
    rateLimits: [
      { id: "five_hour", utilization: 0.125, resetsAt: Date.parse("2026-10-04T17:00:00Z") / 1_000 },
      { id: "seven_day", utilization: 0.41, resetsAt: Date.parse("2026-10-08T12:00:00Z") / 1_000 },
    ],
  });
});

test("API-key sessions have no plan usage", () => {
  assert.equal(planUsageFromResponse({ rate_limits_available: false, rate_limits: null }), undefined);
});
