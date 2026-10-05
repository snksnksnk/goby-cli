import { randomUUID } from "node:crypto";
import {
  listSessions,
  query,
  type CanUseTool,
  type PermissionResult,
  type Query,
  type SDKMessage,
} from "@anthropic-ai/claude-agent-sdk";
import {
  assistantText,
  assistantToolCalls,
  commandFor,
  userToolResults,
  type TrackedToolCall,
} from "./messages.js";
import {
  approvalBindingIsValid,
  canonicalApprovalDisclosure,
} from "./approval.js";
import { evaluateHardPolicy, makePreToolUseHook } from "./policy.js";
import { runTemporaryChat, type TemporaryChatRequest } from "./chat.js";
import { listClaudeModels } from "./models.js";
import { readPlanUsage, type PlanUsage } from "./usage.js";
import {
  CredentialPool,
  apiKeyVariable,
  isUsageLimitFailure,
  resetTimeFromFailure,
  subscriptionTokenVariable,
  type CredentialRoute,
} from "./credentials.js";
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
const sdkVersion = "0.3.263";
const protocolVersion = "1.1";

type UsageSnapshot = {
  estimatedCostUsd?: number;
  inputTokens?: number;
  outputTokens?: number;
  rateLimits?: Array<{
    id: string;
    utilization: number;
    resetsAt?: number;
  }>;
};

type ActiveAssignment = {
  assignmentId: string;
  cwd: string;
  abortController: AbortController;
  query?: Query;
  sessionId?: string;
  /** The credential the current query runs on, and that query's environment. */
  route: CredentialRoute;
  environment: NodeJS.ProcessEnv;
  /** Set when the subscription's usage limit stopped this query. */
  usageLimitReached: boolean;
  startedNotified: boolean;
  launch: (route: CredentialRoute, resumeSessionId?: string) => Query;
  trackedToolCalls: Map<string, TrackedToolCall>;
  lastAssistantText?: string;
  sawResult: boolean;
  resources: Array<Pick<ResourceGrant, "path" | "access">>;
  fileSystemCapabilities: FileSystemCapability[];
  start: Deferred<{ taskId: string; turnId: string }>;
};

type PendingApproval = {
  assignmentId: string;
  toolName: string;
  input: Record<string, unknown>;
  operationDigest: string | undefined;
  disclosureComplete: boolean;
  resolve: (result: PermissionResult) => void;
  disposeAbortListener: () => void;
};

export class ClaudeBridge {
  private readonly activeAssignments = new Map<string, ActiveAssignment>();
  private readonly pendingApprovals = new Map<string, PendingApproval>();
  private lastUsage: UsageSnapshot = {};
  private lastModel: string | undefined;
  private lastClaudeCodeVersion: string | undefined;
  private lastCredentialSource: string | undefined;
  private modelCatalog: { ids: string[]; fetchedAt: number } | undefined;
  private modelCatalogRequest: Promise<string[]> | undefined;
  private planUsage: { usage: PlanUsage | undefined; fetchedAt: number } | undefined;
  private planUsageRequest: Promise<void> | undefined;
  private connectionState: "notChecked" | "connected" | "needsAuthentication" | "failed" = "notChecked";
  private readonly credentials: CredentialPool;

  constructor(private readonly writer: ProtocolWriter, credentials: CredentialPool = new CredentialPool()) {
    this.credentials = credentials;
  }

  /** The child environment for whichever credential new work uses now. */
  private routedEnvironment(): NodeJS.ProcessEnv {
    return this.credentials.environment(this.credentials.current(), providerChildEnvironment());
  }

  async handle(method: string, rawParams: unknown): Promise<unknown> {
    switch (method) {
      case "initialize":
        return this.initialize(requireObject<InitializeRequest>(rawParams ?? {}, "initialize params"));
      case "account/read":
      {
        const [models] = await Promise.all([this.availableModels(), this.refreshPlanUsage()]);
        return this.accountSnapshot(models);
      }
      case "tasks/list":
        return this.listTasks(requireObject<ListTasksRequest>(rawParams, "tasks/list params"));
      case "assignment/start":
        return this.startAssignment(requireObject<StartAssignmentRequest>(rawParams, "assignment/start params"));
      case "assignment/interrupt":
        return this.interruptAssignment(requireObject<InterruptAssignmentRequest>(rawParams, "assignment/interrupt params"));
      case "approval/respond":
        return this.respondToApproval(requireObject<ApprovalResponseRequest>(rawParams, "approval/respond params"));
      case "chat/ask":
        return runTemporaryChat(requireObject<TemporaryChatRequest>(rawParams, "chat/ask params"), {
          query,
          env: this.routedEnvironment(),
          executable: providerRuntimeExecutable(),
        });
      case "shutdown":
        return this.shutdown();
      default:
        throw new JSONRPCError(-32601, `Unknown Claude bridge method: ${method}`);
    }
  }

  private initialize(_request: InitializeRequest): unknown {
    return {
      protocolVersion,
      helperVersion,
      sdkVersion,
      providerId: "claude",
      capabilities: [
        "accountInspection",
        "taskDiscovery",
        "execution",
        "interruption",
        "resume",
        "approvals",
        "usageReporting",
        "quotaReporting",
        "temporaryChat",
        "hooks",
        "mcp",
      ],
    };
  }

  /**
   * The account's model list for the model picker, kept for ten minutes. An
   * empty or failed answer is retried after a minute.
   */
  private async availableModels(): Promise<string[]> {
    const now = Date.now();
    const catalog = this.modelCatalog;
    if (catalog !== undefined) {
      const maxAge = catalog.ids.length > 0 ? 10 * 60_000 : 60_000;
      if (now - catalog.fetchedAt < maxAge) return catalog.ids;
    }
    this.modelCatalogRequest ??= listClaudeModels({
      query,
      env: this.routedEnvironment(),
      executable: providerRuntimeExecutable(),
    }).catch(() => catalog?.ids ?? []).then((ids) => {
      this.modelCatalog = { ids, fetchedAt: Date.now() };
      return ids;
    }).finally(() => {
      this.modelCatalogRequest = undefined;
    });
    return this.modelCatalogRequest;
  }

  /**
   * Plan usage for the Claude account that has plan limits: the saved
   * subscription, or this Mac's Claude Code sign-in when nothing is saved.
   * An API key has none. Kept for a minute so status refreshes stay cheap.
   */
  private async refreshPlanUsage(): Promise<void> {
    const route = this.credentials.hasSubscription
      ? "subscription"
      : this.credentials.hasAPIKey ? undefined : "claudeCodeLogin";
    if (route === undefined) return;
    if (this.planUsage !== undefined && Date.now() - this.planUsage.fetchedAt < 60_000) return;
    this.planUsageRequest ??= readPlanUsage({
      query,
      env: this.credentials.environment(route, providerChildEnvironment()),
      executable: providerRuntimeExecutable(),
    }).catch(() => undefined).then((usage) => {
      this.planUsage = { usage, fetchedAt: Date.now() };
      if (usage !== undefined && usage.rateLimits.length > 0) {
        this.lastUsage = { ...this.lastUsage, rateLimits: usage.rateLimits };
      }
    }).finally(() => {
      this.planUsageRequest = undefined;
    });
    return this.planUsageRequest;
  }

  private accountSnapshot(availableModels: string[] = []): unknown {
    const environmentCredential = this.credentials.hasSubscription
      || this.credentials.hasAPIKey
      || Boolean(process.env.CLAUDE_CODE_USE_BEDROCK || process.env.CLAUDE_CODE_USE_VERTEX);
    const pausedUntil = this.credentials.pausedUntil;
    return {
      connectionState: this.connectionState,
      credentialConfigured: environmentCredential || this.connectionState === "connected",
      credentialSource: this.lastCredentialSource,
      credentialRoute: this.credentials.current(),
      subscriptionConfigured: this.credentials.hasSubscription,
      subscriptionType: this.planUsage?.usage?.subscriptionType,
      apiKeyConfigured: this.credentials.hasAPIKey,
      subscriptionPausedUntil: pausedUntil === undefined ? undefined : new Date(pausedUntil).toISOString(),
      selectedModel: this.lastModel,
      availableModels,
      claudeCodeVersion: this.lastClaudeCodeVersion,
      usage: this.lastUsage,
      observedAt: new Date().toISOString(),
    };
  }

  private async listTasks(request: ListTasksRequest): Promise<unknown> {
    const limit = Math.min(Math.max(request.limitPerProject ?? 20, 1), 100);
    const groups = await Promise.all(request.projects.map(async (project) => {
      const capability = await openDirectoryCapability(
        project.rootPath,
        project.rootIdentity,
        "project root",
      );
      try {
        await assertCapabilitiesCurrent([capability]);
        const sessions = await listSessions({
          dir: capability.canonicalPath,
          limit,
          includeWorktrees: true,
          includeProgrammatic: true,
        });
        return sessions.map((session) => ({
          projectId: project.projectId,
          sessionId: session.sessionId,
          title: session.customTitle ?? session.summary,
          summary: session.firstPrompt,
          updatedAt: new Date(session.lastModified).toISOString(),
          createdAt: session.createdAt === undefined ? undefined : new Date(session.createdAt).toISOString(),
          cwd: session.cwd,
          gitBranch: session.gitBranch,
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
    const abortController = new AbortController();
    const systemPrompt = makeSystemPrompt(request, resources);
    const additionalDirectories = resources.map((resource) => resource.path);
    const launch = (route: CredentialRoute, resumeSessionId?: string): Query => {
      const childEnvironment = this.credentials.environment(route, providerChildEnvironment());
      active.route = route;
      active.environment = childEnvironment;
      active.usageLimitReached = false;
      return query({
      prompt: resumeSessionId === undefined
        ? promptWithVerifiedAttachments(request.prompt, attachments)
        : subscriptionContinuationPrompt,
      options: {
        abortController,
        cwd,
        systemPrompt,
        settingSources: [],
        permissionMode: "default",
        allowedTools: [],
        disallowedTools: disallowedToolsForProviderEnvironment(childEnvironment),
        canUseTool,
        sandbox: {
          enabled: true,
          failIfUnavailable: true,
          autoAllowBashIfSandboxed: false,
          allowUnsandboxedCommands: false,
          filesystem: {
            allowRead: [
              cwd,
              ...resources.map((resource) => resource.path),
              ...attachments.map((attachment) => attachment.path),
            ],
            allowWrite: [cwd, ...resources
              .filter((resource) => resource.access === "readWrite")
              .map((resource) => resource.path)],
          },
        },
        hooks: {
          PreToolUse: [{
            hooks: [async (input) => {
              if (input.hook_event_name !== "PreToolUse") return {};
              return makePreToolUseHook({ cwd, resources: policyResources })(input);
            }],
          }],
        },
        additionalDirectories,
        env: childEnvironment,
        executable: providerRuntimeExecutable() as never,
        ...(resumeSessionId === undefined ? {} : { resume: resumeSessionId }),
        ...(request.model === undefined ? {} : { model: request.model }),
        ...(request.maxTurns === undefined ? {} : { maxTurns: request.maxTurns }),
        ...(request.maxBudgetUsd === undefined ? {} : { maxBudgetUsd: request.maxBudgetUsd }),
      },
      });
    };
    const initialRoute = this.credentials.current();
    const active: ActiveAssignment = {
      assignmentId: request.assignmentId,
      cwd,
      abortController,
      trackedToolCalls: new Map(),
      sawResult: false,
      resources: policyResources,
      fileSystemCapabilities,
      start: deferred(),
      route: initialRoute,
      environment: this.credentials.environment(initialRoute, providerChildEnvironment()),
      usageLimitReached: false,
      startedNotified: false,
      launch,
    };
    this.activeAssignments.set(request.assignmentId, active);

    const canUseTool = this.makeCanUseTool(active, request.agentName);
    let claudeQuery: Query;
    try {
      await assertCapabilitiesCurrent(fileSystemCapabilities);
      claudeQuery = launch(initialRoute);
    } catch (error) {
      this.activeAssignments.delete(request.assignmentId);
      await closeCapabilities(fileSystemCapabilities);
      throw error;
    }
    active.query = claudeQuery;
    void this.consumeQuery(active, claudeQuery);
    return active.start.promise;
  }

  private makeCanUseTool(active: ActiveAssignment, agentName: string): CanUseTool {
    return async (toolName, input, options) => {
      if (options.signal.aborted || active.abortController.signal.aborted) {
        return { behavior: "deny", message: "The assignment was interrupted.", interrupt: true };
      }
      try {
        await assertCapabilitiesCurrent(active.fileSystemCapabilities);
      } catch {
        active.abortController.abort();
        return {
          behavior: "deny",
          message: "A reviewed file-system scope changed. The assignment was interrupted.",
          interrupt: true,
        };
      }
      if (toolName === "Bash" && disallowedToolsForProviderEnvironment(active.environment).includes("Bash")) {
        return {
          behavior: "deny",
          message: "Claude shell tools are unavailable while API-key authentication is active because child commands must never inherit the provider credential.",
        };
      }

      const hardPolicyInput = options.blockedPath === undefined
        ? input
        : { ...input, __gobyBlockedPath: options.blockedPath };
      const hardPolicy = await evaluateHardPolicy(toolName, hardPolicyInput, {
        cwd: active.cwd,
        resources: active.resources,
      });
      if (hardPolicy.behavior === "deny") {
        return { behavior: "deny", message: hardPolicy.reason };
      }

      const approvalId = randomUUID();
      const operation = { toolName, input };
      const disclosure = canonicalApprovalDisclosure(operation);
      const result = deferred<PermissionResult>();
      const onAbort = () => {
        const pending = this.pendingApprovals.get(approvalId);
        if (!pending) return;
        this.pendingApprovals.delete(approvalId);
        pending.resolve({ behavior: "deny", message: "The Claude permission request was cancelled.", interrupt: true });
      };
      options.signal.addEventListener("abort", onAbort, { once: true });
      active.abortController.signal.addEventListener("abort", onAbort, { once: true });
      this.pendingApprovals.set(approvalId, {
        assignmentId: active.assignmentId,
        toolName,
        input,
        operationDigest: disclosure.operationDigest,
        disclosureComplete: disclosure.disclosureComplete,
        resolve: result.resolve,
        disposeAbortListener: () => {
          options.signal.removeEventListener("abort", onAbort);
          active.abortController.signal.removeEventListener("abort", onAbort);
        },
      });
      sendNotification(this.writer, "approval/required", {
        approvalId,
        assignmentId: active.assignmentId,
        kind: approvalKind(toolName),
        summary: options.title ?? `${agentName} wants to use ${toolName}.`,
        details: disclosure.details,
        canAccept: disclosure.disclosureComplete,
        operationDigest: disclosure.operationDigest,
        disclosureComplete: disclosure.disclosureComplete,
        approvalSessionId: active.sessionId,
        toolName,
        toolUseId: options.toolUseID,
        decisionReason: options.decisionReason,
        blockedPath: options.blockedPath,
      });
      return result.promise;
    };
  }

  private async consumeQuery(active: ActiveAssignment, claudeQuery: Query): Promise<void> {
    let continuesOnAPIKey = false;
    try {
      for await (const message of claudeQuery) {
        this.consumeMessage(active, message);
      }
      if (this.shouldContinueOnAPIKey(active)) {
        continuesOnAPIKey = true;
        return;
      }
      if (!active.sawResult && !active.abortController.signal.aborted) {
        const outcome = active.lastAssistantText ?? "Claude finished without a terminal result message.";
        sendNotification(this.writer, "assignment/completed", {
          assignmentId: active.assignmentId,
          outcome,
          sessionId: active.sessionId,
          terminalResultMissing: true,
        });
      }
    } catch (error) {
      const message = describeError(error);
      this.noteUsageLimit(active, message);
      if (this.shouldContinueOnAPIKey(active)) {
        continuesOnAPIKey = true;
        return;
      }
      this.updateConnectionFromError(message);
      active.start.reject(new JSONRPCError(-32020, message));
      sendNotification(this.writer, "assignment/failed", {
        assignmentId: active.assignmentId,
        message,
        sessionId: active.sessionId,
      });
    } finally {
      if (continuesOnAPIKey) {
        void this.continueOnAPIKey(active);
      } else {
        this.denyApprovalsForAssignment(active.assignmentId, "The Claude assignment ended before this approval was answered.");
        this.activeAssignments.delete(active.assignmentId);
        await closeCapabilities(active.fileSystemCapabilities);
      }
    }
  }

  /** Records a subscription usage limit so new work moves to the API key. */
  private noteUsageLimit(active: ActiveAssignment, message: string, resetsAt?: number): void {
    if (active.route !== "subscription" || !isUsageLimitFailure(message)) return;
    active.usageLimitReached = true;
    this.credentials.pauseSubscription(resetsAt ?? resetTimeFromFailure(message));
  }

  private shouldContinueOnAPIKey(active: ActiveAssignment): boolean {
    return active.usageLimitReached
      && !active.abortController.signal.aborted
      && this.credentials.canFallBack(active.route);
  }

  /**
   * Resumes the same Claude session on the API key, so work already done on
   * the subscription is kept. Without a session yet, the task starts over.
   */
  private async continueOnAPIKey(active: ActiveAssignment): Promise<void> {
    this.denyApprovalsForAssignment(active.assignmentId, "Claude switched to the API key before this approval was answered.");
    active.sawResult = false;
    const pausedUntil = this.credentials.pausedUntil;
    sendNotification(this.writer, "assignment/progress", {
      assignmentId: active.assignmentId,
      message: pausedUntil === undefined
        ? "Your Claude subscription reached its usage limit. Continuing on the Anthropic API key."
        : `Your Claude subscription reached its usage limit until ${new Date(pausedUntil).toISOString()}. Continuing on the Anthropic API key.`,
    });
    sendNotification(this.writer, "credential/changed", {
      credentialRoute: "apiKey",
      subscriptionPausedUntil: pausedUntil === undefined ? undefined : new Date(pausedUntil).toISOString(),
    });
    let claudeQuery: Query;
    try {
      await assertCapabilitiesCurrent(active.fileSystemCapabilities);
      claudeQuery = active.launch("apiKey", active.sessionId);
    } catch (error) {
      const message = describeError(error);
      active.start.reject(new JSONRPCError(-32020, message));
      sendNotification(this.writer, "assignment/failed", {
        assignmentId: active.assignmentId,
        message,
        sessionId: active.sessionId,
      });
      this.activeAssignments.delete(active.assignmentId);
      await closeCapabilities(active.fileSystemCapabilities);
      return;
    }
    active.query = claudeQuery;
    await this.consumeQuery(active, claudeQuery);
  }

  private consumeMessage(active: ActiveAssignment, message: SDKMessage): void {
    if (message.type === "system" && message.subtype === "init") {
      active.sessionId = message.session_id;
      this.connectionState = "connected";
      this.lastModel = message.model;
      this.lastClaudeCodeVersion = message.claude_code_version;
      this.lastCredentialSource = message.apiKeySource;
      active.start.resolve({ taskId: message.session_id, turnId: active.assignmentId });
      if (active.startedNotified) return;
      active.startedNotified = true;
      sendNotification(this.writer, "assignment/started", {
        assignmentId: active.assignmentId,
        sessionId: message.session_id,
        model: message.model,
        claudeCodeVersion: message.claude_code_version,
      });
      return;
    }

    if (message.type === "assistant") {
      if (message.error === "authentication_failed" || message.error === "oauth_org_not_allowed") {
        this.connectionState = "needsAuthentication";
      }
      if (message.error === "rate_limit" || message.error === "billing_error") {
        this.noteUsageLimit(active, message.error);
      }
      for (const call of assistantToolCalls(message)) active.trackedToolCalls.set(call.id, call);
      const texts = assistantText(message);
      if (texts.length > 0) {
        active.lastAssistantText = texts[texts.length - 1]!;
        sendNotification(this.writer, "assignment/progress", {
          assignmentId: active.assignmentId,
          message: texts.join("\n"),
        });
      }
      return;
    }

    if (message.type === "user") {
      for (const result of userToolResults(message)) {
        const call = active.trackedToolCalls.get(result.toolUseId);
        if (!call) continue;
        active.trackedToolCalls.delete(result.toolUseId);
        sendNotification(this.writer, "command/completed", {
          assignmentId: active.assignmentId,
          evidenceId: result.toolUseId,
          command: commandFor(call),
          actionCommands: call.name === "Bash" ? [] : [call.name],
          workingDirectory: active.cwd,
          status: result.isError ? "failed" : "completed",
          exitCode: result.isError ? 1 : 0,
          source: "Claude Agent SDK",
          outputSummary: clip(result.output, 2_000),
        });
      }
      return;
    }

    if (message.type === "result") {
      active.sawResult = true;
      active.sessionId ??= message.session_id;
      active.start.resolve({ taskId: message.session_id, turnId: active.assignmentId });
      // Keep the plan windows; a finished turn changed them, so read them again next time.
      this.lastUsage = {
        ...usageFromResult(message),
        ...(this.lastUsage.rateLimits === undefined ? {} : { rateLimits: this.lastUsage.rateLimits }),
      };
      this.planUsage = undefined;
      sendNotification(this.writer, "usage/updated", {
        assignmentId: active.assignmentId,
        ...this.lastUsage,
        isEstimate: true,
      });
      if (message.subtype === "success" && !message.is_error) {
        sendNotification(this.writer, "assignment/completed", {
          assignmentId: active.assignmentId,
          outcome: message.result,
          sessionId: message.session_id,
        });
      } else {
        const failure = message.subtype === "success"
          ? message.result
          : message.errors.join("\n") || message.subtype;
        this.noteUsageLimit(active, failure);
        // The fallback query reports this assignment's outcome instead.
        if (this.shouldContinueOnAPIKey(active)) return;
        this.updateConnectionFromError(failure);
        sendNotification(this.writer, "assignment/failed", {
          assignmentId: active.assignmentId,
          message: failure,
          sessionId: message.session_id,
        });
      }
      return;
    }

    if (message.type === "rate_limit_event") {
      const info = message.rate_limit_info;
      const overageAvailable = info.overageStatus === "allowed" || info.overageStatus === "allowed_warning";
      if (info.status === "rejected" && !overageAvailable) {
        this.noteUsageLimit(active, "rate_limit", info.resetsAt);
      }
      if (info.utilization !== undefined) {
        const id = info.rateLimitType ?? "claude";
        this.lastUsage = {
          ...this.lastUsage,
          rateLimits: [
            ...(this.lastUsage.rateLimits ?? []).filter((limit) => limit.id !== id),
            {
              id,
              utilization: info.utilization,
              ...(info.resetsAt === undefined ? {} : { resetsAt: info.resetsAt }),
            },
          ],
        };
        sendNotification(this.writer, "usage/updated", {
          assignmentId: active.assignmentId,
          ...this.lastUsage,
          isEstimate: false,
        });
      }
      return;
    }

    if (message.type === "system" && message.subtype === "task_progress") {
      sendNotification(this.writer, "assignment/progress", {
        assignmentId: active.assignmentId,
        message: message.summary ?? message.description,
      });
    }
  }

  private async interruptAssignment(request: InterruptAssignmentRequest): Promise<unknown> {
    const active = this.activeAssignments.get(request.assignmentId);
    if (!active) throw new JSONRPCError(-32011, `Assignment ${request.assignmentId} is not active.`);
    active.abortController.abort();
    try {
      await active.query?.interrupt();
    } catch {
      // AbortController is the authoritative fallback for single-prompt mode.
    }
    this.denyApprovalsForAssignment(request.assignmentId, "The assignment was interrupted.");
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
    pending.disposeAbortListener();
    const accepting = request.decision === "accept"
      || request.decision === "acceptForSession"
      || request.decision === "acceptAllForRun";
    if (accepting) {
      const active = this.activeAssignments.get(pending.assignmentId);
      if (!active) {
        pending.resolve({ behavior: "deny", message: "The assignment ended before this approval was applied." });
        return { resolved: true, accepted: false };
      }
      try {
        await assertCapabilitiesCurrent(active.fileSystemCapabilities);
      } catch {
        active.abortController.abort();
        pending.resolve({
          behavior: "deny",
          message: "A reviewed file-system scope changed. The assignment was interrupted.",
          interrupt: true,
        });
        return { resolved: true, accepted: false };
      }
    }
    const bindingIsValid = approvalBindingIsValid(
      pending.disclosureComplete,
      pending.operationDigest,
      { toolName: pending.toolName, input: pending.input },
      request.operationDigest,
    );
    if (accepting && !bindingIsValid) {
      pending.resolve({
        behavior: "deny",
        message: "The Claude operation changed or could not be bound to the reviewed request.",
      });
      return { resolved: true, accepted: false };
    }
    pending.resolve(permissionResult(request.decision, pending));
    return { resolved: true, accepted: accepting };
  }

  private async shutdown(): Promise<unknown> {
    const assignments = [...this.activeAssignments.values()];
    for (const assignment of assignments) {
      assignment.abortController.abort();
      try {
        await assignment.query?.interrupt();
      } catch {
        // The process is shutting down; abort is sufficient.
      }
      await closeCapabilities(assignment.fileSystemCapabilities);
    }
    for (const [approvalId, approval] of this.pendingApprovals) {
      this.pendingApprovals.delete(approvalId);
      approval.disposeAbortListener();
      approval.resolve({ behavior: "deny", message: "Goby closed the Claude bridge.", interrupt: true });
    }
    return { stopped: true };
  }

  private denyApprovalsForAssignment(assignmentId: string, reason: string): void {
    for (const [approvalId, approval] of this.pendingApprovals) {
      if (approval.assignmentId !== assignmentId) continue;
      this.pendingApprovals.delete(approvalId);
      approval.disposeAbortListener();
      approval.resolve({ behavior: "deny", message: reason, interrupt: true });
    }
  }

  private updateConnectionFromError(message: string): void {
    if (/auth|login|credential|api key|oauth/i.test(message)) {
      this.connectionState = "needsAuthentication";
    } else {
      this.connectionState = "failed";
    }
  }
}

function permissionResult(decision: ApprovalDecision, pending: PendingApproval): PermissionResult {
  switch (decision) {
    case "accept":
      return { behavior: "allow", updatedInput: pending.input };
    case "acceptForSession":
    case "acceptAllForRun":
      return { behavior: "allow", updatedInput: pending.input };
    case "decline":
      return { behavior: "deny", message: "The user declined this Claude action." };
    case "cancel":
      return { behavior: "deny", message: "The user cancelled this Claude action.", interrupt: true };
  }
}

function approvalKind(toolName: string): "command" | "fileChange" | "permissions" {
  if (toolName === "Bash") return "command";
  if (["Edit", "Write", "NotebookEdit", "MultiEdit"].includes(toolName)) return "fileChange";
  return "permissions";
}

function usageFromResult(message: Extract<SDKMessage, { type: "result" }>): UsageSnapshot {
  const models = Object.values(message.modelUsage);
  return {
    estimatedCostUsd: message.total_cost_usd,
    inputTokens: models.reduce(
      (sum, usage) => sum + usage.inputTokens + usage.cacheReadInputTokens + usage.cacheCreationInputTokens,
      0,
    ),
    outputTokens: models.reduce((sum, usage) => sum + usage.outputTokens, 0),
  };
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

export function providerChildEnvironment(
  source: NodeJS.ProcessEnv = process.env,
): NodeJS.ProcessEnv {
  const environment: NodeJS.ProcessEnv = {
    ...source,
    CLAUDE_AGENT_SDK_CLIENT_APP: `goby-agentic-dashboard/${helperVersion}`,
  };
  delete environment.COPILOT_GITHUB_TOKEN;
  delete environment.GOBY_COPILOT_GITHUB_TOKEN;
  delete environment.GH_TOKEN;
  delete environment.GITHUB_TOKEN;
  delete environment.GITHUB_COPILOT_API_TOKEN;
  return environment;
}

/** Sent when a subscription limit moves a running assignment to the API key. */
const subscriptionContinuationPrompt = "Your previous turn stopped because the Claude subscription usage limit was reached. Continue the same task from where you left off, without repeating completed steps.";

export function credentialVariableNames(): string[] {
  return [subscriptionTokenVariable, apiKeyVariable];
}

export function providerRuntimeExecutable(): string {
  return process.execPath;
}

export function disallowedToolsForProviderEnvironment(
  environment: NodeJS.ProcessEnv,
): string[] {
  const hasProviderCredential = [
    ...credentialVariableNames(),
    "ANTHROPIC_API_KEY",
    "CLAUDE_CODE_OAUTH_TOKEN",
    "AWS_ACCESS_KEY_ID",
    "AWS_SECRET_ACCESS_KEY",
    "AWS_SESSION_TOKEN",
    "GOOGLE_APPLICATION_CREDENTIALS",
  ].some((name) => Boolean(environment[name]));
  return hasProviderCredential ? ["Bash"] : [];
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
  if (!(["readOnly", "low", "medium", "high"] as const).includes(request.risk)) {
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

function clippedJSON(value: unknown): string {
  return clip(JSON.stringify(value, null, 2), 8_000);
}

function clip(value: string, limit: number): string {
  if (value.length <= limit) return value;
  return `${value.slice(0, limit)}\n… ${value.length - limit} characters omitted`;
}

type Deferred<Value> = {
  promise: Promise<Value>;
  resolve: (value: Value) => void;
  reject: (error: unknown) => void;
};

function deferred<Value>(): Deferred<Value> {
  let resolve!: (value: Value) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<Value>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}
