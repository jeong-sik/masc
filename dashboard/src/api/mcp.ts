// MASC Dashboard — MCP 2026-07-28 over Streamable HTTP

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
import { reportToolHostFailure } from './tool-host-failure'
import { showActionToast } from '../components/common/toast'
import { errorToString } from '../lib/format-string'

const MCP_PROTOCOL_VERSION = '2026-07-28'
const MCP_BLOCKED_MESSAGE = 'MCP 연결이 차단되었습니다.'
const MCP_AUTH_CHANGED_MESSAGE = 'MCP authentication changed during request'

interface McpRequestBinding {
  readonly authRevision: number
}

let blockedAuthRevision: number | null = null
let observedTokenRevision = currentStoredTokenRevision()
let blockedToastShown = false

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
): Promise<string> {
  assertBinding(binding)
  const request = currentRequest(body)
  const res = await fetchWithTimeout('/mcp', {
    method: 'POST',
    headers: mcpHeadersForActor(binding, request.method, request.name, actorName),
    body: JSON.stringify(request.body),
  }, timeoutMs)
  assertBinding(binding)
  if (!res.ok) {
    if (res.status === 403) {
      blockedAuthRevision = binding.authRevision
      throw new Error(MCP_BLOCKED_MESSAGE)
    }
    throw await apiRequestErrorFromResponse('POST', '/mcp', res)
  }
  const text = await res.text()
  assertBinding(binding)
  return text
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
  try {
    const binding = await ensureBinding()
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
    }, binding, DEFAULT_MCP_TIMEOUT_MS, actor)
    const parsed = parseMcpHttpResponse(text)
    return extractMcpText(parsed)
  } catch (err) {
    const message = errorToString(err)
    if (shouldReportToolHostFailure(message)) {
      await bestEffortReportToolHostFailure({
        toolName,
        message,
        phase: 'tools/call',
        requestId,
        timeoutMs: DEFAULT_MCP_TIMEOUT_MS,
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
  const binding = await ensureBinding()
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
