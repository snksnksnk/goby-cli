import assert from "node:assert/strict";
import test from "node:test";
import {
  CredentialPool,
  isUsageLimitFailure,
  resetTimeFromFailure,
} from "../src/credentials.js";
import { disallowedToolsForProviderEnvironment } from "../src/bridge.js";

const subscription = "sk-ant-oat01-subscription-token";
const apiKey = "sk-ant-api03-api-key";

test("the subscription token is the default when both credentials are saved", () => {
  const pool = new CredentialPool({
    GOBY_CLAUDE_SUBSCRIPTION_TOKEN: subscription,
    GOBY_CLAUDE_API_KEY: apiKey,
  });
  assert.equal(pool.current(), "subscription");
  const environment = pool.environment("subscription", { PATH: "/usr/bin" });
  assert.equal(environment.CLAUDE_CODE_OAUTH_TOKEN, subscription);
  assert.equal(environment.ANTHROPIC_API_KEY, undefined);
  assert.equal(environment.GOBY_CLAUDE_SUBSCRIPTION_TOKEN, undefined);
  assert.equal(environment.GOBY_CLAUDE_API_KEY, undefined);
  assert.equal(environment.PATH, "/usr/bin");
});

test("a paused subscription hands new work to the API key until it resets", () => {
  let now = 1_000_000;
  const pool = new CredentialPool({
    GOBY_CLAUDE_SUBSCRIPTION_TOKEN: subscription,
    GOBY_CLAUDE_API_KEY: apiKey,
  }, () => now);
  assert.equal(pool.canFallBack("subscription"), true);
  pool.pauseSubscription(1_000 + 60);
  assert.equal(pool.current(), "apiKey");
  const environment = pool.environment("apiKey", {});
  assert.equal(environment.ANTHROPIC_API_KEY, apiKey);
  assert.equal(environment.CLAUDE_CODE_OAUTH_TOKEN, undefined);
  now = 1_060_001;
  assert.equal(pool.current(), "subscription");
  assert.equal(pool.pausedUntil, undefined);
});

test("a limit without a reset time pauses the subscription for an hour", () => {
  const now = 5_000_000;
  const pool = new CredentialPool({ GOBY_CLAUDE_SUBSCRIPTION_TOKEN: subscription, GOBY_CLAUDE_API_KEY: apiKey }, () => now);
  pool.pauseSubscription();
  assert.equal(pool.pausedUntil, now + 60 * 60_000);
});

test("without an API key the subscription stays in use and cannot fall back", () => {
  const pool = new CredentialPool({ GOBY_CLAUDE_SUBSCRIPTION_TOKEN: subscription });
  pool.pauseSubscription();
  assert.equal(pool.current(), "subscription");
  assert.equal(pool.canFallBack("subscription"), false);
});

test("with no saved credential Claude Code's own sign-in is used", () => {
  const pool = new CredentialPool({ PATH: "/usr/bin" });
  assert.equal(pool.current(), "claudeCodeLogin");
  assert.deepEqual(pool.environment("claudeCodeLogin", { PATH: "/usr/bin" }), { PATH: "/usr/bin" });
});

test("older hosts that pass Claude Code's own variable names still work", () => {
  const pool = new CredentialPool({ CLAUDE_CODE_OAUTH_TOKEN: subscription, ANTHROPIC_API_KEY: apiKey });
  assert.equal(pool.hasSubscription, true);
  assert.equal(pool.hasAPIKey, true);
});

test("usage limit failures are recognized with their reset time", () => {
  assert.equal(isUsageLimitFailure("Claude AI usage limit reached|1760000000"), true);
  assert.equal(isUsageLimitFailure("Credit balance is too low"), true);
  assert.equal(isUsageLimitFailure("You're out of extra usage"), true);
  assert.equal(isUsageLimitFailure("rate_limit"), true);
  assert.equal(isUsageLimitFailure("The file was not found"), false);
  assert.equal(resetTimeFromFailure("Claude AI usage limit reached|1760000000"), 1_760_000_000);
  assert.equal(resetTimeFromFailure("usage limit reached"), undefined);
});

test("Goby's credential slots keep Claude shell tools unavailable", () => {
  assert.deepEqual(disallowedToolsForProviderEnvironment({ GOBY_CLAUDE_API_KEY: apiKey }), ["Bash"]);
  assert.deepEqual(disallowedToolsForProviderEnvironment({ GOBY_CLAUDE_SUBSCRIPTION_TOKEN: subscription }), ["Bash"]);
});
