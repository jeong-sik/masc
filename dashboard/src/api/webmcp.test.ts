import { describe, expect, it } from 'vitest'

import {
  WEBMCP_READONLY_TOOLS,
  installWebmcpAgentSurface,
  webmcpModelContext,
  type ModelContextLike,
  type WebmcpToolRegistration,
} from './webmcp'

function catalogEntry(name: string) {
  return {
    name,
    description: `${name} description`,
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  }
}

function recordingContext() {
  const registrations: WebmcpToolRegistration[] = []
  const context: ModelContextLike = {
    registerTool: (tool) => {
      registrations.push(tool)
    },
  }
  return { context, registrations }
}

describe('webmcpModelContext', () => {
  it('returns null when the document has no modelContext', () => {
    expect(webmcpModelContext({} as Document)).toBeNull()
  })

  it('returns null when modelContext lacks registerTool', () => {
    const doc = { modelContext: { getTools: () => [] } } as unknown as Document
    expect(webmcpModelContext(doc)).toBeNull()
  })

  it('returns the surface when registerTool is a function', () => {
    const surface = { registerTool: () => undefined }
    const doc = { modelContext: surface } as unknown as Document
    expect(webmcpModelContext(doc)).toBe(surface)
  })
})

describe('installWebmcpAgentSurface', () => {
  it('registers exactly the allowlist ∩ catalog, keeping server schema and description', async () => {
    const { context, registrations } = recordingContext()
    const catalog = [
      catalogEntry('masc_status'),
      catalogEntry('masc_tasks'),
      // Mutating tools in the catalog must never be registered.
      catalogEntry('masc_transition'),
      catalogEntry('masc_broadcast'),
    ]
    const report = await installWebmcpAgentSurface(context, {
      listTools: async () => catalog,
      callTool: async () => '',
    })
    expect(report.registered).toEqual(['masc_status', 'masc_tasks'])
    expect(registrations.map(r => r.name)).toEqual(['masc_status', 'masc_tasks'])
    expect(registrations[0]!.description).toBe('masc_status description')
    expect(registrations[0]!.inputSchema).toEqual(catalog[0]!.inputSchema)
  })

  it('reports allowlisted names the catalog does not offer', async () => {
    const { context } = recordingContext()
    const report = await installWebmcpAgentSurface(context, {
      listTools: async () => [catalogEntry('masc_status')],
      callTool: async () => '',
    })
    expect(report.registered).toEqual(['masc_status'])
    expect(report.missing).toEqual(
      WEBMCP_READONLY_TOOLS.filter(name => name !== 'masc_status'),
    )
  })

  it('relays execute to the MCP tool call and wraps the text result', async () => {
    const { context, registrations } = recordingContext()
    const calls: Array<{ name: string; args: Record<string, unknown> }> = []
    await installWebmcpAgentSurface(context, {
      listTools: async () => [catalogEntry('masc_task_history')],
      callTool: async (name, args) => {
        calls.push({ name, args })
        return 'history text'
      },
    })
    const result = await registrations[0]!.execute({ task_id: 'task-1', limit: 5 })
    expect(calls).toEqual([
      { name: 'masc_task_history', args: { task_id: 'task-1', limit: 5 } },
    ])
    expect(result).toEqual({ content: [{ type: 'text', text: 'history text' }] })
  })

  it('propagates tool call failures to the agent instead of masking them', async () => {
    const { context, registrations } = recordingContext()
    await installWebmcpAgentSurface(context, {
      listTools: async () => [catalogEntry('masc_status')],
      callTool: async () => {
        throw new Error('MCP 연결이 차단되었습니다.')
      },
    })
    await expect(registrations[0]!.execute({})).rejects.toThrow('MCP 연결이 차단되었습니다.')
  })

  it('contains no mutating tool names in the allowlist', () => {
    const mutating = ['masc_transition', 'masc_broadcast', 'masc_add_task', 'masc_keeper_up', 'masc_keeper_down']
    for (const name of mutating) {
      expect(WEBMCP_READONLY_TOOLS).not.toContain(name)
    }
  })
})
