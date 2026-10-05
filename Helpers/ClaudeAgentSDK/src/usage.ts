import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Options, Query, SDKUserMessage } from "@anthropic-ai/claude-agent-sdk";
import { temporaryChatOptions } from "./chat.js";

const readTimeoutMs = 20_000;

export type PlanRateLimit = {
  id: string;
  /** Fraction of the window used, 0-1. */
  utilization: number;
  /** Epoch seconds. */
  resetsAt?: number;
};

export type PlanUsage = {
  subscriptionType?: string;
  rateLimits: PlanRateLimit[];
};

type UsageWindow = { utilization: number | null; resets_at: string | null } | null | undefined;

/** The windows Claude's `/usage` shows, in the order Goby displays them. */
const windowOrder = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"] as const;

/**
 * Converts the SDK's `/usage` answer (utilization 0-100, ISO reset times)
 * into the bridge's rate-limit shape (fraction 0-1, epoch seconds).
 */
export function planUsageFromResponse(response: {
  subscription_type?: string | null;
  rate_limits_available?: boolean;
  rate_limits?: Record<string, UsageWindow> | null;
}): PlanUsage | undefined {
  if (!response.rate_limits_available || !response.rate_limits) return undefined;
  const rateLimits: PlanRateLimit[] = [];
  for (const id of windowOrder) {
    const window = response.rate_limits[id];
    if (window?.utilization === null || window?.utilization === undefined) continue;
    const resetsAt = window.resets_at === null ? NaN : Date.parse(window.resets_at);
    rateLimits.push({
      id,
      utilization: Math.min(Math.max(window.utilization / 100, 0), 1),
      ...(Number.isNaN(resetsAt) ? {} : { resetsAt: Math.round(resetsAt / 1_000) }),
    });
  }
  return {
    ...(response.subscription_type ? { subscriptionType: response.subscription_type } : {}),
    rateLimits,
  };
}

/**
 * Reads the subscription's plan usage the way Claude's `/usage` does. The
 * session is opened with no prompt and closed once it answers, so no model
 * request is made and no usage is spent. Undefined when the SDK cannot say.
 */
export async function readPlanUsage(deps: {
  query: (params: { prompt: AsyncIterable<SDKUserMessage>; options: Options }) => Query;
  env: Record<string, string | undefined>;
  executable: string;
  timeoutMs?: number;
}): Promise<PlanUsage | undefined> {
  const cwd = await mkdtemp(join(tmpdir(), "goby-usage-"));
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
    // Experimental in the SDK; feature-detect so an SDK update cannot break account reads.
    const read = (session as unknown as {
      usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET?: (opts: { skipBehaviors: boolean }) => Promise<unknown>;
    }).usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET;
    if (typeof read !== "function") return undefined;
    const timeout = new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new Error("Claude did not report plan usage in time.")), deps.timeoutMs ?? readTimeoutMs);
    });
    const response = await Promise.race([read.call(session, { skipBehaviors: true }), timeout]);
    return planUsageFromResponse(response as Parameters<typeof planUsageFromResponse>[0]);
  } finally {
    if (timer !== undefined) clearTimeout(timer);
    closeInput();
    abortController.abort();
    await rm(cwd, { recursive: true, force: true });
  }
}
