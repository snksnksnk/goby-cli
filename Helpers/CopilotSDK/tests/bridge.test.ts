import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import type { PermissionRequest } from "@github/copilot-sdk";
import {
  CopilotBridge,
  permissionResult,
  providerChildEnvironment,
  providerExcludedTools,
} from "../src/bridge.js";
import { evaluateHardPolicy } from "../src/policy.js";
import { describeError } from "../src/protocol.js";

test("protocol negotiation and missing-credential account check make no SDK request", async () => {
  const original = process.env.GOBY_COPILOT_GITHUB_TOKEN;
  delete process.env.GOBY_COPILOT_GITHUB_TOKEN;
  try {
    const bridge = new CopilotBridge(() => {});
    const initialized = await bridge.handle("initialize", {
      clientInfo: { name: "test", version: "0.2.0-beta.1" },
    }) as Record<string, unknown>;
    const account = await bridge.handle("account/read", {}) as Record<string, unknown>;

    assert.equal(initialized.providerId, "github-copilot");
    assert.equal(initialized.protocolVersion, "1.1");
    assert.equal(initialized.sdkVersion, "1.0.13");
    assert.equal(account.connectionState, "needsAuthentication");
    assert.equal(account.credentialConfigured, false);
  } finally {
    if (original === undefined) delete process.env.GOBY_COPILOT_GITHUB_TOKEN;
    else process.env.GOBY_COPILOT_GITHUB_TOKEN = original;
  }
});

test("Copilot child environment excludes provider bootstrap and Claude credentials", () => {
  const environment = providerChildEnvironment({
    PATH: "/usr/bin",
    GOBY_COPILOT_GITHUB_TOKEN: "selected-copilot-token",
    GITHUB_TOKEN: "github-token",
    ANTHROPIC_API_KEY: "anthropic-key",
    CLAUDE_CODE_OAUTH_TOKEN: "claude-token",
  });

  assert.equal(environment.PATH, "/usr/bin");
  assert.equal(environment.GOBY_COPILOT_GITHUB_TOKEN, undefined);
  assert.equal(environment.GITHUB_TOKEN, undefined);
  assert.equal(environment.ANTHROPIC_API_KEY, undefined);
  assert.equal(environment.CLAUDE_CODE_OAUTH_TOKEN, undefined);
});

test("Copilot excludes arbitrary shell execution from the credentialed runtime", () => {
  assert.deepEqual(providerExcludedTools(), ["manage_schedule", "shell"]);
});

test("provider errors are bounded and redact credentials and host paths", () => {
  const message = describeError(new Error(
    `Bearer abc.def GITHUB_TOKEN=super-secret at /Users/alice/private/project?token=query-secret ${"x".repeat(2_000)}`,
  ));

  assert.equal(message.includes("abc.def"), false);
  assert.equal(message.includes("super-secret"), false);
  assert.equal(message.includes("/Users/alice"), false);
  assert.equal(message.includes("query-secret"), false);
  assert.equal(message.length <= 1_000, true);
});

test("hard policy blocks broad destructive commands and paths outside reviewed roots", async () => {
  const context = {
    cwd: "/workspace/project",
    resources: [{ path: "/workspace/reference", access: "readOnly" as const }],
  };
  const destructive = {
    kind: "shell",
    fullCommandText: "sudo rm -rf /",
    commands: [{ identifier: "sudo", readOnly: false }],
    possiblePaths: ["/"],
  } as PermissionRequest;
  const outsideWrite = {
    kind: "write",
    fileName: "/workspace/other/file.swift",
    intention: "Edit another project",
  } as PermissionRequest;
  const reviewedRead = {
    kind: "read",
    path: "/workspace/reference/README.md",
    intention: "Read reference",
  } as PermissionRequest;
  const readOnlyWrite = {
    kind: "write",
    fileName: "/workspace/reference/README.md",
    intention: "Edit reference",
  } as PermissionRequest;

  assert.equal((await evaluateHardPolicy(destructive, context)).behavior, "deny");
  assert.equal((await evaluateHardPolicy(outsideWrite, context)).behavior, "deny");
  assert.equal((await evaluateHardPolicy(reviewedRead, context)).behavior, "continue");
  assert.equal((await evaluateHardPolicy(readOnlyWrite, context)).behavior, "deny");
});

test("hard policy rejects a project symlink that escapes the reviewed root", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "goby-copilot-policy-"));
  try {
    const project = path.join(root, "project");
    const outside = path.join(root, "outside");
    await mkdir(project);
    await mkdir(outside);
    await symlink(outside, path.join(project, "linked"));
    const request = {
      kind: "write",
      fileName: path.join(project, "linked", "new-file.txt"),
      intention: "Write through a symlink",
    } as PermissionRequest;

    assert.equal((await evaluateHardPolicy(request, { cwd: project, resources: [] })).behavior, "deny");
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("hard policy grants an attachment as one exact read-only file", async () => {
  const context = {
    cwd: "/workspace/project",
    resources: [{ path: "/private/staged/context.txt", access: "readOnly" as const }],
  };
  const exactRead = {
    kind: "read",
    path: "/private/staged/context.txt",
    intention: "Read reviewed context",
  } as PermissionRequest;
  const siblingRead = {
    kind: "read",
    path: "/private/staged/sibling.txt",
    intention: "Read unreviewed context",
  } as PermissionRequest;
  const attachmentWrite = {
    kind: "write",
    fileName: "/private/staged/context.txt",
    intention: "Modify reviewed context",
  } as PermissionRequest;

  assert.equal((await evaluateHardPolicy(exactRead, context)).behavior, "continue");
  assert.equal((await evaluateHardPolicy(siblingRead, context)).behavior, "deny");
  assert.equal((await evaluateHardPolicy(attachmentWrite, context)).behavior, "deny");
});

test("session approval never invents a broader rule for unsupported requests", () => {
  const unsupported = { kind: "hook" } as PermissionRequest;
  const shellWithoutSessionScope = {
    kind: "shell",
    canOfferSessionApproval: false,
    commands: [{ identifier: "swift", readOnly: true }],
  } as PermissionRequest;
  const url = {
    kind: "url",
    url: "https://api.github.com/repos/octo/example",
  } as PermissionRequest;
  const read = {
    kind: "read",
    path: "/workspace/project/README.md",
    intention: "Read project documentation",
    canOfferSessionApproval: true,
  } as PermissionRequest;

  assert.deepEqual(permissionResult("acceptForSession", unsupported), {
    kind: "approve-once",
    approvedInteractively: true,
  });
  assert.deepEqual(permissionResult("acceptForSession", shellWithoutSessionScope), {
    kind: "approve-once",
    approvedInteractively: true,
  });
  assert.deepEqual(permissionResult("acceptForSession", url), {
    kind: "approve-for-session",
    domain: "api.github.com",
  });
  assert.deepEqual(permissionResult("acceptForSession", read), {
    kind: "approve-once",
    approvedInteractively: true,
  });
});
