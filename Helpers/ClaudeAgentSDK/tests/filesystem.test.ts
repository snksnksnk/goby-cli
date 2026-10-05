import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtemp, mkdir, rename, rm, stat, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import {
  assertCapabilitiesCurrent,
  closeCapabilities,
  openDirectoryCapability,
  openRegularFileCapability,
} from "../src/filesystem.js";
import type { FileSystemIdentity } from "../src/protocol.js";

async function identityFor(
  target: string,
  kind: FileSystemIdentity["kind"],
): Promise<FileSystemIdentity> {
  const metadata = await stat(target, { bigint: true });
  return {
    device: metadata.dev.toString(),
    inode: metadata.ino.toString(),
    kind,
  };
}

test("unchanged directory identity remains valid when only its contents change", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "goby-provider-scope-"));
  try {
    const identity = await identityFor(root, "directory");
    const capability = await openDirectoryCapability(root, identity);
    await writeFile(path.join(root, "new.txt"), "new content");
    await assertCapabilitiesCurrent([capability]);
    await closeCapabilities([capability]);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("same-path directory replacement is rejected before and after admission", async () => {
  const parent = await mkdtemp(path.join(tmpdir(), "goby-provider-race-"));
  const reviewed = path.join(parent, "reviewed");
  const retained = path.join(parent, "retained");
  try {
    await mkdir(reviewed);
    const identity = await identityFor(reviewed, "directory");
    const admitted = await openDirectoryCapability(reviewed, identity);

    await rename(reviewed, retained);
    await mkdir(reviewed);
    await assert.rejects(openDirectoryCapability(reviewed, identity));
    await assert.rejects(assertCapabilitiesCurrent([admitted]));
    await closeCapabilities([admitted]);

    await rm(reviewed, { recursive: true, force: true });
    await symlink(retained, reviewed);
    await assert.rejects(openDirectoryCapability(reviewed, identity));
  } finally {
    await rm(parent, { recursive: true, force: true });
  }
});

test("identity fields reject number coercion and compare decimal strings exactly", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "goby-provider-integer-"));
  try {
    const identity = await identityFor(root, "directory");
    await assert.rejects(openDirectoryCapability(root, {
      ...identity,
      inode: 9_007_199_254_740_993 as unknown as string,
    }));
    await assert.rejects(openDirectoryCapability(root, {
      ...identity,
      inode: "9007199254740993",
    }));
    const capability = await openDirectoryCapability(root, identity);
    await closeCapabilities([capability]);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("local attachment identity and reviewed digest both remain required", async () => {
  const parent = await mkdtemp(path.join(tmpdir(), "goby-provider-attachment-"));
  const attachment = path.join(parent, "attachment.txt");
  try {
    const reviewedBytes = Buffer.from("reviewed bytes");
    await writeFile(attachment, reviewedBytes);
    const identity = await identityFor(attachment, "regularFile");
    const digest = createHash("sha256").update(reviewedBytes).digest("hex");
    const capability = await openRegularFileCapability(attachment, identity, digest);
    await closeCapabilities([capability]);

    await rm(attachment);
    await writeFile(attachment, "replacement bytes");
    await assert.rejects(openRegularFileCapability(attachment, identity, digest));
  } finally {
    await rm(parent, { recursive: true, force: true });
  }
});

test("an admitted attachment is rejected after same-inode content mutation", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "goby-claude-attachment-mutation-"));
  const attachment = path.join(root, "context.txt");
  await writeFile(attachment, "reviewed");
  const identity = await identityFor(attachment, "regularFile");
  const capability = await openRegularFileCapability(
    attachment,
    identity,
    createHash("sha256").update("reviewed").digest("hex"),
  );
  try {
    await writeFile(attachment, "changed!");
    await assert.rejects(assertCapabilitiesCurrent([capability]), /attachment changed after review/);
  } finally {
    await closeCapabilities([capability]);
    await rm(root, { recursive: true, force: true });
  }
});
