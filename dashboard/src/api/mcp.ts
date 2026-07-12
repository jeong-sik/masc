// MASC Dashboard — MCP-over-HTTP client with session lifecycle

import {
  apiRequestErrorFromResponse,
  fetchWithTimeout,
  DEFAULT_MCP_TIMEOUT_MS,
  authHeaders,
  currentStoredTokenRevision,
  currentDashboardActor,
  getStoredToken,
  getStoredTokenMeta,
} from './core'
import { ensureDevToken, resetDevTokenBootstrap } from './dev-token'
import {
  MCP_INIT_COOLDOWN_MS,
  MCP_INITIALIZE_TIMEOUT_MS,
  MCP_INITIALIZED_NOTIFY_TIMEOUT_MS,
} from '../config/constants'
import { reportToolHostFailure } from './tool-host-failure'
import { showActionToast } from '../components/common/toast'
import { errorToString } from '../lib/format-string'

// --- MCP Session Management ---

const MCP_BLOCKED_MESSAGE = 'MCP 연결이 차단되었습니다.'
const MCP_AUTH_CHANGED_MESSAGE = 'MCP authentication changed during request'

interface McpSessionBinding {
  readonly sessionId: string | null
  readonly authRevision: number
}

type McpSessionState =
  | { readonly kind: 'ready'; readonly binding: McpSessionBinding }
  | { readonly kind: 'blocked'; readonly authRevision: number }

interface McpInitAttempt {
  readonly generation: number
  readonly promise: Promise<McpSessionBinding>
  cooldownTimer: ReturnType<typeof setTimeout> | null
}

interface McpRequestTrace {
  binding: McpSessionBinding | null
}

type McpErrorResponseContract =
  | { readonly kind: 'unknown_session'; readonly replacementSessionId: string }
  | { readonly kind: 'other' }

let mcpSessionState: McpSessionState | null = null
let observedTokenRevision = currentStoredTokenRevision()
let initGeneration = 0
let initAttempt: McpInitAttempt | null = null

async function bestEffortReportToolHostFailure(payload: {
  toolName: string
  message: string
  phase: string
  requestId?: string
  sessionId?: string
  timeoutMs?: number
}) {
  try {
    await reportToolHostFailure({
      client_name: 'masc-dashboard',
      tool_name: payload.toolName,
      transport: 'mcp_http',
      phase: payload.phase,
      message: payload.message,
      request_id: payload.requestId,
      session_id: payload.sessionId,
      timeout_ms: payload.timeoutMs,
    })
  } catch {
    // Best-effort only. The original MCP error should surface unchanged.
  }
}

function shouldReportToolHostFailure(message: string): boolean {
  const normalized = message.toLowerCase()
  return (
    normalized.includes('timeout after')
    || normalized.includes('timed out awaiting tools/call')
    || normalized.includes('failed to fetch')
    || normalized.includes('networkerror')
    || normalized.includes('load failed')
    || normalized.includes('error decoding response body')
  )
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
  if (meta?.source === 'dev' || meta?.actor) return actor
  return null
}

function mcpHeadersForActor(
  binding: McpSessionBinding,
  actorName?: string | null,
  extra?: Record<string, string>,
): Record<string, string> {
  assertAuthRevision(binding.authRevision)
  const headers: Record<string, string> = {
    ...authHeaders({ actorName }),
    'Content-Type': 'application/json',
    Accept: 'application/json, text/event-stream',
    ...(extra ?? {}),
  }
  assertAuthRevision(binding.authRevision)
  if (binding.sessionId) {
    headers['Mcp-Session-Id'] = binding.sessionId
  }
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

function assertPublishedBinding(binding: McpSessionBinding): void {
  assertAuthRevision(binding.authRevision)
  if (mcpSessionState?.kind !== 'ready' || mcpSessionState.binding !== binding) {
    throw authChangedError()
  }
}

function invalidateInitAttempt(): void {
  initGeneration += 1
  if (initAttempt?.cooldownTimer) {
    clearTimeout(initAttempt.cooldownTimer)
  }
  initAttempt = null
}

function resetMcpSessionOnly(): void {
  mcpSessionState = null
  invalidateInitAttempt()
}

function synchronizeMcpAuthRevision(): void {
  const currentRevision = currentStoredTokenRevision()
  if (observedTokenRevision !== currentRevision) {
    resetMcpSessionOnly()
    resetDevTokenBootstrap()
    observedTokenRevision = currentRevision
  }
}

function mcpBodyMethod(body: unknown): string | null {
  if (typeof body !== 'object' || body === null) return null
  const method = (body as Record<string, unknown>).method
  return typeof method === 'string' ? method : null
}

function canRetryUnknownSession(body: unknown): boolean {
  const method = mcpBodyMethod(body)
  return method !== 'initialize'
    && method !== 'notifications/initialized'
    && method !== 'ping'
    && method !== 'server/discover'
}

function classifyMcpErrorResponse(
  res: Response,
  body: unknown,
): McpErrorResponseContract {
  const replacementSessionId = res.headers.get('Mcp-Session-Id')
  if (
    res.status === 404
    && replacementSessionId
    && canRetryUnknownSession(body)
  ) {
    return { kind: 'unknown_session', replacementSessionId }
  }
  return { kind: 'other' }
}

function invalidatePublishedBinding(binding: McpSessionBinding): void {
  assertPublishedBinding(binding)
  resetMcpSessionOnly()
}

async function mcpPost(
  body: unknown,
  binding: McpSessionBinding,
  timeoutMs = DEFAULT_MCP_TIMEOUT_MS,
  actorName?: string | null,
  retryUnknownSession = true,
  requestTrace?: McpRequestTrace,
): Promise<string> {
  assertPublishedBinding(binding)
  if (requestTrace) requestTrace.binding = binding
  const res = await fetchWithTimeout('/mcp', {
    method: 'POST',
    headers: mcpHeadersForActor(binding, actorName),
    body: JSON.stringify(body),
  }, timeoutMs)
  assertPublishedBinding(binding)
  if (!res.ok) {
    if (res.status === 403) {
      mcpSessionState = {
        kind: 'blocked',
        authRevision: binding.authRevision,
      }
      throw new Error(MCP_BLOCKED_MESSAGE)
    }
    const responseContract = classifyMcpErrorResponse(res, body)
    const err = await apiRequestErrorFromResponse('POST', '/mcp', res)
    if (
      retryUnknownSession
      && responseContract.kind === 'unknown_session'
    ) {
      invalidatePublishedBinding(binding)
      const freshBinding = await ensureSession()
      return mcpPost(body, freshBinding, timeoutMs, actorName, false, requestTrace)
    }
    throw err
  }
  // Capture session ID only after successful responses. A stale-session 404
  // may include a fresh header, but that header is not initialized yet.
  const sid = res.headers.get('Mcp-Session-Id')
  const text = await res.text()
  assertPublishedBinding(binding)
  if (sid && sid !== binding.sessionId) {
    mcpSessionState = {
      kind: 'ready',
      binding: { sessionId: sid, authRevision: binding.authRevision },
    }
  }
  return text
}

let blockedToastShown = false

function assertCurrentInitAttempt(
  attempt: McpInitAttempt,
  authRevision?: number,
): void {
  if (initAttempt !== attempt || attempt.generation !== initGeneration) {
    throw authChangedError()
  }
  if (authRevision !== undefined) assertAuthRevision(authRevision)
}

async function initializeSession(
  attempt: McpInitAttempt,
): Promise<McpSessionBinding> {
  await ensureDevToken()
  assertCurrentInitAttempt(attempt)
  const authRevision = currentStoredTokenRevision()
  observedTokenRevision = authRevision
  const initializingBinding: McpSessionBinding = {
    sessionId: null,
    authRevision,
  }
  const res = await fetchWithTimeout('/mcp', {
    method: 'POST',
    headers: mcpHeadersForActor(initializingBinding),
    body: JSON.stringify({
      jsonrpc: '2.0',
      method: 'initialize',
      params: {
        protocolVersion: '2025-03-26',
        capabilities: {},
        clientInfo: { name: 'masc-dashboard', version: '1.0.0' },
      },
      id: 0,
    }),
  }, MCP_INITIALIZE_TIMEOUT_MS)
  assertCurrentInitAttempt(attempt, authRevision)
  if (!res.ok) {
    if (res.status === 403) {
      mcpSessionState = { kind: 'blocked', authRevision }
      initAttempt = null
      throw new Error(MCP_BLOCKED_MESSAGE)
    }
    throw await apiRequestErrorFromResponse('POST', '/mcp initialize', res)
  }
  const binding: McpSessionBinding = {
    sessionId: res.headers.get('Mcp-Session-Id'),
    authRevision,
  }
  if (binding.sessionId) {
    try {
      const initializedRes = await fetchWithTimeout('/mcp', {
        method: 'POST',
        headers: mcpHeadersForActor(binding),
        body: JSON.stringify({
          jsonrpc: '2.0',
          method: 'notifications/initialized',
        }),
      }, MCP_INITIALIZED_NOTIFY_TIMEOUT_MS)
      assertCurrentInitAttempt(attempt, authRevision)
      if (!initializedRes.ok) {
        throw await apiRequestErrorFromResponse(
          'POST',
          '/mcp notifications/initialized',
          initializedRes,
        )
      }
    } catch (err) {
      assertCurrentInitAttempt(attempt, authRevision)
      console.warn('[mcp] initialized notification failed:', err)
      throw err
    }
  }
  assertCurrentInitAttempt(attempt, authRevision)
  mcpSessionState = { kind: 'ready', binding }
  initAttempt = null
  return binding
}

function startSessionInitialization(): Promise<McpSessionBinding> {
  const generation = initGeneration + 1
  initGeneration = generation
  let attempt!: McpInitAttempt
  const promise = Promise.resolve()
    .then(() => initializeSession(attempt))
    .catch((err: unknown) => {
      if (initAttempt === attempt) {
        if (attempt.cooldownTimer) clearTimeout(attempt.cooldownTimer)
        attempt.cooldownTimer = setTimeout(() => {
          if (initAttempt === attempt) initAttempt = null
          attempt.cooldownTimer = null
        }, MCP_INIT_COOLDOWN_MS)
      }
      throw err
    })
  attempt = { generation, promise, cooldownTimer: null }
  initAttempt = attempt
  return promise
}

async function ensureSession(): Promise<McpSessionBinding> {
  synchronizeMcpAuthRevision()
  if (mcpSessionState?.kind === 'blocked') {
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
  if (mcpSessionState?.kind === 'ready') {
    assertAuthRevision(mcpSessionState.binding.authRevision)
    return mcpSessionState.binding
  }
  if (initAttempt) return initAttempt.promise
  return startSessionInitialization()
}

export function resetMcpClientState(): void {
  resetMcpSessionOnly()
  resetDevTokenBootstrap()
  observedTokenRevision = currentStoredTokenRevision()
}

// --- MCP over HTTP helper ---

interface McpCallResponse {
  result?: {
    content?: Array<{ type?: string; text?: string }>
    isError?: boolean
  }
  error?: { message?: string }
}

function parseMcpHttpResponse(raw: string): McpCallResponse {
  const line = raw.split('\n').find(l => l.startsWith('data: '))
  const payload = line ? line.slice(6).trim() : raw.trim()
  return JSON.parse(payload) as McpCallResponse
}

function extractMcpText(res: McpCallResponse): string {
  if (res.error?.message) throw new Error(res.error.message)
  if (res.result?.isError) {
    const err = res.result.content?.[0]?.text ?? 'MCP tool call failed'
    throw new Error(err)
  }
  return res.result?.content?.[0]?.text ?? ''
}

async function callMcpToolInternal(
  toolName: string,
  args: Record<string, unknown>,
): Promise<string> {
  const requestId = String(Math.floor(Date.now() % 1000000))
  synchronizeMcpAuthRevision()
  let phase = mcpSessionState?.kind === 'ready' ? 'tools/call' : 'initialize'
  const requestTrace: McpRequestTrace = { binding: null }
  try {
    const binding = await ensureSession()
    phase = 'tools/call'
    const explicitActor = explicitToolActor(args)
    const actor = explicitActor ?? implicitToolActor()
    const toolArgs =
      explicitActor == null && actor
        ? { ...args, _agent_name: actor }
        : args
    const text = await mcpPost({
      jsonrpc: '2.0',
      method: 'tools/call',
      params: {
        name: toolName,
        arguments: toolArgs,
      },
      id: Number.parseInt(requestId, 10),
    }, binding, DEFAULT_MCP_TIMEOUT_MS, actor, true, requestTrace)
    const parsed = parseMcpHttpResponse(text)
    return extractMcpText(parsed)
  } catch (err) {
    const message = errorToString(err)
    if (shouldReportToolHostFailure(message)) {
      await bestEffortReportToolHostFailure({
        toolName,
        message,
        phase,
        requestId: phase === 'tools/call' ? requestId : undefined,
        sessionId: requestTrace.binding?.sessionId ?? undefined,
        timeoutMs: phase === 'initialize' ? MCP_INITIALIZE_TIMEOUT_MS : DEFAULT_MCP_TIMEOUT_MS,
      })
    }
    throw err
  }
}

export async function callMcpTool(toolName: string, args: Record<string, unknown>): Promise<string> {
  return callMcpToolInternal(toolName, args)
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
  const binding = await ensureSession()
  const text = await mcpPost({
    jsonrpc: '2.0',
    method: 'tools/list',
    params: cursor ? { cursor } : {},
    id: Date.now(),
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

const MAX_TOOL_LIST_PAGES = 50

export async function listAllMcpTools(): Promise<McpToolsListResult['tools']> {
  const all: McpToolsListResult['tools'] = []
  let cursor: string | undefined
  let pages = 0
  do {
    const page = await listMcpTools(cursor)
    all.push(...page.tools)
    cursor = page.nextCursor
    pages++
    if (pages >= MAX_TOOL_LIST_PAGES && cursor) {
      throw new Error(
        `tools/list: reached maximum pagination limit of ${MAX_TOOL_LIST_PAGES} pages while server indicated more pages (pagesFetched=${pages}, toolsCollected=${all.length}, lastCursor=${cursor})`
      )
    }
  } while (cursor)
  return all
}

function parseMcpJsonText(text: string): Record<string, unknown> {
  const trimmed = text.trim()
  if (!trimmed) return {}
  return JSON.parse(trimmed) as Record<string, unknown>
}
