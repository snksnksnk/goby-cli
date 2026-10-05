import path from "node:path";
import { realpath } from "node:fs/promises";
import type { HookJSONOutput, PreToolUseHookInput } from "@anthropic-ai/claude-agent-sdk";
import type { ResourceGrant } from "./protocol.js";

export type PolicyContext = {
  cwd: string;
  resources: Array<Pick<ResourceGrant, "path" | "access">>;
};

export type PolicyDecision =
  | { behavior: "continue" }
  | { behavior: "deny"; reason: string };

const criticalShellPatterns: Array<{ pattern: RegExp; reason: string }> = [
  { pattern: /(?:^|[;&|]\s*)sudo(?:\s|$)/i, reason: "Elevated shell commands are not allowed through the Claude bridge." },
  { pattern: /\brm\s+(?:-[^\s]*r[^\s]*f|-[^\s]*f[^\s]*r)\s+(?:\/|~(?:\/|\s|$)|\$HOME\b)/i, reason: "Recursive deletion of a broad system or home path is blocked." },
  { pattern: /\bgit\s+(?:reset\s+--hard|clean\s+-[^\s]*f)/i, reason: "Destructive Git history or working-copy cleanup is blocked by provider policy." },
  { pattern: /\b(?:diskutil\s+erase|shutdown|reboot|halt)\b/i, reason: "System-destructive commands are blocked by provider policy." },
];

const readTools = new Set(["Read", "Glob", "Grep"]);
const writeTools = new Set(["Edit", "Write", "NotebookEdit", "MultiEdit"]);
const pathKeys = ["file_path", "path", "notebook_path"];

export async function evaluateHardPolicy(
  toolName: string,
  input: Record<string, unknown>,
  context: PolicyContext,
): Promise<PolicyDecision> {
  if (toolName === "Bash") {
    const command = typeof input.command === "string" ? input.command : "";
    for (const rule of criticalShellPatterns) {
      if (rule.pattern.test(command)) return { behavior: "deny", reason: rule.reason };
    }
    const blockedPath = typeof input.__gobyBlockedPath === "string" ? input.__gobyBlockedPath : undefined;
    if (blockedPath) {
      const access = await accessForPath(blockedPath, context);
      if (access === "none") {
        return { behavior: "deny", reason: "This command attempted to access a path outside the assignment working copy and its reviewed resources." };
      }
      if (access === "readOnly") {
        return { behavior: "deny", reason: "This command attempted to modify a resource that was granted read-only access." };
      }
    }
    return { behavior: "continue" };
  }

  if (!readTools.has(toolName) && !writeTools.has(toolName)) {
    return { behavior: "continue" };
  }

  const suppliedPath = pathKeys
    .map((key) => input[key])
    .find((value): value is string => typeof value === "string" && value.length > 0);
  if (!suppliedPath) return { behavior: "continue" };

  const access = await accessForPath(suppliedPath, context);
  if (access === "none") {
    return {
      behavior: "deny",
      reason: "This tool targets a path outside the assignment working copy and its reviewed resources.",
    };
  }
  if (writeTools.has(toolName) && access === "readOnly") {
    return {
      behavior: "deny",
      reason: "This resource was granted read-only access for the assignment.",
    };
  }
  return { behavior: "continue" };
}

export function makePreToolUseHook(context: PolicyContext) {
  return async (input: PreToolUseHookInput): Promise<HookJSONOutput> => {
    const toolInput = isRecord(input.tool_input) ? input.tool_input : {};
    const decision = await evaluateHardPolicy(input.tool_name, toolInput, context);
    if (decision.behavior === "continue") return {};
    return {
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: decision.reason,
      },
    };
  };
}

type PathAccess = "project" | "readOnly" | "readWrite" | "none";

async function accessForPath(candidate: string, context: PolicyContext): Promise<PathAccess> {
  try {
    const resolved = await canonicalizeAllowingMissing(path.resolve(context.cwd, candidate));
    const projectRoot = await canonicalizeAllowingMissing(path.resolve(context.cwd));
    if (isWithin(resolved, projectRoot)) return "project";
    for (const resource of context.resources) {
      const resourceRoot = await canonicalizeAllowingMissing(path.resolve(resource.path));
      if (isWithin(resolved, resourceRoot)) return resource.access;
    }
  } catch {
    return "none";
  }
  return "none";
}

async function canonicalizeAllowingMissing(candidate: string): Promise<string> {
  let cursor = candidate;
  const suffix: string[] = [];
  while (true) {
    try {
      const canonical = await realpath(cursor);
      return path.resolve(canonical, ...suffix);
    } catch (error) {
      if (!isMissingPathError(error)) throw error;
      const parent = path.dirname(cursor);
      if (parent === cursor) throw error;
      suffix.unshift(path.basename(cursor));
      cursor = parent;
    }
  }
}

function isMissingPathError(error: unknown): boolean {
  return typeof error === "object" && error !== null && "code" in error
    && ((error as { code?: unknown }).code === "ENOENT" || (error as { code?: unknown }).code === "ENOTDIR");
}

function isWithin(candidate: string, root: string): boolean {
  const relative = path.relative(root, candidate);
  return relative === "" || (!relative.startsWith(`..${path.sep}`) && relative !== ".." && !path.isAbsolute(relative));
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
