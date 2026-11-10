// MASC Dashboard — MCP 2026-07-28 over Streamable HTTP

import { v4 as randomUuid } from 'uuid'
import {
  ApiRequestError,
  apiRequestErrorFromResponse,
  fetchWithTimeout,
  DEFAULT_MCP_TIMEOUT_MS,
  authHeaders,
  currentStoredTokenRevision,
  currentDashboardActor,
  getStoredToken,
  getStoredTokenMeta,
} from './core'
import {
  ensureDevToken,
  recoverScopedRejectedCredential,
  refreshDevTokenAfterAuthError,
  resetDevTokenBootstrap,
} from './dev-token'
import {
  reportToolHostFailure,
  type ToolHostFailureCauseCode,
} from './tool-host-failure'
import { showActionToast } from '../components/common/toast'
import { errorToString } from '../lib/format-string'
import { parseUniqueJson } from '../lib/json-unique'
import { dashboardActorRevision, managedDashboardActorRevision, managedDashboardRefusal, managedDashboardUnverified,
  noteManagedCredentialRefusalObservation } from '../lib/dashboard-session-actor'

const MCP_PROTOCOL_VERSION = '2026-07-28'
const MCP_BLOCKED_MESSAGE = 'MCP 연결이 차단되었습니다.'
const MCP_AUTH_CHANGED_MESSAGE = 'MCP authentication changed during request'

interface McpRequestBinding {
  readonly authRevision: number
}

type ScopedWorkspace = { basePath: string; mascRoot: string }

function scopedWorkspace(args: Record<string, unknown>): ScopedWorkspace | null {
  const raw = args.expected_workspace
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) return null
  const { base_path: basePath, masc_root: mascRoot } = raw as Record<string, unknown>
  return typeof basePath === 'string' && basePath.trim() !== '' && typeof mascRoot === 'string' && mascRoot.trim() !== ''
    ? { basePath, mascRoot } : null
}

let blockedAuthRevision: number | null = null
let observedTokenRevision = currentStoredTokenRevision()
let blockedToastShown = false

async function bestEffortReportToolHostFailure(payload: {
  toolName: string
  message: string
  phase: string
  causeCode: ToolHostFailureCauseCode
  requestId?: string
  timeoutMs?: number
}) {
  try {
    await reportToolHostFailure({
      client_name: 'masc-dashboard',
      tool_name: payload.toolName,
      transport: 'mcp_http',
      phase: payload.phase,
      cause_code: payload.causeCode,
      message: payload.message,
      request_id: payload.requestId,
      timeout_ms: payload.timeoutMs,
    })
  } catch {
    // Best-effort only. The original MCP error should surface unchanged.
  }
}

type ToolHostFailureObservation =
  | { causeCode: 'tool_host_timeout'; timeoutMs: number }
  | { causeCode: 'tool_host_transport_unavailable'; timeoutMs?: never }

function toolHostFailureObservation(err: unknown): ToolHostFailureObservation | null {
  if (err instanceof ApiRequestError && err.timeout) {
    return { causeCode: 'tool_host_timeout', timeoutMs: DEFAULT_MCP_TIMEOUT_MS }
  }
  if (err instanceof TypeError) {
    return { causeCode: 'tool_host_transport_unavailable' }
  }
  return null
}

function explicitToolActor(args: Record<string, unknown>): string | null {
  const internalActor =
    typeof args._agent_name === 'string' && args._agent_name.trim() !== ''
      ? args._agent_name.trim()
      : null
  if (internalActor) return internalActor
  if (getStoredToken()) return null
  return typeof args.agent_name === 'string' && args.agent_name.trim() !== ''
    ? args.agent_name.trim()
    : null
}

function implicitToolActor(): string | null {
  const actor = currentDashboardActor()
  if (!actor) return null
  if (!getStoredToken()) return actor
  const meta = getStoredTokenMeta()
  if (meta?.source === 'dev') return actor
  return null
}

function mcpHeadersForActor(
  binding: McpRequestBinding,
  method: string,
  name: string | null,
  actorName?: string | null,
): Record<string, string> {
  assertAuthRevision(binding.authRevision)
  const headers: Record<string, string> = {
    ...authHeaders({ actorName }),
    'Content-Type': 'application/json',
    Accept: 'application/json, text/event-stream',
    'Mcp-Protocol-Version': MCP_PROTOCOL_VERSION,
    'Mcp-Method': method,
  }
  if (name) headers['Mcp-Name'] = name
  assertAuthRevision(binding.authRevision)
  return headers
}

function authChangedError(): Error {
  return new Error(MCP_AUTH_CHANGED_MESSAGE)
}

function assertAuthRevision(expectedRevision: number): void {
  if (currentStoredTokenRevision() !== expectedRevision) {
    throw authChangedError()
  }
}

function assertBinding(binding: McpRequestBinding): void {
  assertAuthRevision(binding.authRevision)
}

function synchronizeMcpAuthRevision(): void {
  const currentRevision = currentStoredTokenRevision()
  if (observedTokenRevision !== currentRevision) {
    blockedAuthRevision = null
    blockedToastShown = false
    resetDevTokenBootstrap()
    observedTokenRevision = currentRevision
  }
}

function currentRequest(body: unknown): {
  body: Record<string, unknown>
  method: string
  name: string | null
} {
  if (typeof body !== 'object' || body === null) {
    throw new Error('MCP request must be an object')
  }
  const request = body as Record<string, unknown>
  if (typeof request.method !== 'string') {
    throw new Error('MCP request method is required')
  }
  const rawParams = request.params
  const params = typeof rawParams === 'object' && rawParams !== null
    ? rawParams as Record<string, unknown>
    : {}
  const rawMeta = params._meta
  const meta = typeof rawMeta === 'object' && rawMeta !== null
    ? rawMeta as Record<string, unknown>
    : {}
  const nameKey = request.method === 'resources/read' ? 'uri' : 'name'
  const rawName = params[nameKey]
  return {
    body: {
      ...request,
      params: {
        ...params,
        _meta: {
          ...meta,
          'io.modelcontextprotocol/protocolVersion': MCP_PROTOCOL_VERSION,
          'io.modelcontextprotocol/clientCapabilities': {},
        },
      },
    },
    method: request.method,
    name: typeof rawName === 'string' ? rawName : null,
  }
}

async function mcpPost(
  body: unknown,
  binding: McpRequestBinding,
  timeoutMs = DEFAULT_MCP_TIMEOUT_MS,
  actorName?: string | null,
  scoped = false,
  onUnauthorized?: () => void,
  onStaleTaskSuccess?: (text: string) => void,
  requestSignal?: AbortSignal,
): Promise<string> {
  assertBinding(binding)
  const request = currentRequest(body)
  const init = {
    method: 'POST',
    headers: mcpHeadersForActor(binding, request.method, request.name, actorName),
    body: JSON.stringify(request.body),
    reportCredentialRefusal: !scoped,
    signal: requestSignal,
  }
  const consume = async (res: Response) => {
    requestSignal?.throwIfAborted()
    // Only a Task creation's completed HTTP 200 can preserve evidence under
    // its original owner. Other responses keep the normal header guard.
    if (!onStaleTaskSuccess || res.status !== 200) assertBinding(binding)
    if (!res.ok) {
      if (res.status === 401) onUnauthorized?.()
      if (res.status === 403 && !scoped) {
        blockedAuthRevision = binding.authRevision
        throw new Error(MCP_BLOCKED_MESSAGE)
      }
      const error = await apiRequestErrorFromResponse('POST', '/mcp', res, scoped)
      assertBinding(binding)
      throw error
    }
    const text = await res.text()
    requestSignal?.throwIfAborted()
    if (onStaleTaskSuccess && res.status === 200 && currentStoredTokenRevision() !== binding.authRevision) {
      // The observer receives only a validated projection and cannot change
      // the stale result or trigger credential recovery by throwing.
      try { onStaleTaskSuccess(text) } catch { /* preserve the stale error */ }
    }
    assertBinding(binding)
    return text
  }
  if (scoped) return fetchWithTimeout('/mcp', init, timeoutMs, consume)
  return consume(await fetchWithTimeout('/mcp', init, timeoutMs))
}

async function ensureBinding(): Promise<McpRequestBinding> {
  synchronizeMcpAuthRevision()
  if (blockedAuthRevision === currentStoredTokenRevision()) {
    if (!blockedToastShown) {
      blockedToastShown = true
      showActionToast(
        'MCP 연결이 차단되었습니다.',
        { label: '재연결', onClick: () => { resetMcpClientState(); blockedToastShown = false } },
        'error',
        15000,
      )
    }
    throw new Error(MCP_BLOCKED_MESSAGE)
  }
  await ensureDevToken()
  const authRevision = currentStoredTokenRevision()
  observedTokenRevision = authRevision
  return { authRevision }
}

export function resetMcpClientState(): void {
  blockedAuthRevision = null
  blockedToastShown = false
  resetDevTokenBootstrap()
  observedTokenRevision = currentStoredTokenRevision()
}

// --- MCP over HTTP helper ---

interface McpCallResponse {
  id?: unknown
  result?: {
    content?: Array<{ type?: string; text?: string }>
    isError?: boolean
    structuredContent?: unknown
  }
  error?: { message?: string; code?: number }
}

class McpProtocolError extends Error {
  readonly code: number | null

  constructor(message: string, code: number | null) {
    super(message)
    this.name = 'McpProtocolError'
    this.code = code
  }
}

class McpPreDispatchIdentityChangedError extends Error {
  constructor() {
    super('MCP authentication changed before dispatch; refresh the Goal before retrying')
    this.name = 'McpPreDispatchIdentityChangedError'
  }
}

class McpScopedTaskBindingError extends Error {
  constructor() {
    super('Task request requires an original request ID and workspace')
    this.name = 'McpScopedTaskBindingError'
  }
}

export function mcpIdentityRequiresGoalRefresh(error: unknown): boolean {
  return error instanceof McpPreDispatchIdentityChangedError
}

class McpToolCallError extends Error {
  readonly authErrorCode: unknown
  readonly structuredContent: unknown

  constructor(message: string, authErrorCode: unknown, structuredContent: unknown) {
    super(message)
    this.name = 'McpToolCallError'
    this.authErrorCode = authErrorCode
    this.structuredContent = structuredContent
  }
}

export function mcpStructuredContentFromError(error: unknown): unknown {
  return error instanceof McpToolCallError ? error.structuredContent : null
}

export type McpCallFailureDisposition =
  | 'known_tool_response'
  | 'known_pre_effect'
  | 'outcome_unknown'

export function mcpCallFailureDisposition(error: unknown): McpCallFailureDisposition {
  if (mcpIdentityRequiresGoalRefresh(error)) return 'known_pre_effect'
  if (error instanceof McpScopedTaskBindingError) return 'known_pre_effect'
  if (error instanceof McpToolCallError) return 'known_tool_response'
  if (error instanceof McpProtocolError && error.code === -32001) {
    return 'known_pre_effect'
  }
  if (
    error instanceof ApiRequestError
    && !error.timeout
    && error.status !== undefined
    && error.status >= 400
    && error.status < 500
    // A gateway timeout response may arrive after the upstream accepted work.
    && error.status !== 408
  ) {
    return 'known_pre_effect'
  }
  if (error instanceof Error && error.message === MCP_BLOCKED_MESSAGE) {
    return 'known_pre_effect'
  }
  return 'outcome_unknown'
}

function structuredAuthErrorCode(value: unknown): unknown {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return null
  return (value as Record<string, unknown>).auth_error_code
}

function parseMcpHttpResponse(raw: string, expectedId?: string, unique = false): McpCallResponse {
  const text = raw.trim()
  const payloads: string[] = []
  if (text.startsWith('{') || text.startsWith('[')) {
    payloads.push(text)
  } else {
    // An SSE response may contain progress notifications before its result.
    // Multiple data fields in one event form a single newline-separated body.
    let data: string[] = []
    const finishEvent = () => {
      if (data.length > 0) payloads.push(data.join('\n'))
      data = []
    }
    for (const line of raw.split(/\r\n|\r|\n/)) {
      if (line === '') finishEvent()
      else if (line === 'data') data.push('')
      else if (line.startsWith('data:')) {
        const value = line.slice(5)
        data.push(value.startsWith(' ') ? value.slice(1) : value)
      }
    }
    finishEvent()
  }

  let response: McpCallResponse | null = null
  for (const payload of payloads) {
    const value: unknown = unique ? parseUniqueJson(payload) : JSON.parse(payload)
    if (typeof value !== 'object' || value === null || Array.isArray(value)) {
      throw new Error('Invalid MCP response')
    }
    const message = value as Record<string, unknown>
    const hasResult = Object.hasOwn(message, 'result')
    const hasError = Object.hasOwn(message, 'error')
    if (!hasResult && !hasError && typeof message.method === 'string') continue
    if (hasResult === hasError || response !== null || (unique && message.jsonrpc !== '2.0')) {
      throw new Error('Invalid MCP response')
    }
    if (expectedId !== undefined && message.id !== expectedId) {
      throw new Error('MCP response does not match the request')
    }
    response = message as McpCallResponse
  }
  if (response === null) throw new Error('MCP response has no result')
  return response
}

function extractMcpText(res: McpCallResponse): string {
  if (res.error !== undefined) {
    if (typeof res.error !== 'object' || res.error === null || typeof res.error.message !== 'string') {
      throw new Error('Invalid MCP error response')
    }
    throw new McpProtocolError(
      res.error.message,
      typeof res.error.code === 'number' ? res.error.code : null,
    )
  }
  if (typeof res.result !== 'object' || res.result === null || Array.isArray(res.result)
    || (res.result.isError !== undefined && typeof res.result.isError !== 'boolean')) {
    throw new Error('Invalid MCP result')
  }
  if (res.result.isError) {
    const err = res.result.content?.[0]?.text ?? 'MCP tool call failed'
    throw new McpToolCallError(
      err,
      structuredAuthErrorCode(res.result.structuredContent),
      res.result.structuredContent,
    )
  }
  return res.result.content?.[0]?.text ?? ''
}

export type StaleTaskCreation = { readonly kind: 'created'; readonly taskId: string }

type TaskCreationCapture = {
  readonly requestId: string
  readonly goalId: string | null
  readonly onStaleSuccess: (result: StaleTaskCreation) => void
}

function retainStaleTaskCreation(raw: string, rpcId: string, capture: TaskCreationCapture): void {
  const message = parseMcpHttpResponse(raw, rpcId, true)
  if (message.error !== undefined || typeof message.result !== 'object' || message.result === null
    || Array.isArray(message.result) || (message.result.isError !== undefined && message.result.isError !== false)
    || !Array.isArray(message.result.content)) return
  const content = message.result.content[0]
  if (!content || content.type !== 'text' || typeof content.text !== 'string') return
  const value = parseUniqueJson(content.text)
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return
  const result = value as Record<string, unknown>
  if (result.ok !== true || result.creation_request_id !== capture.requestId || result.goal_id !== capture.goalId
    || typeof result.task_id !== 'string' || result.task_id.trim() === '') return
  capture.onStaleSuccess({ kind: 'created', taskId: result.task_id })
}

async function callMcpToolInternal(
  toolName: string,
  args: Record<string, unknown>,
  allowAuthRecovery = true,
  expectedIdentity?: { revision: number; actor: string },
  isCurrent?: () => boolean,
  recoveryIsCurrent?: () => boolean,
  waitForRecoveryCurrent?: () => Promise<boolean>,
  taskCapture?: TaskCreationCapture,
  strictTaskResult = false,
  onReceiptUnauthorized?: () => void,
  requestSignal?: AbortSignal,
): Promise<string> {
  requestSignal?.throwIfAborted()
  const requestId = randomUuid()
  let explicitActor: string | null = null
  let sentToken: string | null = null
  let sentActorRevision: number | null = null
  let sentRevision: number | null = null
  let sentManagedDev = false
  let sentWorkspace: ScopedWorkspace | null = null
  const sentActorIsCurrent = () => sentManagedDev
    ? getStoredToken() === sentToken && getStoredTokenMeta()?.source === 'dev'
      && managedDashboardActorRevision.peek() === sentActorRevision
    : dashboardActorRevision.peek() === sentActorRevision
  try {
    // A scoped request already owns a particular credential revision. Starting
    // a global bootstrap here could install a different credential after the
    // original workspace has retired. Let the owner observe bootstrap changes
    // and submit again under the newly observed identity instead.
    const scopedIsCurrent = () => !requestSignal?.aborted && (!expectedIdentity || (
      currentStoredTokenRevision() === expectedIdentity.revision
      && (getStoredToken() !== null || currentDashboardActor() === expectedIdentity.actor)
      && !(getStoredToken() !== null && getStoredTokenMeta()?.source === 'dev'
        && (managedDashboardRefusal.peek() === expectedIdentity.revision
          || managedDashboardUnverified.peek() === expectedIdentity.revision))
      && (!isCurrent || isCurrent())))
    if (!scopedIsCurrent()) throw new McpPreDispatchIdentityChangedError()
    // Preserve the asynchronous dispatch boundary so ownership can retire
    // before any scoped request leaves the browser.
    if (expectedIdentity) await Promise.resolve()
    const binding = expectedIdentity ? { authRevision: currentStoredTokenRevision() } : await ensureBinding()
    if (!scopedIsCurrent()) throw new McpPreDispatchIdentityChangedError()
    // Classify identity authority only after the binding is established.
    // A caller-supplied hint never overrides the credential used by this request.
    const hasBearer = getStoredToken() !== null
    explicitActor = hasBearer ? null : explicitToolActor(args)
    const actor = explicitActor ?? implicitToolActor()
    const preparedArgs = (() => {
      if (hasBearer) {
        const { _agent_name: _untrustedActor, ...credentialBoundArgs } = args
        return actor
          ? { ...credentialBoundArgs, _agent_name: actor }
          : credentialBoundArgs
      }
      return explicitActor == null && actor
        ? { ...args, _agent_name: actor }
        : args
    })()
    sentWorkspace = expectedIdentity ? scopedWorkspace(preparedArgs) : null
    const toolArgs = sentWorkspace ? { ...preparedArgs,
      expected_workspace: { base_path: sentWorkspace.basePath, masc_root: sentWorkspace.mascRoot } } : preparedArgs
    if (!scopedIsCurrent() || (isCurrent && !isCurrent())) throw new McpPreDispatchIdentityChangedError()
    sentToken = getStoredToken()
    sentRevision = binding.authRevision
    sentManagedDev = sentToken !== null && getStoredTokenMeta()?.source === 'dev'
    sentActorRevision = sentManagedDev ? managedDashboardActorRevision.peek() : dashboardActorRevision.peek()
    const text = await mcpPost({
      jsonrpc: '2.0',
      method: 'tools/call',
      params: {
        name: toolName,
        arguments: toolArgs,
      },
      id: requestId,
    }, binding, DEFAULT_MCP_TIMEOUT_MS, actor, expectedIdentity !== undefined, () => {
      const headerCurrent = recoveryIsCurrent ?? isCurrent
      const current = expectedIdentity && sentWorkspace && sentRevision === expectedIdentity.revision
        && currentStoredTokenRevision() === sentRevision && sentActorIsCurrent() && headerCurrent && headerCurrent()
      if (current && onReceiptUnauthorized) {
        try { onReceiptUnauthorized() } catch { /* The observer cannot change transport semantics. */ }
      }
      if (expectedIdentity && sentWorkspace && sentManagedDev && sentRevision === expectedIdentity.revision
        && currentStoredTokenRevision() === sentRevision && sentActorIsCurrent() && current) {
        noteManagedCredentialRefusalObservation(expectedIdentity.revision)
      }
    }, taskCapture ? text => { retainStaleTaskCreation(text, requestId, taskCapture) } : undefined, requestSignal)
    requestSignal?.throwIfAborted()
    if (requestSignal && isCurrent && !isCurrent()) throw new DOMException('MCP read owner retired', 'AbortError')
    const strictResult = taskCapture !== undefined || strictTaskResult
    const parsed = parseMcpHttpResponse(text, expectedIdentity ? requestId : undefined, strictResult)
    if (strictResult && parsed.error === undefined && parsed.result?.isError !== true) {
      const content = parsed.result?.content?.[0]
      if (!Array.isArray(parsed.result?.content) || !content || content.type !== 'text' || typeof content.text !== 'string') {
        throw new Error('Invalid MCP Task result')
      }
    }
    return extractMcpText(parsed)
  } catch (err) {
    requestSignal?.throwIfAborted()
    const authErrorCode = err instanceof McpToolCallError
      ? err.authErrorCode
      : err instanceof ApiRequestError && err.status === 401
        ? err.authErrorCode
        : null
    if (
      allowAuthRecovery
      && explicitActor === null
      && sentRevision !== null && currentStoredTokenRevision() === sentRevision
      && sentActorIsCurrent()
      && await refreshDevTokenAfterAuthError(authErrorCode)
    ) {
      observedTokenRevision = currentStoredTokenRevision()
      return callMcpToolInternal(toolName, args, false)
    }
    const recoveryCurrent = recoveryIsCurrent ?? isCurrent
    const scopedAuthRefusal = (err instanceof ApiRequestError && err.status === 401)
      || (err instanceof McpToolCallError && authErrorCode === 'actor_mismatch')
    if (!allowAuthRecovery && expectedIdentity && recoveryCurrent && explicitActor === null && sentToken && sentWorkspace
      && scopedAuthRefusal) {
      const token = sentToken
      await recoverScopedRejectedCredential({ token, authErrorCode: typeof authErrorCode === 'string' ? authErrorCode : undefined,
        httpStatus: err instanceof ApiRequestError ? err.status : undefined }, () =>
        recoveryCurrent() && currentStoredTokenRevision() === expectedIdentity.revision
        && sentActorIsCurrent(), waitForRecoveryCurrent, sentWorkspace)
    }
    const message = errorToString(err)
    const failure = toolHostFailureObservation(err)
    if (failure) {
      void bestEffortReportToolHostFailure({
        toolName,
        message,
        phase: 'tools/call',
        causeCode: failure.causeCode,
        requestId,
        timeoutMs: failure.timeoutMs,
      })
    }
    throw err
  }
}

export async function callMcpTool(toolName: string, args: Record<string, unknown>): Promise<string> {
  return callMcpToolInternal(toolName, args)
}

/** Dispatch only under the caller's observed identity and workspace.
 * Observer reads may supply requestSignal; existing effect callers retain
 * their original transport and receipt lifetime. */
export async function callMcpToolAtIdentity(
  toolName: string,
  args: Record<string, unknown>,
  expectedIdentity: { revision: number; actor: string },
  isCurrent?: () => boolean,
  recoveryIsCurrent?: () => boolean,
  waitForRecoveryCurrent?: () => Promise<boolean>,
  requestSignal?: AbortSignal,
): Promise<string> {
  return callMcpToolInternal(toolName, args, false, expectedIdentity, isCurrent, recoveryIsCurrent, waitForRecoveryCurrent,
    undefined, false, undefined, requestSignal)
}

/** Preserve only a validated late Task result for its original receipt.
 * A retired credential still rejects the call; the callback grants no current
 * presentation or mutation authority. No Task request is replayed. */
export async function callMcpTaskCreationAtIdentity(
  args: Record<string, unknown>,
  expectedIdentity: { revision: number; actor: string },
  isCurrent: () => boolean,
  recoveryIsCurrent: (() => boolean) | undefined,
  waitForRecoveryCurrent: (() => Promise<boolean>) | undefined,
  onStaleSuccess: (result: StaleTaskCreation) => void,
): Promise<string> {
  const workspace = scopedWorkspace(args)
  const requestId = args.creation_request_id
  const goalId = args.goal_id ?? null
  if (!workspace || typeof requestId !== 'string' || requestId.trim() === ''
    || !(goalId === null || (typeof goalId === 'string' && goalId.trim() !== ''))
    || typeof onStaleSuccess !== 'function') throw new McpScopedTaskBindingError()
  const capturedArgs = { ...args, creation_request_id: requestId,
    expected_workspace: { base_path: workspace.basePath, masc_root: workspace.mascRoot } }
  return callMcpToolInternal('masc_add_task', capturedArgs, false, { ...expectedIdentity }, isCurrent,
    recoveryIsCurrent, waitForRecoveryCurrent, { requestId, goalId, onStaleSuccess })
}

/** Read one Task creation receipt under its original workspace and current identity. */
export async function callMcpTaskReceiptAtIdentity(
  args: Record<string, unknown>,
  expectedIdentity: { revision: number; actor: string },
  isCurrent: () => boolean,
  onUnauthorized?: () => void,
): Promise<string> {
  const workspace = scopedWorkspace(args)
  const requestId = args.creation_request_id
  if (!workspace || typeof requestId !== 'string' || requestId.trim() === '') {
    throw new McpScopedTaskBindingError()
  }
  const capturedArgs = { ...args, creation_request_id: requestId,
    expected_workspace: { base_path: workspace.basePath, masc_root: workspace.mascRoot } }
  return callMcpToolInternal('masc_tasks', capturedArgs, false, { ...expectedIdentity }, isCurrent,
    undefined, undefined, undefined, true, onUnauthorized)
}

// --- MCP tools/list — fetch tool schemas with inputSchema ---

interface McpToolsListResult {
  tools: Array<{
    name: string
    description: string
    inputSchema: Record<string, unknown>
    annotations?: Record<string, unknown>
  }>
  nextCursor?: string
}

interface McpListResponse {
  result?: McpToolsListResult
  error?: { message?: string }
}

function extractFirstSseDataPayload(raw: string): string {
  const line = raw.split('\n').find(l => l.startsWith('data: '))
  return line ? line.slice(6).trim() : raw.trim()
}

function parseMcpListResponse(raw: string): McpListResponse {
  const payload = extractFirstSseDataPayload(raw)
  return parseMcpJsonText(payload) as McpListResponse
}

async function listMcpTools(cursor?: string): Promise<McpToolsListResult> {
  const binding = await ensureBinding()
  const text = await mcpPost({
    jsonrpc: '2.0',
    method: 'tools/list',
    params: cursor ? { cursor } : {},
    // A uuid, like every other request in this file. `Date.now()` gave two
    // calls in the same millisecond the same JSON-RPC id, and repeated the
    // whole value space roughly every 16m40s once it was taken modulo a
    // million.
    id: randomUuid(),
  }, binding)
  const parsed = parseMcpListResponse(text)
  if (parsed.error) {
    const message = parsed.error.message || 'tools/list: 서버가 message 없이 error 반환'
    throw new Error(message)
  }
  if (!parsed.result) {
    throw new Error('tools/list: 응답에 result 없음')
  }
  return parsed.result
}

/* Pagination ends when the server stops handing back a cursor. The failure
   worth guarding is a server that never stops -- one that returns the same
   cursor forever, or cycles through a set of them -- and the answer to that is
   progress, not a page budget.

   A fixed cap answered a different question. It refused a server that
   legitimately had more pages than the number someone picked, and it let a
   non-progressing server run for that many round trips before saying anything.
   Seen cursors decide it directly: a cursor that repeats means the server has
   not advanced, and that is the error. */
export async function listAllMcpTools(): Promise<McpToolsListResult['tools']> {
  const all: McpToolsListResult['tools'] = []
  const seenCursors = new Set<string>()
  let cursor: string | undefined
  let pages = 0
  do {
    const page = await listMcpTools(cursor)
    all.push(...page.tools)
    cursor = page.nextCursor
    pages++
    if (cursor !== undefined) {
      if (seenCursors.has(cursor)) {
        throw new Error(
          `tools/list: server repeated cursor ${cursor} after ${pages} page(s), so pagination is not advancing (toolsCollected=${all.length})`
        )
      }
      seenCursors.add(cursor)
    }
  } while (cursor)
  return all
}

function parseMcpJsonText(text: string): Record<string, unknown> {
  const trimmed = text.trim()
  if (!trimmed) return {}
  return JSON.parse(trimmed) as Record<string, unknown>
}
