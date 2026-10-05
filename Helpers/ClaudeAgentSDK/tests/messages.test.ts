import assert from "node:assert/strict";
import test from "node:test";
import type { SDKAssistantMessage, SDKUserMessage } from "@anthropic-ai/claude-agent-sdk";
import { assistantText, assistantToolCalls, commandFor, userToolResults } from "../src/messages.js";
import { describeError } from "../src/protocol.js";

test("normalizes assistant text and tool calls", () => {
  const message = {
    type: "assistant",
    message: {
      content: [
        { type: "text", text: " Running tests. " },
        { type: "tool_use", id: "tool-1", name: "Bash", input: { command: "swift test" } },
      ],
    },
  } as unknown as SDKAssistantMessage;

  assert.deepEqual(assistantText(message), ["Running tests."]);
  const calls = assistantToolCalls(message);
  assert.equal(calls.length, 1);
  assert.equal(commandFor(calls[0]!), "swift test");
});

test("normalizes successful and failed tool results", () => {
  const message = {
    type: "user",
    message: {
      role: "user",
      content: [
        { type: "tool_result", tool_use_id: "one", content: "ok" },
        { type: "tool_result", tool_use_id: "two", is_error: true, content: [{ type: "text", text: "failed" }] },
      ],
    },
  } as unknown as SDKUserMessage;

  assert.deepEqual(userToolResults(message), [
    { toolUseId: "one", isError: false, output: "ok" },
    { toolUseId: "two", isError: true, output: "failed" },
  ]);
});

test("provider errors are bounded and redact credentials and host paths", () => {
  const message = describeError(new Error(
    `Bearer abc.def API_KEY=super-secret at /Users/alice/private/project?token=query-secret ${"x".repeat(2_000)}`,
  ));

  assert.equal(message.includes("abc.def"), false);
  assert.equal(message.includes("super-secret"), false);
  assert.equal(message.includes("/Users/alice"), false);
  assert.equal(message.includes("query-secret"), false);
  assert.equal(message.length <= 1_000, true);
});
