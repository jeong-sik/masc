// @vitest-environment happy-dom
//
// task-2325 (P3 follow-up to #42979, reviewer: masc-pro-builder / be-sleepers).
// The pure label function was already pinned by tool-display-label.test.ts and
// the shared fixture table, and the OCaml pane tests cover the TUI fan — but
// nothing failed if one of these components went back to drawing
// `${tool.name}` directly. These tests render the components themselves and
// pin the visible outcome: the label appears, the wire name does not. The
// wire name stays the identity (stored in action records, sent to the API);
// only what these surfaces DRAW is under test here.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render, h } from 'preact'
import { act } from 'preact/test-utils'
import { listAllMcpTools } from '../../api/mcp'
import { loadToolSchemas, schemasError, schemasLoading, selectedTool } from './tool-executor-state'
import { ToolExecutor } from './tool-executor'
import { ToolPicker } from './tool-picker'
import { ToolResultDisplay } from './tool-result-display'
import type { McpToolSchema } from '../../types/json-schema'

vi.mock('../../api/mcp', () => ({
  listAllMcpTools: vi.fn(),
  callMcpTool: vi.fn(),
}))

const WIRE_NAME = 'keeper_task_done'
const LABEL = 'KeeperTaskDone'
const SLUG = 'browser-lanes'

function makeTool(name: string): McpToolSchema {
  // The description must not mention the tool name: the "wire name is never
  // drawn" assertions scan the whole subtree text, and both detail and row
  // render `tool.description` verbatim.
  return { name, description: '테스트 도구 설명', inputSchema: { type: 'object', properties: {} } }
}

// listAllMcpTools returns a wire-shaped tool list (McpToolsListResult['tools'])
// that loadToolSchemas re-casts into the executor's signal. Cast at the mock
// boundary with the declared return type instead of an inline `as never`,
// which gives the compiler nothing to check.
const toolsArg = (tools: McpToolSchema[]): Awaited<ReturnType<typeof listAllMcpTools>> => tools as never

describe('tool-executor surfaces draw the display label, not the raw wire name', () => {
  let el: HTMLDivElement
  beforeEach(() => {
    el = document.createElement('div')
    document.body.appendChild(el)
    // Default: an empty catalog so the executor's load effect settles without
    // an error toast; the picker test overrides this with real rows.
    vi.mocked(listAllMcpTools).mockReset().mockResolvedValue(toolsArg([]))
    schemasError.value = null
    schemasLoading.value = false
    selectedTool.value = null
  })
  afterEach(() => {
    render(null, el)
    el.remove()
    schemasError.value = null
    schemasLoading.value = false
    selectedTool.value = null
  })

  it('executor detail title shows the label', async () => {
    selectedTool.value = makeTool(WIRE_NAME)
    render(h(ToolExecutor, {}), el)
    await act(async () => {}) // let the schema load effect settle
    expect(el.querySelector('h3')?.textContent).toBe(LABEL)
    expect(el.textContent).not.toContain(WIRE_NAME)
  })

  it('executor detail passes a skill slug through unchanged', async () => {
    selectedTool.value = makeTool(SLUG)
    render(h(ToolExecutor, {}), el)
    await act(async () => {})
    expect(el.querySelector('h3')?.textContent).toBe(SLUG)
  })

  it('picker rows show the label and never the wire name', async () => {
    vi.mocked(listAllMcpTools).mockResolvedValue(toolsArg([makeTool(WIRE_NAME), makeTool(SLUG)]))
    await loadToolSchemas(true)
    render(h(ToolPicker, {}), el)
    expect(el.textContent).toContain(LABEL)
    expect(el.textContent).toContain(SLUG)
    expect(el.textContent).not.toContain(WIRE_NAME)
  })

  it('result display header shows the label for an inline payload', () => {
    render(h(ToolResultDisplay, { success: true, text: 'ok', toolName: WIRE_NAME, timestamp: 1_700_000_000_000 }), el)
    expect(el.textContent).toContain(LABEL)
    expect(el.textContent).not.toContain(WIRE_NAME)
  })

  it('result display header shows the label through the blob-marker path too', () => {
    const marker = `[masc:blob sha256=${'a'.repeat(64)} bytes=10 mime=text/plain preview="out"]`
    render(h(ToolResultDisplay, { success: true, text: marker, toolName: WIRE_NAME, timestamp: 1_700_000_000_000 }), el)
    expect(el.textContent).toContain(LABEL)
    expect(el.textContent).not.toContain(WIRE_NAME)
  })

  it('control: with the label port stubbed to identity the raw name shows', async () => {
    // Sensitivity proof for the assertions above: the same component, with
    // toolDisplayLabel replaced by the identity function, DOES draw the wire
    // name. If someone reverts a call site to `${tool.name}`, the positive
    // tests fail exactly like this control renders it.
    vi.resetModules()
    vi.doMock('../../lib/tool-display-label', () => ({ toolDisplayLabel: (name: string) => name }))
    const { ToolResultDisplay: IdentityResult } = await import('./tool-result-display')
    render(h(IdentityResult, { success: true, text: 'ok', toolName: WIRE_NAME, timestamp: 1_700_000_000_000 }), el)
    expect(el.textContent).toContain(WIRE_NAME)
    vi.doUnmock('../../lib/tool-display-label')
    vi.resetModules()
  })
})
