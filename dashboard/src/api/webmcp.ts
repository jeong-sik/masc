// MASC Dashboard — WebMCP agent surface (Chrome origin trial, experiment lane)
//
// Relays a closed read-only subset of the masc MCP tool catalog to the page's
// `document.modelContext` (WebMCP, W3C draft). An in-browser agent then calls
// masc tools through the dashboard page instead of driving its DOM.
//
// Boundary rules:
// - No-op unless the browser exposes `document.modelContext` (feature detect,
//   no polyfill, no navigator.* fallback — that surface is deprecated).
// - The exposed set is the closed list below. Mutating tools stay out until an
//   approval design exists; adding a name here is a deliberate surface change.
// - Tool descriptions and input schemas come from the server catalog
//   (tools/list), so the WebMCP projection cannot drift from the MCP surface.

import { callMcpTool, listAllMcpTools } from './mcp'

// Closed allowlist of read-only projection tools. Order is registration order.
export const WEBMCP_READONLY_TOOLS: readonly string[] = [
  'masc_status',
  'masc_tasks',
  'masc_task_history',
  'masc_keeper_list',
  'masc_goal_list',
  'masc_board_search',
  'masc_messages',
  'masc_schedule_list',
]

export interface WebmcpToolResult {
  content: Array<{ type: 'text'; text: string }>
}

export interface WebmcpToolRegistration {
  name: string
  description: string
  inputSchema: Record<string, unknown>
  execute: (args: Record<string, unknown>) => Promise<WebmcpToolResult>
}

/** The subset of the WebMCP ModelContext interface this adapter uses. */
export interface ModelContextLike {
  registerTool: (tool: WebmcpToolRegistration) => Promise<void> | void
}

/**
 * Returns the document's WebMCP surface, or null when the browser does not
 * ship one (stable Chrome without the origin trial, every other browser).
 */
export function webmcpModelContext(doc: Document): ModelContextLike | null {
  const candidate = (doc as Document & { modelContext?: unknown }).modelContext
  if (typeof candidate !== 'object' || candidate === null) return null
  const registerTool = (candidate as { registerTool?: unknown }).registerTool
  return typeof registerTool === 'function' ? (candidate as ModelContextLike) : null
}

export interface WebmcpInstallReport {
  /** Tools registered on the model context, in registration order. */
  registered: string[]
  /** Allowlisted names the server catalog did not offer this session. */
  missing: string[]
}

export interface WebmcpInstallDeps {
  listTools: () => Promise<Array<{
    name: string
    description: string
    inputSchema: Record<string, unknown>
  }>>
  callTool: (name: string, args: Record<string, unknown>) => Promise<string>
}

const liveDeps: WebmcpInstallDeps = {
  listTools: listAllMcpTools,
  callTool: callMcpTool,
}

/**
 * Registers the allowlisted read-only masc tools on the given model context.
 * Names present in the allowlist but absent from the server catalog are
 * reported in `missing` — the caller decides how loudly to surface that.
 */
export async function installWebmcpAgentSurface(
  context: ModelContextLike,
  deps: WebmcpInstallDeps = liveDeps,
): Promise<WebmcpInstallReport> {
  const catalog = await deps.listTools()
  const byName = new Map(catalog.map(tool => [tool.name, tool]))
  const registered: string[] = []
  const missing: string[] = []
  for (const name of WEBMCP_READONLY_TOOLS) {
    const tool = byName.get(name)
    if (!tool) {
      missing.push(name)
      continue
    }
    await context.registerTool({
      name: tool.name,
      description: tool.description,
      inputSchema: tool.inputSchema,
      execute: async (args) => ({
        content: [{ type: 'text', text: await deps.callTool(tool.name, args) }],
      }),
    })
    registered.push(name)
  }
  return { registered, missing }
}
