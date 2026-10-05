export type JSONRPCID = string | number;

export type JSONRPCRequest = {
  jsonrpc: "2.0";
  id: JSONRPCID;
  method: string;
  params?: unknown;
};

export type JSONRPCNotification = {
  jsonrpc: "2.0";
  method: string;
  params?: unknown;
};

export type IncomingJSONRPCMessage = JSONRPCRequest | JSONRPCNotification;

export type InitializeRequest = {
  clientInfo?: { name?: string; version?: string };
};

export type FileSystemIdentity = {
  device: string;
  inode: string;
  kind: "directory" | "regularFile";
};

export type ResourceGrant = {
  path: string;
  access: "readOnly" | "readWrite";
  identity: FileSystemIdentity;
};

export type AttachmentGrant = {
  id: string;
  path: string;
  displayName: string;
  kind: "file" | "image" | "snippet";
  identity: FileSystemIdentity;
  contentSHA256: string;
};

export type StartAssignmentRequest = {
  assignmentId: string;
  prompt: string;
  cwd: string;
  cwdIdentity: FileSystemIdentity;
  agentName: string;
  agentSummary: string;
  agentInstructions?: string;
  instructionPacks?: Array<{ name: string; version: number; body: string }>;
  resources?: ResourceGrant[];
  attachments?: AttachmentGrant[];
  risk: "readOnly" | "low" | "medium" | "high";
  model?: string;
};

export type ApprovalDecision =
  | "accept"
  | "acceptForSession"
  | "acceptAllForRun"
  | "decline"
  | "cancel";

export type ApprovalResponseRequest = {
  approvalId: string;
  assignmentId: string;
  decision: ApprovalDecision;
  operationDigest?: string;
};

export type InterruptAssignmentRequest = { assignmentId: string };

export type ListTasksRequest = {
  projects: Array<{
    projectId: string;
    rootPath: string;
    rootIdentity: FileSystemIdentity;
  }>;
  limitPerProject?: number;
};

export class JSONRPCError extends Error {
  constructor(
    readonly code: number,
    message: string,
    readonly data?: unknown,
  ) {
    super(message);
    this.name = "JSONRPCError";
  }
}

export type ProtocolWriter = (value: unknown) => void;

export function sendResult(writer: ProtocolWriter, id: JSONRPCID, result: unknown): void {
  writer({ jsonrpc: "2.0", id, result });
}

export function sendError(writer: ProtocolWriter, id: JSONRPCID, error: unknown): void {
  const rpcError = error instanceof JSONRPCError
    ? error
    : new JSONRPCError(-32603, describeError(error));
  writer({
    jsonrpc: "2.0",
    id,
    error: {
      code: rpcError.code,
      message: rpcError.message,
      ...(rpcError.data === undefined ? {} : { data: rpcError.data }),
    },
  });
}

export function sendNotification(writer: ProtocolWriter, method: string, params: unknown): void {
  writer({ jsonrpc: "2.0", method, params });
}

export function describeError(error: unknown): string {
  const fallback = "Unknown GitHub Copilot bridge error.";
  const source = error instanceof Error
    ? error.message
    : typeof error === "string"
      ? error
      : fallback;
  return sanitizeErrorDescription(source, fallback);
}

function sanitizeErrorDescription(source: string, fallback: string): string {
  const redacted = source
    .replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g, " ")
    .replace(/\bBearer\s+[A-Za-z0-9._~+\/-]+=*/gi, "Bearer [redacted]")
    .replace(/\b([A-Z][A-Z0-9_]*(?:API_KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL)[A-Z0-9_]*|(?:api[_ -]?key|token|secret|password|credential)s?)\s*[:=]\s*([^\s,;]+)/gi, "$1=[redacted]")
    .replace(/([?&](?:key|token|secret|signature|credential)=)[^&\s]+/gi, "$1[redacted]")
    .replace(/(?:file:\/\/)?\/(?:Users|home|private|var|tmp)\/[^\s,;:)]+/g, "[path redacted]")
    .replace(/[A-Za-z]:\\[^\s,;:)]+/g, "[path redacted]")
    .replace(/\s+/g, " ")
    .trim();
  return (redacted || fallback).slice(0, 1_000);
}

export function requireObject<T extends object>(value: unknown, label: string): T {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new JSONRPCError(-32602, `${label} must be an object.`);
  }
  return value as T;
}
