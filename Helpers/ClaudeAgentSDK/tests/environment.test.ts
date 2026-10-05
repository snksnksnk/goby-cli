import assert from "node:assert/strict";
import test from "node:test";
import {
  disallowedToolsForProviderEnvironment,
  providerChildEnvironment,
  providerRuntimeExecutable,
} from "../src/bridge.js";

test("Claude child environment excludes GitHub and Copilot credentials", () => {
  const environment = providerChildEnvironment({
    PATH: "/usr/bin",
    ANTHROPIC_API_KEY: "selected-claude-key",
    GOBY_COPILOT_GITHUB_TOKEN: "copilot-token",
    GITHUB_TOKEN: "github-token",
    GH_TOKEN: "gh-token",
  });

  assert.equal(environment.PATH, "/usr/bin");
  assert.equal(environment.ANTHROPIC_API_KEY, "selected-claude-key");
  assert.equal(environment.GOBY_COPILOT_GITHUB_TOKEN, undefined);
  assert.equal(environment.GITHUB_TOKEN, undefined);
  assert.equal(environment.GH_TOKEN, undefined);
  assert.deepEqual(disallowedToolsForProviderEnvironment(environment), ["Bash"]);
});

test("Claude shell remains unavailable for every inherited provider credential", () => {
  const environment = providerChildEnvironment({
    PATH: "/usr/bin",
    CLAUDE_CODE_OAUTH_TOKEN: "oauth-session",
  });

  assert.deepEqual(disallowedToolsForProviderEnvironment(environment), ["Bash"]);
  assert.deepEqual(disallowedToolsForProviderEnvironment({ PATH: "/usr/bin" }), []);
});

test("Claude SDK child uses the already validated absolute Node runtime", () => {
  assert.equal(providerRuntimeExecutable(), process.execPath);
  assert.equal(providerRuntimeExecutable().startsWith("/"), true);
  assert.notEqual(providerRuntimeExecutable(), "node");
});
