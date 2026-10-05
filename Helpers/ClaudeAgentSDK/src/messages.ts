import type { SDKAssistantMessage, SDKUserMessage } from "@anthropic-ai/claude-agent-sdk";

export type TrackedToolCall = {
  id: string;
  name: string;
  input: Record<string, unknown>;
};

export type ToolResult = {
  toolUseId: string;
  isError: boolean;
  output: string;
};

export function assistantText(message: SDKAssistantMessage): string[] {
  return message.message.content.flatMap((block) => {
    if (block.type !== "text") return [];
    const trimmed = block.text.trim();
    return trimmed.length === 0 ? [] : [trimmed];
  });
}

export function assistantToolCalls(message: SDKAssistantMessage): TrackedToolCall[] {
  return message.message.content.flatMap((block) => {
    if (block.type !== "tool_use") return [];
    const input = isRecord(block.input) ? block.input : {};
    return [{ id: block.id, name: block.name, input }];
  });
}

export function userToolResults(message: SDKUserMessage): ToolResult[] {
  if (!Array.isArray(message.message.content)) return [];
  return message.message.content.flatMap((block) => {
    if (block.type !== "tool_result") return [];
    return [{
      toolUseId: block.tool_use_id,
      isError: block.is_error === true,
      output: stringifyToolOutput(block.content),
    }];
  });
}

export function commandFor(call: TrackedToolCall): string {
  if (call.name === "Bash" && typeof call.input.command === "string") {
    return call.input.command;
  }
  return `${call.name} ${JSON.stringify(call.input)}`;
}

function stringifyToolOutput(value: unknown): string {
  if (typeof value === "string") return value;
  if (Array.isArray(value)) {
    return value.map((item) => {
      if (isRecord(item) && item.type === "text" && typeof item.text === "string") return item.text;
      return JSON.stringify(item);
    }).join("\n");
  }
  return value === undefined ? "" : JSON.stringify(value);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
