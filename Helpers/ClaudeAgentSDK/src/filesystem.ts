import { createHash } from "node:crypto";
import { constants, type BigIntStats } from "node:fs";
import path from "node:path";
import { open, realpath, type FileHandle } from "node:fs/promises";
import {
  JSONRPCError,
  type FileSystemIdentity,
} from "./protocol.js";

const maximumAttachmentBytes = 25 * 1_024 * 1_024;
const unsignedDecimal = /^(0|[1-9][0-9]{0,19})$/;
const maximumUInt64 = (1n << 64n) - 1n;

export type FileSystemCapability = {
  originalPath: string;
  canonicalPath: string;
  identity: FileSystemIdentity;
  contentSHA256?: string;
  handle: FileHandle;
};

export async function openDirectoryCapability(
  input: string,
  identity: FileSystemIdentity,
  label = "directory",
): Promise<FileSystemCapability> {
  return openCapability(input, identity, "directory", label);
}

export async function openRegularFileCapability(
  input: string,
  identity: FileSystemIdentity,
  contentSHA256: string,
  label = "attachment",
): Promise<FileSystemCapability> {
  const capability = await openCapability(input, identity, "regularFile", label);
  try {
    if (!/^[a-f0-9]{64}$/.test(contentSHA256)) {
      throw new JSONRPCError(-32602, `${label} has an invalid content digest.`);
    }
    const actualDigest = await digestRegularFile(capability, maximumAttachmentBytes);
    if (actualDigest !== contentSHA256) {
      throw new JSONRPCError(-32602, `${label} changed after review.`);
    }
    capability.contentSHA256 = contentSHA256;
    return capability;
  } catch (error) {
    await capability.handle.close().catch(() => {});
    throw error;
  }
}

export async function assertCapabilitiesCurrent(
  capabilities: readonly FileSystemCapability[],
): Promise<void> {
  for (const capability of capabilities) {
    validateMetadata(
      await capability.handle.stat({ bigint: true }),
      capability.identity,
      capability.identity.kind,
      "reviewed file-system scope",
    );
    await assertPathIdentity(
      capability.originalPath,
      capability.identity,
      capability.identity.kind,
      "reviewed file-system scope",
    );
    await assertPathIdentity(
      capability.canonicalPath,
      capability.identity,
      capability.identity.kind,
      "reviewed file-system scope",
    );
    if (capability.contentSHA256 !== undefined) {
      const actualDigest = await digestRegularFile(capability, maximumAttachmentBytes);
      if (actualDigest !== capability.contentSHA256) {
        throw new JSONRPCError(-32602, "attachment changed after review.");
      }
    }
  }
}

export async function closeCapabilities(
  capabilities: readonly FileSystemCapability[],
): Promise<void> {
  await Promise.all(capabilities.map(async (capability) => {
    await capability.handle.close().catch(() => {});
  }));
}

async function openCapability(
  input: string,
  identity: FileSystemIdentity,
  expectedKind: FileSystemIdentity["kind"],
  label: string,
): Promise<FileSystemCapability> {
  validateIdentity(identity, expectedKind, label);
  if (!path.isAbsolute(input) || input.includes("\0")) {
    throw new JSONRPCError(-32602, `${label} must use an absolute local path.`);
  }

  const flags = constants.O_RDONLY
    | constants.O_NOFOLLOW
    | (expectedKind === "directory" ? constants.O_DIRECTORY : 0);
  let handle: FileHandle;
  try {
    handle = await open(input, flags);
  } catch {
    throw new JSONRPCError(-32602, `${label} could not be opened without following a link.`);
  }

  try {
    validateMetadata(await handle.stat({ bigint: true }), identity, expectedKind, label);
    const canonicalPath = await realpath(input);
    await assertPathIdentity(canonicalPath, identity, expectedKind, label);
    return { originalPath: input, canonicalPath, identity, handle };
  } catch (error) {
    await handle.close().catch(() => {});
    throw error;
  }
}

async function assertPathIdentity(
  input: string,
  identity: FileSystemIdentity,
  expectedKind: FileSystemIdentity["kind"],
  label: string,
): Promise<void> {
  const flags = constants.O_RDONLY
    | constants.O_NOFOLLOW
    | (expectedKind === "directory" ? constants.O_DIRECTORY : 0);
  let handle: FileHandle;
  try {
    handle = await open(input, flags);
  } catch {
    throw new JSONRPCError(-32602, `${label} changed after review.`);
  }
  try {
    validateMetadata(await handle.stat({ bigint: true }), identity, expectedKind, label);
  } finally {
    await handle.close().catch(() => {});
  }
}

function validateIdentity(
  identity: FileSystemIdentity,
  expectedKind: FileSystemIdentity["kind"],
  label: string,
): void {
  if (identity === null || typeof identity !== "object") {
    throw new JSONRPCError(-32602, `${label} is missing its reviewed file-system identity.`);
  }
  if (
    !unsignedDecimal.test(identity.device)
    || !unsignedDecimal.test(identity.inode)
    || BigInt(identity.device) > maximumUInt64
    || BigInt(identity.inode) > maximumUInt64
    || identity.kind !== expectedKind
  ) {
    throw new JSONRPCError(-32602, `${label} has an invalid reviewed file-system identity.`);
  }
}

function validateMetadata(
  metadata: BigIntStats,
  identity: FileSystemIdentity,
  expectedKind: FileSystemIdentity["kind"],
  label: string,
): void {
  const kindMatches = expectedKind === "directory"
    ? metadata.isDirectory()
    : metadata.isFile();
  if (
    !kindMatches
    || metadata.dev.toString() !== identity.device
    || metadata.ino.toString() !== identity.inode
  ) {
    throw new JSONRPCError(-32602, `${label} changed after review.`);
  }
}

async function digestRegularFile(
  capability: FileSystemCapability,
  maximumBytes: number,
): Promise<string> {
  const before = await capability.handle.stat({ bigint: true });
  if (before.size < 0n || before.size > BigInt(maximumBytes)) {
    throw new JSONRPCError(-32602, "attachment exceeds the provider input limit.");
  }
  const digest = createHash("sha256");
  const buffer = Buffer.allocUnsafe(1_048_576);
  let position = 0;
  while (true) {
    const read = await capability.handle.read(buffer, 0, buffer.length, position);
    if (read.bytesRead === 0) break;
    position += read.bytesRead;
    if (position > maximumBytes) {
      throw new JSONRPCError(-32602, "attachment exceeds the provider input limit.");
    }
    digest.update(buffer.subarray(0, read.bytesRead));
  }
  const after = await capability.handle.stat({ bigint: true });
  validateMetadata(after, capability.identity, "regularFile", "attachment");
  if (after.size !== before.size || after.size !== BigInt(position)) {
    throw new JSONRPCError(-32602, "attachment changed while it was being verified.");
  }
  return digest.digest("hex");
}
