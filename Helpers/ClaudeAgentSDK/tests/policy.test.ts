import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { evaluateHardPolicy } from "../src/policy.js";

const context = {
  cwd: "/work/project",
  resources: [
    { path: "/shared/read-only", access: "readOnly" as const },
    { path: "/shared/editable", access: "readWrite" as const },
  ],
};

test("allows project paths", async () => {
  assert.deepEqual(
    await evaluateHardPolicy("Edit", { file_path: "Sources/App.swift" }, context),
    { behavior: "continue" },
  );
});

test("blocks paths outside the project and reviewed resources", async () => {
  const decision = await evaluateHardPolicy("Read", { file_path: "/private/secrets.txt" }, context);
  assert.equal(decision.behavior, "deny");
});

test("enforces a read-only resource grant", async () => {
  const decision = await evaluateHardPolicy("Write", { file_path: "/shared/read-only/report.md" }, context);
  assert.equal(decision.behavior, "deny");
});

test("allows only the exact reviewed attachment path", async () => {
  const attachmentContext = {
    cwd: "/work/project",
    resources: [{ path: "/private/staged/context.txt", access: "readOnly" as const }],
  };
  assert.deepEqual(
    await evaluateHardPolicy("Read", { file_path: "/private/staged/context.txt" }, attachmentContext),
    { behavior: "continue" },
  );
  assert.equal(
    (await evaluateHardPolicy("Read", { file_path: "/private/staged/sibling.txt" }, attachmentContext)).behavior,
    "deny",
  );
  assert.equal(
    (await evaluateHardPolicy("Write", { file_path: "/private/staged/context.txt" }, attachmentContext)).behavior,
    "deny",
  );
});

test("allows a write into a reviewed read-write resource", async () => {
  assert.deepEqual(
    await evaluateHardPolicy("Write", { file_path: "/shared/editable/report.md" }, context),
    { behavior: "continue" },
  );
});

test("blocks broad deletion and destructive git commands", async () => {
  assert.equal((await evaluateHardPolicy("Bash", { command: "rm -rf /" }, context)).behavior, "deny");
  assert.equal((await evaluateHardPolicy("Bash", { command: "git reset --hard HEAD~1" }, context)).behavior, "deny");
  assert.equal((await evaluateHardPolicy("Bash", { command: "git clean -fd" }, context)).behavior, "deny");
});

test("leaves ordinary commands for Goby approval", async () => {
  assert.deepEqual(
    await evaluateHardPolicy("Bash", { command: "swift test" }, context),
    { behavior: "continue" },
  );
});

test("rejects project paths whose existing ancestor is a symlink escape", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "goby-claude-policy-"));
  try {
    const project = path.join(root, "project");
    const outside = path.join(root, "outside");
    await mkdir(project);
    await mkdir(outside);
    await symlink(outside, path.join(project, "linked"));

    const decision = await evaluateHardPolicy(
      "Write",
      { file_path: path.join(project, "linked", "new-file.txt") },
      { cwd: project, resources: [] },
    );
    assert.equal(decision.behavior, "deny");
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("rejects a sandbox-reported Bash path outside reviewed roots", async () => {
  const decision = await evaluateHardPolicy(
    "Bash",
    { command: "cat file", __gobyBlockedPath: "/private/secret" },
    context,
  );
  assert.equal(decision.behavior, "deny");
});
