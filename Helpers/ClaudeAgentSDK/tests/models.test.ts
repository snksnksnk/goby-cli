import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import test from "node:test";
import type { ModelInfo, Options, Query } from "@anthropic-ai/claude-agent-sdk";
import { listClaudeModels, modelIDs } from "../src/models.js";

test("model ids prefer concrete ids and skip the default row", () => {
  const models: ModelInfo[] = [
    { value: "default", displayName: "Default", description: "" },
    { value: "sonnet", resolvedModel: "claude-sonnet-5-5", displayName: "Sonnet", description: "" },
    { value: "claude-sonnet-5-5", displayName: "Sonnet", description: "" },
    { value: "haiku", displayName: "Haiku", description: "" },
  ];
  assert.deepEqual(modelIDs(models), ["claude-sonnet-5-5", "haiku"]);
});

test("lists models without sending a prompt and closes the session", async () => {
  let seen: Options | undefined;
  const ids = await listClaudeModels({
    query: ({ prompt, options }) => {
      seen = options;
      assert.ok(existsSync(options.cwd!));
      void (async () => {
        for await (const message of prompt) assert.fail(`unexpected message ${JSON.stringify(message)}`);
      })();
      return { supportedModels: async () => [{ value: "opus", displayName: "Opus", description: "" }] } as unknown as Query;
    },
    env: {},
    executable: "node",
  });
  assert.deepEqual(ids, ["opus"]);
  assert.deepEqual(seen?.tools, []);
  assert.equal(seen?.abortController?.signal.aborted, true);
  assert.equal(existsSync(seen!.cwd!), false);
});

test("gives up when Claude does not answer", async () => {
  await assert.rejects(listClaudeModels({
    query: () => ({ supportedModels: () => new Promise(() => {}) }) as unknown as Query,
    env: {},
    executable: "node",
    timeoutMs: 20,
  }), /in time/);
});
