import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Options, Query, SDKMessage } from "@anthropic-ai/claude-agent-sdk";
import { assistantText } from "./messages.js";
import { JSONRPCError } from "./protocol.js";

/** A temporary chat question. `prompt` already carries earlier turns. */
export type TemporaryChatRequest = {
  prompt: string;
  model?: string;
};

export type TemporaryChatResponse = { text: string };

export const temporaryChatSystemPrompt = [
  "You answer quick questions in Goby's temporary chat.",
  "You have no tools and no access to the user's projects, files, commands or settings.",
  "Answer from your own knowledge, concisely, in Markdown.",
  "If a question needs the user's files or projects, say so and suggest sending it as a project request in Goby.",
].join(" ");

const promptLimit = 64_000;

/**
 * Options for a chat that can only talk: no built-in tools, no MCP servers,
 * no settings, plugins or saved session, one turn, in an empty folder the
 * sandbox may read but never write. Every tool request is denied as well.
 */
export function temporaryChatOptions(input: {
  cwd: string;
  env: Record<string, string | undefined>;
  executable: string;
  model?: string;
  abortController?: AbortController;
}): Options {
  return {
    ...(input.abortController === undefined ? {} : { abortController: input.abortController }),
    cwd: input.cwd,
    systemPrompt: temporaryChatSystemPrompt,
    settingSources: [],
    tools: [],
    allowedTools: [],
    mcpServers: {},
    permissionMode: "default",
    canUseTool: async () => ({ behavior: "deny", message: "Temporary chat has no tool access." }),
    persistSession: false,
    maxTurns: 1,
    sandbox: {
      enabled: true,
      failIfUnavailable: true,
      autoAllowBashIfSandboxed: false,
      allowUnsandboxedCommands: false,
      filesystem: { allowRead: [input.cwd], allowWrite: [] },
    },
    env: input.env,
    executable: input.executable as never,
    ...(input.model === undefined ? {} : { model: input.model }),
  };
}

/** The final answer from a chat's message stream. */
export async function collectChatAnswer(messages: AsyncIterable<SDKMessage>): Promise<string> {
  let lastText: string | undefined;
  for await (const message of messages) {
    if (message.type === "assistant") {
      if (message.error === "authentication_failed" || message.error === "oauth_org_not_allowed") {
        throw new JSONRPCError(-32001, "Claude needs a valid credential. Check Goby Settings → Providers.");
      }
      const texts = assistantText(message);
      if (texts.length > 0) lastText = texts.join("\n\n");
    }
    if (message.type === "result") {
      if (message.subtype === "success" && !message.is_error) {
        const result = message.result.trim();
        return result.length > 0 ? result : (lastText ?? "");
      }
      const failure = message.subtype === "success" ? message.result : message.errors.join("\n") || message.subtype;
      throw new JSONRPCError(-32002, `Claude could not answer: ${failure}`);
    }
  }
  if (lastText !== undefined) return lastText;
  throw new JSONRPCError(-32002, "Claude finished without an answer.");
}

/** Runs one chat turn in a fresh empty folder and removes it afterwards. */
export async function runTemporaryChat(
  request: TemporaryChatRequest,
  deps: {
    query: (params: { prompt: string; options: Options }) => Query | AsyncIterable<SDKMessage>;
    env: Record<string, string | undefined>;
    executable: string;
  },
): Promise<TemporaryChatResponse> {
  const prompt = typeof request.prompt === "string" ? request.prompt.trim() : "";
  if (prompt.length === 0) throw new JSONRPCError(-32602, "chat/ask needs a question.");
  if (prompt.length > promptLimit) throw new JSONRPCError(-32602, "chat/ask question is too long.");
  const cwd = await mkdtemp(join(tmpdir(), "goby-chat-"));
  try {
    const messages = deps.query({
      prompt,
      options: temporaryChatOptions({
        cwd,
        env: deps.env,
        executable: deps.executable,
        ...(request.model === undefined ? {} : { model: request.model }),
      }),
    });
    return { text: await collectChatAnswer(messages) };
  } finally {
    await rm(cwd, { recursive: true, force: true });
  }
}
