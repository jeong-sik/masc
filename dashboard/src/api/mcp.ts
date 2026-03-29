// MASC Dashboard — MCP-over-HTTP client with session lifecycle

import { fetchWithTimeout, DEFAULT_MCP_TIMEOUT_MS } from './core'
import {
  MCP_INIT_COOLDOWN_MS,
  MCP_INITIALIZE_TIMEOUT_MS,
  MCP_INITIALIZED_NOTIFY_TIMEOUT_MS,
} from '../config/constants'
import { reportToolHostFailure } from './dashboard'

// --- MCP Session Management ---

let mcpSessionId: string | null = null
let initPromise: Promise<void> | null = null
let initCooldownTimer: ReturnType<typeof setTimeout> | null = null

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
    'Content-Type': 'application/json',
    Accept: 'application/json, text/event-stream',
    ...(extra ?? {}),
  }
  if (mcpSessionId) {
    headers['Mcp-Session-Id'] = mcpSessionId
  }
  return headers
}

async function mcpPost(body: unknown, timeoutMs = DEFAULT_MCP_TIMEOUT_MS): Promise<string> {
  const res = await fetchWithTimeout('/mcp', {
    method: 'POST',
    headers: mcpHeaders(),
    body: JSON.stringify(body),
  }, timeoutMs)
  // Capture session ID from response
  const sid = res.headers.get('Mcp-Session-Id')
  if (sid) mcpSessionId = sid
  if (!res.ok) {
    if (res.status === 403) {
      throw new Error('MCP 연결이 차단되었습니다. 로컬 환경에서만 사용할 수 있는 기능입니다.')
    }
    throw new Error(`POST /mcp: ${res.status} ${res.statusText}`)
  }
  return res.text()
}

async function ensureSession(): Promise<void> {
  if (mcpSessionId === '__blocked__') {
    throw new Error('MCP 연결이 차단되었습니다. 로컬 환경에서만 사용할 수 있는 기능입니다.')
  }
  if (mcpSessionId) return
  if (initPromise) return initPromise
  initPromise = (async () => {
    try {
      const res = await fetchWithTimeout('/mcp', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Accept: 'application/json, text/event-stream',
        },
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
      if (err instanceof Error && err.message.includes('403')) {
        mcpSessionId = '__blocked__'
      }
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

export async function callMcpTool(toolName: string, args: Record<string, unknown>): Promise<string> {
  const requestId = String(Math.floor(Date.now() % 1000000))
  let phase = mcpSessionId ? 'tools/call' : 'initialize'
  try {
    await ensureSession()
    phase = 'tools/call'
    const text = await mcpPost({
      jsonrpc: '2.0',
      method: 'tools/call',
      params: {
        name: toolName,
        arguments: args,
      },
      id: Number.parseInt(requestId, 10),
    })
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

function parseMcpListResponse(raw: string): McpListResponse {
  const line = raw.split('\n').find(l => l.startsWith('data: '))
  const payload = line ? line.slice(6).trim() : raw.trim()
  return JSON.parse(payload) as McpListResponse
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
  if (parsed.error?.message) throw new Error(parsed.error.message)
  return parsed.result ?? { tools: [] }
}

export async function listAllMcpTools(): Promise<McpToolsListResult['tools']> {
  const all: McpToolsListResult['tools'] = []
  let cursor: string | undefined
  do {
    const page = await listMcpTools(cursor)
    all.push(...page.tools)
    cursor = page.nextCursor
  } while (cursor)
  return all
}

function parseMcpJsonText(text: string): Record<string, unknown> {
  const trimmed = text.trim()
  if (!trimmed) return {}
  return JSON.parse(trimmed) as Record<string, unknown>
}

// --- Autoresearch ---

export async function fetchAutoresearchStatus(loopId: string): Promise<Record<string, unknown>> {
  return parseMcpJsonText(await callMcpTool('masc_autoresearch_status', { loop_id: loopId }))
}

export async function injectAutoresearchHypothesis(
  loopId: string,
  hypothesis: string,
): Promise<Record<string, unknown>> {
  return parseMcpJsonText(
    await callMcpTool('masc_autoresearch_inject', {
      loop_id: loopId,
      hypothesis,
    }),
  )
}

export async function runAutoresearchCycle(loopId: string): Promise<Record<string, unknown>> {
  return parseMcpJsonText(await callMcpTool('masc_autoresearch_cycle', { loop_id: loopId }))
}

export async function stopAutoresearchLoop(
  loopId: string,
  reason?: string,
): Promise<Record<string, unknown>> {
  return parseMcpJsonText(
    await callMcpTool('masc_autoresearch_stop', {
      loop_id: loopId,
      ...(reason ? { reason } : {}),
    }),
  )
}
