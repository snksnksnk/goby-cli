/**
 * Chooses which Claude credential a query runs on. A Claude Pro/Max
 * subscription token is the default; an Anthropic API key takes over while
 * the subscription's usage limit is exhausted, and the subscription returns
 * once its limit resets. With neither, the Claude Code sign-in on this Mac
 * is used.
 */

export const subscriptionTokenVariable = "GOBY_CLAUDE_SUBSCRIPTION_TOKEN";
export const apiKeyVariable = "GOBY_CLAUDE_API_KEY";

export type CredentialRoute = "subscription" | "apiKey" | "claudeCodeLogin";

/** How long to stay on the API key when the limit reports no reset time. */
const defaultPauseMilliseconds = 60 * 60_000;

export class CredentialPool {
  private readonly subscriptionToken: string | undefined;
  private readonly apiKey: string | undefined;
  private subscriptionPausedUntil: number | undefined;

  constructor(
    source: NodeJS.ProcessEnv = process.env,
    private readonly now: () => number = Date.now,
  ) {
    const subscription = nonEmpty(source[subscriptionTokenVariable]) ?? nonEmpty(source.CLAUDE_CODE_OAUTH_TOKEN);
    const apiKey = nonEmpty(source[apiKeyVariable]) ?? nonEmpty(source.ANTHROPIC_API_KEY);
    this.subscriptionToken = subscription;
    this.apiKey = apiKey;
  }

  get hasSubscription(): boolean {
    return this.subscriptionToken !== undefined;
  }

  get hasAPIKey(): boolean {
    return this.apiKey !== undefined;
  }

  /** Epoch milliseconds the subscription is paused until, while it is paused. */
  get pausedUntil(): number | undefined {
    if (this.subscriptionPausedUntil === undefined) return undefined;
    if (this.subscriptionPausedUntil <= this.now()) {
      this.subscriptionPausedUntil = undefined;
      return undefined;
    }
    return this.subscriptionPausedUntil;
  }

  current(): CredentialRoute {
    if (this.subscriptionToken !== undefined && this.pausedUntil === undefined) return "subscription";
    if (this.apiKey !== undefined) return "apiKey";
    // A paused subscription is still better than nothing; Claude reports the limit.
    if (this.subscriptionToken !== undefined) return "subscription";
    return "claudeCodeLogin";
  }

  /** True when work exhausting the subscription can continue on the API key. */
  canFallBack(route: CredentialRoute): boolean {
    return route === "subscription" && this.apiKey !== undefined;
  }

  /** `resetsAt` is in epoch seconds, as Claude reports it. */
  pauseSubscription(resetsAt?: number): void {
    const resetMilliseconds = resetsAt === undefined ? undefined : resetsAt * 1_000;
    this.subscriptionPausedUntil = resetMilliseconds !== undefined && resetMilliseconds > this.now()
      ? resetMilliseconds
      : this.now() + defaultPauseMilliseconds;
  }

  /**
   * The child environment for `route`: exactly one Claude credential under
   * the name Claude Code reads, and never the other slot.
   */
  environment(route: CredentialRoute, base: NodeJS.ProcessEnv): NodeJS.ProcessEnv {
    const environment: NodeJS.ProcessEnv = { ...base };
    delete environment[subscriptionTokenVariable];
    delete environment[apiKeyVariable];
    delete environment.CLAUDE_CODE_OAUTH_TOKEN;
    delete environment.ANTHROPIC_API_KEY;
    if (route === "subscription" && this.subscriptionToken !== undefined) {
      environment.CLAUDE_CODE_OAUTH_TOKEN = this.subscriptionToken;
    } else if (route === "apiKey" && this.apiKey !== undefined) {
      environment.ANTHROPIC_API_KEY = this.apiKey;
    }
    return environment;
  }
}

/**
 * Claude's wording when a subscription has used its allowance, or when the
 * account behind a credential has no credits left.
 */
export function isUsageLimitFailure(message: string): boolean {
  return /usage limit|limit reached|rate[ _-]?limit|out of (extra )?usage|credit balance is too low|credits? (are |is )?(exhausted|required)|billing_error|quota/i
    .test(message);
}

/** Claude has written `Claude AI usage limit reached|<epoch seconds>`. */
export function resetTimeFromFailure(message: string): number | undefined {
  const match = /\|(\d{9,11})\b/.exec(message);
  return match === null ? undefined : Number(match[1]);
}

function nonEmpty(value: string | undefined): string | undefined {
  const trimmed = value?.trim();
  return trimmed === undefined || trimmed.length === 0 ? undefined : trimmed;
}
