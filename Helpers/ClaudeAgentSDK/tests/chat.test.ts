import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import test from "node:test";
import type { Options, SDKMessage } from "@anthropic-ai/claude-agent-sdk";
import { collectChatAnswer, runTemporaryChat, temporaryChatOptions } from "../src/chat.js";

async function* stream(messages: unknown[]): AsyncIterable<SDKMessage> {
  for (const message of messages) yield message as SDKMessage;
}

test("chat options allow talking only", async () => {
  const options = temporaryChatOptions({ cwd: "/tmp/empty", env: {}, executable: "node" });
  assert.deepEqual(options.tools, []);
  assert.deepEqual(options.allowedTools, []);
  assert.deepEqual(options.mcpServers, {});
  assert.deepEqual(options.settingSources, []);
  assert.equal(options.persistSession, false);
  assert.equal(options.maxTurns, 1);
  assert.deepEqual(options.sandbox?.filesystem?.allowWrite, []);
  const decision = await options.canUseTool!("Bash", { command: "ls" }, { signal: new AbortController().signal } as never);
  assert.equal(decision?.behavior, "deny");
});

test("collects the final answer and reports failures", async () => {
  const answer = await collectChatAnswer(stream([
    { type: "assistant", message: { content: [{ type: "text", text: "Partial" }] } },
    { type: "result", subtype: "success", is_error: false, result: "Final answer" },
  ]));
  assert.equal(answer, "Final answer");
  await assert.rejects(collectChatAnswer(stream([
    { type: "result", subtype: "error_max_turns", is_error: true, errors: ["limit"] },
  ])), /could not answer/);
});

test("runs in a fresh folder that is removed afterwards", async () => {
  let seen: Options | undefined;
  const response = await runTemporaryChat({ prompt: "What is 2 + 2?" }, {
    query: ({ options }) => {
      seen = options;
      assert.ok(existsSync(options.cwd!));
      return stream([{ type: "result", subtype: "success", is_error: false, result: "4" }]);
    },
    env: {},
    executable: "node",
  });
  assert.equal(response.text, "4");
  assert.ok(seen?.cwd);
  assert.equal(existsSync(seen!.cwd!), false);
  await assert.rejects(runTemporaryChat({ prompt: "  " }, { query: () => stream([]), env: {}, executable: "node" }));
});
