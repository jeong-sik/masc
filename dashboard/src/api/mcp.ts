// MASC Dashboard — MCP-over-HTTP client and autoresearch helpers

import { postRaw, DEFAULT_MCP_TIMEOUT_MS } from './core'

// --- MCP over HTTP helper ---

interface McpCallResponse {
  result?: {
    content?: Array<{ type?: string; text?: string }>
    isError?: boolean
  }
  error?: { message?: string }
}

function parseMcpHttpResponse(raw: string): McpCallResponse {
  // Streamable HTTP may return SSE-formatted payload; extract first "data:" line
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
  const text = await postRaw('/mcp', {
    jsonrpc: '2.0',
    method: 'tools/call',
    params: {
      name: toolName,
      arguments: args,
    },
    id: Math.floor(Date.now() % 1000000),
  }, {
    Accept: 'application/json',
  }, DEFAULT_MCP_TIMEOUT_MS)
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
