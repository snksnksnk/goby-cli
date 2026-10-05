import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ModelInfo, Options, Query, SDKUserMessage } from "@anthropic-ai/claude-agent-sdk";
import { temporaryChatOptions } from "./chat.js";

const listTimeoutMs = 20_000;

/**
 * Model ids for the model picker, in Claude's order. A concrete id is
 * preferred over its alias so the picker shows what will run; the "default"
 * row is left out because Automatic already covers it.
 */
export function modelIDs(models: ModelInfo[]): string[] {
  const seen = new Set<string>();
  const ids: string[] = [];
  for (const model of models) {
    if (model.value === "default") continue;
    const id = (model.resolvedModel ?? model.value).trim();
    if (id.length === 0 || seen.has(id)) continue;
    seen.add(id);
    ids.push(id);
  }
  return ids;
}

/**
 * Asks Claude which models this account can use. The session is opened with
 * no prompt and closed as soon as the list arrives, so no model request is
 * made; it runs with the temporary chat's no-tools, no-write options.
 */
export async function listClaudeModels(deps: {
  query: (params: { prompt: AsyncIterable<SDKUserMessage>; options: Options }) => Query;
  env: Record<string, string | undefined>;
  executable: string;
  timeoutMs?: number;
}): Promise<string[]> {
  const cwd = await mkdtemp(join(tmpdir(), "goby-models-"));
  const abortController = new AbortController();
  let closeInput: () => void = () => {};
  const inputClosed = new Promise<void>((resolve) => { closeInput = resolve; });
  async function* noMessages(): AsyncIterable<SDKUserMessage> {
    await inputClosed;
  }
  let timer: NodeJS.Timeout | undefined;
  try {
    const session = deps.query({
      prompt: noMessages(),
      options: temporaryChatOptions({ cwd, env: deps.env, executable: deps.executable, abortController }),
    });
    const timeout = new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new Error("Claude did not list its models in time.")), deps.timeoutMs ?? listTimeoutMs);
    });
    return modelIDs(await Promise.race([session.supportedModels(), timeout]));
  } finally {
    if (timer !== undefined) clearTimeout(timer);
    closeInput();
    abortController.abort();
    await rm(cwd, { recursive: true, force: true });
  }
}
