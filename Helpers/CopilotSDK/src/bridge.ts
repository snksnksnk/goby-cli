import { randomUUID } from "node:crypto";
import { mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  CopilotClient,
  type CopilotSession,
  type PermissionRequest,
  type PermissionRequestResult,
  type SessionEvent,
} from "@github/copilot-sdk";
import { evaluateHardPolicy } from "./policy.js";
import {
  approvalBindingIsValid,
  canonicalApprovalDisclosure,
} from "./approval.js";
import {
  assertCapabilitiesCurrent,
  closeCapabilities,
  openDirectoryCapability,
  openRegularFileCapability,
  type FileSystemCapability,
} from "./filesystem.js";
import {
  JSONRPCError,
  describeError,
  requireObject,
  sendNotification,
  type ApprovalDecision,
  type ApprovalResponseRequest,
  type AttachmentGrant,
  type InitializeRequest,
  type InterruptAssignmentRequest,
  type ListTasksRequest,
  type ProtocolWriter,
  type ResourceGrant,
  type StartAssignmentRequest,
} from "./protocol.js";

const helperVersion = "0.2.0-beta.1";
const sdkVersion = "1.0.13";
const protocolVersion = "1.1";

type UsageSnapshot = {
  inputTokens?: number;
  outputTokens?: number;
  nanoAIU?: number;
};

type TrackedToolCall = {
  id: string;
  name: string;
  input: unknown;
};

type ActiveAssignment = {
  assignmentId: string;
  cwd: string;
  session: CopilotSession;
  unsubscribe: () => void;
  resources: Array<Pick<ResourceGrant, "path" | "access">>;
  fileSystemCapabilities: FileSystemCapability[];
  trackedToolCalls: Map<string, TrackedToolCall>;
  lastAssistantText?: string;
  sent: boolean;
  terminal: boolean;
};

type PendingApproval = {
  assignmentId: string;
  request: PermissionRequest;
  operationDigest: string | undefined;
  disclosureComplete: boolean;
  resolve: (result: PermissionRequestResult) => void;
};

export class CopilotBridge {
  private client: CopilotClient | undefined;
  private runtimeVersion: string | undefined;
  private connectionState: "notChecked" | "connected" | "needsAuthentication" | "failed" = "notChecked";
  private login: string | undefined;
  private authType: string | undefined;
  private availableModels: Array<{ id: string; name: string }> = [];
  private lastUsage: UsageSnapshot = {};
  private readonly activeAssignments = new Map<string, ActiveAssignment>();
  private readonly pendingApprovals = new Map<string, PendingApproval>();

  constructor(private readonly writer: ProtocolWriter) {}

  async handle(method: string, rawParams: unknown): Promise<unknown> {
    switch (method) {
      case "initialize":
        return this.initialize(requireObject<InitializeRequest>(rawParams ?? {}, "initialize params"));
      case "account/read":
        return this.accountSnapshot();
      case "tasks/list":
        return this.listTasks(requireObject<ListTasksRequest>(rawParams, "tasks/list params"));
      case "assignment/start":
        return this.startAssignment(requireObject<StartAssignmentRequest>(rawParams, "assignment/start params"));
      case "assignment/interrupt":
        return this.interruptAssignment(requireObject<InterruptAssignmentRequest>(rawParams, "assignment/interrupt params"));
      case "approval/respond":
        return this.respondToApproval(requireObject<ApprovalResponseRequest>(rawParams, "approval/respond params"));
      case "shutdown":
        return this.shutdown();
      default:
        throw new JSONRPCError(-32601, `Unknown GitHub Copilot bridge method: ${method}`);
    }
  }

  private initialize(_request: InitializeRequest): unknown {
    return {
      protocolVersion,
      helperVersion,
      sdkVersion,
      providerId: "github-copilot",
      capabilities: [
        "accountInspection",
        "taskDiscovery",
        "execution",
        "interruption",
        "resume",
        "approvals",
        "usageReporting",
        "hooks",
      ],
    };
  }

  private async accountSnapshot(): Promise<unknown> {
    if (!configuredToken()) {
      this.connectionState = "needsAuthentication";
      return this.accountResponse();
    }
    try {
      const client = await this.ensureClient();
      const [status, auth, models] = await Promise.all([
        client.getStatus(),
        client.getAuthStatus(),
        client.listModels(),
      ]);
      this.runtimeVersion = status.version;
      this.login = auth.login;
      this.authType = auth.authType;
      this.connectionState = auth.isAuthenticated ? "connected" : "needsAuthentication";
      this.availableModels = models
        .filter((model) => model.policy?.state !== "disabled")
        .map((model) => ({ id: model.id, name: model.name }));
      return this.accountResponse(auth.statusMessage);
    } catch (error) {
      this.updateConnectionFromError(describeError(error));
      return this.accountResponse(describeError(error));
    }
  }

  private accountResponse(statusMessage?: string): unknown {
    return {
      connectionState: this.connectionState,
      credentialConfigured: Boolean(configuredToken()),
      credentialSource: configuredToken() ? "goby-keychain" : undefined,
      login: this.login,
      authType: this.authType,
      runtimeVersion: this.runtimeVersion,
      selectedModel: undefined,
      availableModels: this.availableModels,
      usage: this.lastUsage,
      statusMessage,
      observedAt: new Date().toISOString(),
    };
  }

  private async listTasks(request: ListTasksRequest): Promise<unknown> {
    const client = await this.ensureAuthenticatedClient();
    const limit = Math.min(Math.max(request.limitPerProject ?? 20, 1), 100);
    const groups = await Promise.all(request.projects.map(async (project) => {
      const capability = await openDirectoryCapability(
        project.rootPath,
        project.rootIdentity,
        "project root",
      );
      try {
        await assertCapabilitiesCurrent([capability]);
        const sessions = await client.listSessions({ workingDirectory: capability.canonicalPath });
        return sessions
          .sort((left, right) => right.modifiedTime.getTime() - left.modifiedTime.getTime())
          .slice(0, limit)
          .map((session) => ({
            projectId: project.projectId,
            sessionId: session.sessionId,
            title: session.summary ?? "GitHub Copilot session",
            summary: session.summary,
            updatedAt: session.modifiedTime.toISOString(),
            createdAt: session.startTime.toISOString(),
            cwd: session.context?.workingDirectory ?? capability.canonicalPath,
          }));
      } finally {
        await closeCapabilities([capability]);
      }
    }));
    return { tasks: groups.flat() };
  }

  private async startAssignment(request: StartAssignmentRequest): Promise<unknown> {
    validateStartRequest(request);
    if (this.activeAssignments.has(request.assignmentId)) {
      throw new JSONRPCError(-32010, `Assignment ${request.assignmentId} is already active.`);
    }

    const client = await this.ensureAuthenticatedClient();
    const fileSystemCapabilities: FileSystemCapability[] = [];
    let cwdCapability: FileSystemCapability;
    const resourceCapabilities: FileSystemCapability[] = [];
    const attachmentCapabilities: FileSystemCapability[] = [];
    try {
      cwdCapability = await openDirectoryCapability(request.cwd, request.cwdIdentity, "working directory");
      fileSystemCapabilities.push(cwdCapability);
      for (const resource of request.resources ?? []) {
        const capability = await openDirectoryCapability(resource.path, resource.identity, "shared resource");
        resourceCapabilities.push(capability);
        fileSystemCapabilities.push(capability);
      }
      for (const attachment of request.attachments ?? []) {
        const capability = await openRegularFileCapability(
          attachment.path,
          attachment.identity,
          attachment.contentSHA256,
          "local attachment",
        );
        attachmentCapabilities.push(capability);
        fileSystemCapabilities.push(capability);
      }
      await assertCapabilitiesCurrent(fileSystemCapabilities);
    } catch (error) {
      await closeCapabilities(fileSystemCapabilities);
      throw error;
    }
    const cwd = cwdCapability.canonicalPath;
    const resources = (request.resources ?? []).map((resource, index) => ({
      ...resource,
      path: resourceCapabilities[index]!.canonicalPath,
    }));
    const attachments = (request.attachments ?? []).map((attachment, index) => ({
      ...attachment,
      path: attachmentCapabilities[index]!.canonicalPath,
    }));
    const policyResources: Array<Pick<ResourceGrant, "path" | "access">> = [
      ...resources,
      ...attachments.map((attachment) => ({ path: attachment.path, access: "readOnly" as const })),
    ];
    let active: ActiveAssignment | undefined;
    const permissionHandler = async (permission: PermissionRequest): Promise<PermissionRequestResult> => {
      if (!active) return { kind: "user-not-available" };
      try {
        await assertCapabilitiesCurrent(active.fileSystemCapabilities);
      } catch {
        await active.session.abort().catch(() => {});
        return {
          kind: "reject",
          feedback: "A reviewed file-system scope changed. The assignment was interrupted.",
        };
      }
      return this.requestApproval(active, permission);
    };
    const onEvent = (event: SessionEvent): void => {
      if (active) this.consumeEvent(active, event);
    };
    let session: CopilotSession;
    try {
      await assertCapabilitiesCurrent(fileSystemCapabilities);
      session = await client.createSession({
      sessionId: request.assignmentId,
      model: request.model ?? "auto",
      clientName: `goby-agentic-dashboard/${helperVersion}`,
      workingDirectory: cwd,
      additionalDirectories: resources.map((resource) => resource.path),
      systemMessage: { mode: "append", content: makeSystemPrompt(request, resources) },
      availableTools: ["builtin:*"],
      // The pinned native runtime receives COPILOT_SDK_AUTH_TOKEN during
      // bootstrap. Its source is not distributed, so keep arbitrary command
      // execution unavailable rather than trusting a child-environment scrub
      // that Goby cannot independently verify.
      excludedTools: providerExcludedTools(),
      enableConfigDiscovery: false,
      skipCustomInstructions: true,
      customAgentsLocalOnly: true,
      coauthorEnabled: false,
      manageScheduleEnabled: false,
      enableFileHooks: false,
      enableHostGitOperations: true,
      enableSkills: false,
      enableSessionStore: true,
      enableSessionTelemetry: false,
      memory: { enabled: false },
      remoteSession: "off",
      onPermissionRequest: permissionHandler,
      onEvent,
      });
    } catch (error) {
      await closeCapabilities(fileSystemCapabilities);
      throw error;
    }
    active = {
      assignmentId: request.assignmentId,
      cwd,
      session,
      unsubscribe: () => {},
      resources: policyResources,
      fileSystemCapabilities,
      trackedToolCalls: new Map(),
      sent: false,
      terminal: false,
    };
    this.activeAssignments.set(request.assignmentId, active);

    try {
      await assertCapabilitiesCurrent(fileSystemCapabilities);
      const messageId = await session.send({
        prompt: promptWithVerifiedAttachments(request.prompt, attachments),
      });
      active.sent = true;
      this.connectionState = "connected";
      sendNotification(this.writer, "assignment/started", {
        assignmentId: request.assignmentId,
        sessionId: session.sessionId,
        messageId,
        model: request.model ?? "auto",
      });
      return { taskId: session.sessionId, turnId: messageId };
    } catch (error) {
      this.finishWithFailure(active, describeError(error));
      throw new JSONRPCError(-32020, describeError(error));
    }
  }

  private async requestApproval(
    active: ActiveAssignment,
    request: PermissionRequest,
  ): Promise<PermissionRequestResult> {
    const policy = await evaluateHardPolicy(request, { cwd: active.cwd, resources: active.resources });
    if (policy.behavior === "deny") {
      return Promise.resolve({ kind: "reject", feedback: policy.reason });
    }
    const approvalId = randomUUID();
    const disclosure = canonicalApprovalDisclosure(request);
    return new Promise<PermissionRequestResult>((resolve) => {
      this.pendingApprovals.set(approvalId, {
        assignmentId: active.assignmentId,
        request,
        operationDigest: disclosure.operationDigest,
        disclosureComplete: disclosure.disclosureComplete,
        resolve,
      });
      sendNotification(this.writer, "approval/required", {
        approvalId,
        assignmentId: active.assignmentId,
        kind: approvalKind(request),
        summary: approvalSummary(request),
        details: disclosure.details,
        canAccept: disclosure.disclosureComplete,
        operationDigest: disclosure.operationDigest,
        disclosureComplete: disclosure.disclosureComplete,
        approvalSessionId: active.session.sessionId,
        managedApprovalRequired: request.managedApprovalRequired === true,
      });
    });
  }

  private consumeEvent(active: ActiveAssignment, event: SessionEvent): void {
    if (active.terminal) return;
    switch (event.type) {
      case "assistant.message": {
        const message = event.data.content.trim();
        if (message.length > 0) {
          active.lastAssistantText = message;
          sendNotification(this.writer, "assignment/progress", {
            assignmentId: active.assignmentId,
            message,
          });
        }
        return;
      }
      case "assistant.usage": {
        this.lastUsage = {
          inputTokens: (this.lastUsage.inputTokens ?? 0) + (event.data.inputTokens ?? 0),
          outputTokens: (this.lastUsage.outputTokens ?? 0) + (event.data.outputTokens ?? 0),
          nanoAIU: (this.lastUsage.nanoAIU ?? 0) + (event.data.copilotUsage?.totalNanoAiu ?? 0),
        };
        sendNotification(this.writer, "usage/updated", {
          assignmentId: active.assignmentId,
          ...this.lastUsage,
          isEstimate: false,
        });
        return;
      }
      case "tool.execution_start":
        active.trackedToolCalls.set(event.data.toolCallId, {
          id: event.data.toolCallId,
          name: event.data.toolName,
          input: event.data.arguments,
        });
        return;
      case "tool.execution_complete": {
        const call = active.trackedToolCalls.get(event.data.toolCallId);
        active.trackedToolCalls.delete(event.data.toolCallId);
        sendNotification(this.writer, "command/completed", {
          assignmentId: active.assignmentId,
          evidenceId: event.data.toolCallId,
          command: call === undefined ? event.data.toolCallId : commandFor(call),
          actionCommands: call?.name === "shell" ? [] : [call?.name ?? "tool"],
          workingDirectory: active.cwd,
          status: event.data.success ? "completed" : "failed",
          exitCode: event.data.success ? 0 : 1,
          source: "GitHub Copilot SDK",
          outputSummary: clip(event.data.result?.detailedContent ?? event.data.result?.content ?? event.data.error?.message ?? "", 2_000),
        });
        return;
      }
      case "session.error":
        this.updateConnectionFromError(event.data.message, event.data.errorType);
        this.finishWithFailure(active, event.data.message);
        return;
      case "session.idle":
        if (active.sent) this.finishWithSuccess(active, active.lastAssistantText ?? "GitHub Copilot finished without a final assistant message.");
        return;
      default:
        return;
    }
  }

  private async interruptAssignment(request: InterruptAssignmentRequest): Promise<unknown> {
    const active = this.activeAssignments.get(request.assignmentId);
    if (!active) throw new JSONRPCError(-32011, `Assignment ${request.assignmentId} is not active.`);
    this.denyApprovalsForAssignment(request.assignmentId, "The GitHub Copilot assignment was interrupted.");
    await active.session.abort();
    return { interrupted: true };
  }

  private async respondToApproval(request: ApprovalResponseRequest): Promise<unknown> {
    const pending = this.pendingApprovals.get(request.approvalId);
    if (!pending) throw new JSONRPCError(-32012, `Approval ${request.approvalId} is not pending.`);
    if (request.assignmentId !== pending.assignmentId) {
      throw new JSONRPCError(
        -32013,
        `Approval ${request.approvalId} does not belong to assignment ${request.assignmentId}.`,
      );
    }
    this.pendingApprovals.delete(request.approvalId);
    const active = this.activeAssignments.get(pending.assignmentId);
    if (!active) {
      pending.resolve({ kind: "reject", feedback: "The assignment ended before this approval was applied." });
      return { resolved: true };
    }
    try {
      await assertCapabilitiesCurrent(active.fileSystemCapabilities);
    } catch {
      await active.session.abort().catch(() => {});
      pending.resolve({
        kind: "reject",
        feedback: "A reviewed file-system scope changed. The assignment was interrupted.",
      });
      return { resolved: true, accepted: false };
    }
    const policy = await evaluateHardPolicy(pending.request, {
      cwd: active.cwd,
      resources: active.resources,
    });
    if (policy.behavior === "deny") {
      pending.resolve({ kind: "reject", feedback: policy.reason });
      return { resolved: true };
    }
    const accepting = request.decision === "accept"
      || request.decision === "acceptForSession"
      || request.decision === "acceptAllForRun";
    const bindingIsValid = approvalBindingIsValid(
      pending.disclosureComplete,
      pending.operationDigest,
      pending.request,
      request.operationDigest,
    );
    if (accepting && !bindingIsValid) {
      pending.resolve({
        kind: "reject",
        feedback: "The GitHub Copilot operation changed or could not be bound to the reviewed request.",
      });
      return { resolved: true, accepted: false };
    }
    pending.resolve(permissionResult(request.decision, pending.request));
    return { resolved: true, accepted: accepting };
  }

  private async shutdown(): Promise<unknown> {
    for (const active of this.activeAssignments.values()) {
      this.denyApprovalsForAssignment(active.assignmentId, "Goby closed the GitHub Copilot bridge.");
      try { await active.session.abort(); } catch { /* Best-effort shutdown. */ }
      try { await active.session.disconnect(); } catch { /* Best-effort shutdown. */ }
      active.unsubscribe();
      await closeCapabilities(active.fileSystemCapabilities);
    }
    this.activeAssignments.clear();
    if (this.client) {
      try { await this.client.stop(); } catch { /* Best-effort shutdown. */ }
      this.client = undefined;
    }
    this.connectionState = "notChecked";
    return { stopped: true };
  }

  private async ensureClient(): Promise<CopilotClient> {
    if (this.client) return this.client;
    const token = configuredToken();
    if (!token) {
      this.connectionState = "needsAuthentication";
      throw new JSONRPCError(-32001, "A Goby-managed GitHub Copilot credential is required.");
    }
    const baseDirectory = process.env.GOBY_COPILOT_HOME
      ?? path.join(tmpdir(), "goby-copilot-sdk");
    await mkdir(baseDirectory, { recursive: true, mode: 0o700 });
    const environment = providerChildEnvironment();
    const client = new CopilotClient({
      gitHubToken: token,
      useLoggedInUser: false,
      mode: "empty",
      baseDirectory,
      logLevel: "none",
      env: environment,
    });
    try {
      await client.start();
      const status = await client.getStatus();
      this.runtimeVersion = status.version;
      this.client = client;
      return client;
    } catch (error) {
      try { await client.forceStop(); } catch { /* Best-effort cleanup. */ }
      this.updateConnectionFromError(describeError(error));
      throw error;
    }
  }

  private async ensureAuthenticatedClient(): Promise<CopilotClient> {
    const client = await this.ensureClient();
    const auth = await client.getAuthStatus();
    this.login = auth.login;
    this.authType = auth.authType;
    if (!auth.isAuthenticated) {
      this.connectionState = "needsAuthentication";
      throw new JSONRPCError(-32001, auth.statusMessage ?? "GitHub Copilot authentication is required.");
    }
    this.connectionState = "connected";
    return client;
  }

  private finishWithSuccess(active: ActiveAssignment, outcome: string): void {
    if (active.terminal) return;
    active.terminal = true;
    this.denyApprovalsForAssignment(active.assignmentId, "The GitHub Copilot assignment completed before this approval was answered.");
    this.activeAssignments.delete(active.assignmentId);
    sendNotification(this.writer, "assignment/completed", {
      assignmentId: active.assignmentId,
      outcome,
      sessionId: active.session.sessionId,
    });
    void active.session.disconnect();
    void closeCapabilities(active.fileSystemCapabilities);
  }

  private finishWithFailure(active: ActiveAssignment, message: string): void {
    if (active.terminal) return;
    active.terminal = true;
    this.denyApprovalsForAssignment(active.assignmentId, "The GitHub Copilot assignment ended before this approval was answered.");
    this.activeAssignments.delete(active.assignmentId);
    sendNotification(this.writer, "assignment/failed", {
      assignmentId: active.assignmentId,
      message,
      sessionId: active.session.sessionId,
    });
    void active.session.disconnect();
    void closeCapabilities(active.fileSystemCapabilities);
  }

  private denyApprovalsForAssignment(assignmentId: string, feedback: string): void {
    for (const [approvalId, approval] of this.pendingApprovals) {
      if (approval.assignmentId !== assignmentId) continue;
      this.pendingApprovals.delete(approvalId);
      approval.resolve({ kind: "reject", feedback });
    }
  }

  private updateConnectionFromError(message: string, errorType?: string): void {
    if (errorType === "authentication" || /auth|login|credential|token/i.test(message)) {
      this.connectionState = "needsAuthentication";
    } else {
      this.connectionState = "failed";
    }
  }
}

function configuredToken(): string | undefined {
  const token = process.env.GOBY_COPILOT_GITHUB_TOKEN?.trim();
  return token && token.length > 0 ? token : undefined;
}

export function providerChildEnvironment(
  source: NodeJS.ProcessEnv = process.env,
): NodeJS.ProcessEnv {
  const environment = { ...source };
  delete environment.COPILOT_GITHUB_TOKEN;
  delete environment.GOBY_COPILOT_GITHUB_TOKEN;
  delete environment.GH_TOKEN;
  delete environment.GITHUB_TOKEN;
  delete environment.GITHUB_COPILOT_API_TOKEN;
  delete environment.ANTHROPIC_API_KEY;
  delete environment.CLAUDE_CODE_OAUTH_TOKEN;
  delete environment.CLAUDE_CODE_USE_BEDROCK;
  delete environment.CLAUDE_CODE_USE_VERTEX;
  return environment;
}

export function providerExcludedTools(): string[] {
  return ["manage_schedule", "shell"];
}

export function permissionResult(decision: ApprovalDecision, request: PermissionRequest): PermissionRequestResult {
  switch (decision) {
    case "accept":
      return { kind: "approve-once", approvedInteractively: true };
    case "acceptForSession":
    case "acceptAllForRun": {
      if (request.kind === "shell" || request.kind === "read" || request.kind === "write") {
        return { kind: "approve-once", approvedInteractively: true };
      }
      if (request.kind === "url") {
        try {
          return { kind: "approve-for-session", domain: new URL(request.url).hostname };
        } catch {
          return { kind: "approve-once", approvedInteractively: true };
        }
      }
      const approval = sessionApproval(request);
      return approval === undefined
        ? { kind: "approve-once", approvedInteractively: true }
        : { kind: "approve-for-session", approval };
    }
    case "decline":
      return { kind: "reject", feedback: "The user declined this GitHub Copilot action." };
    case "cancel":
      return { kind: "reject", feedback: "The user cancelled this GitHub Copilot action." };
  }
}

function sessionApproval(request: PermissionRequest): Exclude<Extract<PermissionRequestResult, { kind: "approve-for-session" }>["approval"], undefined> | undefined {
  switch (request.kind) {
    case "shell":
      return { kind: "commands", commandIdentifiers: request.commands.map((command) => command.identifier) };
    case "read": return { kind: "read" };
    case "write": return { kind: "write" };
    case "mcp": return { kind: "mcp", serverName: request.serverName, toolName: request.toolName };
    case "memory": return { kind: "memory" };
    case "custom-tool": return { kind: "custom-tool", toolName: request.toolName };
    default: return undefined;
  }
}

function approvalKind(request: PermissionRequest): "command" | "fileChange" | "permissions" {
  if (request.kind === "shell") return "command";
  if (request.kind === "write") return "fileChange";
  return "permissions";
}

function approvalSummary(request: PermissionRequest): string {
  switch (request.kind) {
    case "shell": return request.intention || "GitHub Copilot wants to run a command.";
    case "write": return request.intention || `GitHub Copilot wants to write ${request.fileName}.`;
    case "read": return request.intention || `GitHub Copilot wants to read ${request.path}.`;
    default: return `GitHub Copilot requests ${request.kind} permission.`;
  }
}

function commandFor(call: TrackedToolCall): string {
  if (call.name === "shell" && isRecord(call.input)) {
    const command = call.input.command ?? call.input.fullCommandText;
    if (typeof command === "string") return command;
  }
  return `${call.name} ${JSON.stringify(call.input ?? {})}`;
}

function makeSystemPrompt(request: StartAssignmentRequest, resources: ResourceGrant[]): string {
  const instructions = request.agentInstructions?.trim();
  const packs = (request.instructionPacks ?? [])
    .map((pack) => `Instruction pack: ${pack.name} v${pack.version}\n${pack.body}`)
    .join("\n\n");
  const resourceText = resources
    .map((resource) => `- ${resource.path} (${resource.access === "readOnly" ? "read only" : "read and write"})`)
    .join("\n");
  return [
    `You are the ${request.agentName} agent working for Goby Agentic Dashboard.`,
    request.agentSummary,
    instructions ? `Role instructions:\n${instructions}` : "",
    packs ? `Reviewed instruction packs:\n${packs}` : "",
    resourceText ? `Reviewed external resources:\n${resourceText}` : "No external resources were granted.",
    `The disclosed plan risk is ${request.risk}. Work only in the provided working copy and reviewed resources.`,
    "Do not broaden scope, change Git history, publish, merge, push, or delete branches unless the current Goby approval explicitly covers that exact action.",
  ].filter((part) => part.length > 0).join("\n\n");
}

function validateStartRequest(request: StartAssignmentRequest): void {
  for (const [label, value] of [
    ["assignmentId", request.assignmentId],
    ["prompt", request.prompt],
    ["cwd", request.cwd],
    ["agentName", request.agentName],
    ["agentSummary", request.agentSummary],
    ["risk", request.risk],
  ] as const) {
    if (typeof value !== "string" || value.trim().length === 0) {
      throw new JSONRPCError(-32602, `${label} is required.`);
    }
  }
  if (!( ["readOnly", "low", "medium", "high"] as const).includes(request.risk)) {
    throw new JSONRPCError(-32602, `Unsupported risk value: ${request.risk}`);
  }
}

function promptWithVerifiedAttachments(prompt: string, attachments: AttachmentGrant[]): string {
  if (attachments.length === 0) return prompt;
  const context = attachments.map((attachment) => {
    const label = attachment.kind === "image" ? "Image" : "File";
    return `- ${label}: ${attachment.displayName}\n  Path: ${attachment.path}`;
  }).join("\n");
  return `${prompt}\n\nVerified local attachments:\n${context}`;
}

function clip(value: string, limit: number): string {
  if (value.length <= limit) return value;
  return `${value.slice(0, limit)}\n… ${value.length - limit} characters omitted`;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
