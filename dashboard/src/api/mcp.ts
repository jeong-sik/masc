// MASC Dashboard — MCP-over-HTTP client with session lifecycle

import { fetchWithTimeout, DEFAULT_MCP_TIMEOUT_MS } from './core'

// --- MCP Session Management ---

let mcpSessionId: string | null = null
let initPromise: Promise<void> | null = null

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
      }, 10000)
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
        }, 5000).catch(() => {})
      }
    } catch (err) {
      if (err instanceof Error && err.message.includes('403')) {
        mcpSessionId = '__blocked__'
      }
      throw err
    } finally {
      initPromise = null
    }
  })()
  return initPromise
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
  await ensureSession()
  const text = await mcpPost({
    jsonrpc: '2.0',
    method: 'tools/call',
    params: {
      name: toolName,
      arguments: args,
    },
    id: Math.floor(Date.now() % 1000000),
  })
  const parsed = parseMcpHttpResponse(text)
  return extractMcpText(parsed)
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
