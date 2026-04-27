// MASC Dashboard — MCP-over-HTTP client with session lifecycle

import {
  apiRequestErrorFromResponse,
  fetchWithTimeout,
  DEFAULT_MCP_TIMEOUT_MS,
  authHeaders,
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

// --- MCP Session Management ---

const MCP_BLOCKED_MESSAGE = 'MCP 연결이 차단되었습니다.'
const MCP_SESSION_BLOCKED = '__blocked__'

let mcpSessionId: string | null = null
let initPromise: Promise<void> | null = null
let initCooldownTimer: ReturnType<typeof setTimeout> | null = null

export { ensureDevToken }

async function bestEffortReportToolHostFailure(payload: {
  toolName: string
  message: string
  phase: string
  requestId?: string
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
      session_id: mcpSessionId ?? undefined,
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

function mcpHeaders(extra?: Record<string, string>): Record<string, string> {
  const headers: Record<string, string> = {
    ...authHeaders(),
    'Content-Type': 'application/json',
    Accept: 'application/json, text/event-stream',
    ...(extra ?? {}),
  }
  if (mcpSessionId) {
    headers['Mcp-Session-Id'] = mcpSessionId
  }
  return headers
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
  actorName?: string | null,
  extra?: Record<string, string>,
): Record<string, string> {
  const headers: Record<string, string> = {
    ...authHeaders({ actorName }),
    'Content-Type': 'application/json',
    Accept: 'application/json, text/event-stream',
    ...(extra ?? {}),
  }
  if (mcpSessionId) {
    headers['Mcp-Session-Id'] = mcpSessionId
  }
  return headers
}

async function mcpPost(
  body: unknown,
  timeoutMs = DEFAULT_MCP_TIMEOUT_MS,
  actorName?: string | null,
): Promise<string> {
  const res = await fetchWithTimeout('/mcp', {
    method: 'POST',
    headers: mcpHeadersForActor(actorName),
    body: JSON.stringify(body),
  }, timeoutMs)
  // Capture session ID from response
  const sid = res.headers.get('Mcp-Session-Id')
  if (sid) mcpSessionId = sid
  if (!res.ok) {
    if (res.status === 403) {
      mcpSessionId = MCP_SESSION_BLOCKED
      throw new Error(MCP_BLOCKED_MESSAGE)
    }
    throw await apiRequestErrorFromResponse('POST', '/mcp', res)
  }
  return res.text()
}

let blockedToastShown = false

async function ensureSession(): Promise<void> {
  if (mcpSessionId === MCP_SESSION_BLOCKED) {
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
  if (mcpSessionId) return
  if (initPromise) return initPromise
  initPromise = (async () => {
    await ensureDevToken()
    try {
      const res = await fetchWithTimeout('/mcp', {
        method: 'POST',
        headers: mcpHeaders(),
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
      if (!res.ok) {
        if (res.status === 403) {
          mcpSessionId = MCP_SESSION_BLOCKED
          throw new Error(MCP_BLOCKED_MESSAGE)
        }
        throw await apiRequestErrorFromResponse('POST', '/mcp initialize', res)
      }
      const sid = res.headers.get('Mcp-Session-Id')
      if (sid) mcpSessionId = sid
      // Send initialized notification
      if (mcpSessionId) {
        await fetchWithTimeout('/mcp', {
          method: 'POST',
          headers: mcpHeaders(),
          body: JSON.stringify({
            jsonrpc: '2.0',
            method: 'notifications/initialized',
          }),
        }, MCP_INITIALIZED_NOTIFY_TIMEOUT_MS).catch(err => console.warn('[mcp] initialized notification failed:', err))
      }
      initPromise = null
    } catch (err) {
      // Keep initPromise alive briefly to prevent retry storms
      if (initCooldownTimer) {
        clearTimeout(initCooldownTimer)
      }
      initCooldownTimer = setTimeout(() => {
        initPromise = null
        initCooldownTimer = null
      }, MCP_INIT_COOLDOWN_MS)
      throw err
    }
  })()
  return initPromise
}

export function resetMcpClientState(): void {
  mcpSessionId = null
  initPromise = null
  resetDevTokenBootstrap()
  if (initCooldownTimer) {
    clearTimeout(initCooldownTimer)
    initCooldownTimer = null
  }
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
  let phase = mcpSessionId ? 'tools/call' : 'initialize'
  try {
    await ensureSession()
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
    }, DEFAULT_MCP_TIMEOUT_MS, actor)
    const parsed = parseMcpHttpResponse(text)
    return extractMcpText(parsed)
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    if (shouldReportToolHostFailure(message)) {
      await bestEffortReportToolHostFailure({
        toolName,
        message,
        phase,
        requestId: phase === 'tools/call' ? requestId : undefined,
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

export async function listMcpTools(cursor?: string): Promise<McpToolsListResult> {
  await ensureSession()
  const text = await mcpPost({
    jsonrpc: '2.0',
    method: 'tools/list',
    params: cursor ? { cursor } : {},
    id: Date.now(),
  })
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
