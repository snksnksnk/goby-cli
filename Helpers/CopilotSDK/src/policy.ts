import path from "node:path";
import { realpath } from "node:fs/promises";
import type { PermissionRequest } from "@github/copilot-sdk";
import type { ResourceGrant } from "./protocol.js";

export type PolicyContext = {
  cwd: string;
  resources: Array<Pick<ResourceGrant, "path" | "access">>;
};

export type PolicyDecision =
  | { behavior: "continue" }
  | { behavior: "deny"; reason: string };

const criticalShellPatterns: Array<{ pattern: RegExp; reason: string }> = [
  { pattern: /(?:^|[;&|]\s*)sudo(?:\s|$)/i, reason: "Elevated shell commands are not allowed through the Copilot bridge." },
  { pattern: /\brm\s+(?:-[^\s]*r[^\s]*f|-[^\s]*f[^\s]*r)\s+(?:\/|~(?:\/|\s|$)|\$HOME\b)/i, reason: "Recursive deletion of a broad system or home path is blocked." },
  { pattern: /\bgit\s+(?:reset\s+--hard|clean\s+-[^\s]*f)/i, reason: "Destructive Git history or working-copy cleanup is blocked by provider policy." },
  { pattern: /\b(?:diskutil\s+erase|shutdown|reboot|halt)\b/i, reason: "System-destructive commands are blocked by provider policy." },
];

export async function evaluateHardPolicy(
  request: PermissionRequest,
  context: PolicyContext,
): Promise<PolicyDecision> {
  switch (request.kind) {
    case "shell": {
      for (const rule of criticalShellPatterns) {
        if (rule.pattern.test(request.fullCommandText)) {
          return { behavior: "deny", reason: rule.reason };
        }
      }
      for (const candidate of request.possiblePaths) {
        const access = await accessForPath(candidate, context);
        if (access === "none") {
          return { behavior: "deny", reason: "This command targets a path outside the assignment working copy and its reviewed resources." };
        }
        if (access === "readOnly" && !request.commands.every((command) => command.readOnly)) {
          return { behavior: "deny", reason: "This command may write to a resource that was granted read-only access." };
        }
      }
      return { behavior: "continue" };
    }
    case "write": {
      const access = await accessForPath(request.fileName, context);
      if (access === "readWrite" || access === "project") return { behavior: "continue" };
      return {
        behavior: "deny",
        reason: access === "readOnly"
          ? "This resource was granted read-only access for the assignment."
          : "This write targets a path outside the assignment working copy and its reviewed resources.",
      };
    }
    case "read":
      return await accessForPath(request.path, context) === "none"
        ? { behavior: "deny", reason: "This read targets a path outside the assignment working copy and its reviewed resources." }
        : { behavior: "continue" };
    default:
      return { behavior: "continue" };
  }
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
