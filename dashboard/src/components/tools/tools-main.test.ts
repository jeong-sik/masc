import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({
  loadTools: vi.fn(),
  toolsData: { value: null as null | { generated_at?: string; tool_inventory: { tools: unknown[] }; tool_usage: Record<string, unknown> & { registered_count: number; distinct_tools_called: number; never_called_count: number } } },
  toolsLoading: { value: false },
  toolsError: { value: null as string | null },
}))

vi.mock('./tool-state', () => ({
  loadTools: mocks.loadTools,
  toolsData: mocks.toolsData,
  toolsError: mocks.toolsError,
  toolsLoading: mocks.toolsLoading,
}))

vi.mock('../common/card', () => ({
  Card: ({ title, children }: { title: string; children: unknown }) => html`
    <section data-card-title=${title}>
      <h2>${title}</h2>
      ${children}
    </section>
  `,
}))

vi.mock('../tool-metrics', () => ({
  ToolMetrics: () => html`<div>ToolMetrics</div>`,
}))

vi.mock('./tool-full-inventory', () => ({
  FullInventoryView: () => html`<div>FullInventoryView</div>`,
}))

vi.mock('./prompt-registry-panel', () => ({
  PromptRegistryPanel: () => html`<div>PromptRegistryPanel</div>`,
}))

vi.mock('./config-resolution-panel', () => ({
  ConfigResolutionPanel: () => html`<div>ConfigResolutionPanel</div>`,
}))

vi.mock('../tool-executor/tool-executor', () => ({
  ToolExecutor: () => html`<div>ToolExecutor</div>`,
}))

import { Tools } from './tools-main'

async function flush(): Promise<void> {
  for (let i = 0; i < 4; i += 1) {
    await Promise.resolve()
    await new Promise(resolve => setTimeout(resolve, 0))
  }
}

describe('Tools', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    mocks.loadTools.mockClear()
    mocks.toolsData.value = null
    mocks.toolsLoading.value = false
    mocks.toolsError.value = null
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('loads tool data and renders full inventory with prompt registry inside the tools surface', async () => {
    render(html`<${Tools} />`, container)
    await flush()

    expect(mocks.loadTools).toHaveBeenCalledTimes(1)
    expect(container.textContent).toContain('ConfigResolutionPanel')
    expect(container.textContent).toContain('시스템 도구 목록')
    expect(container.textContent).toContain('FullInventoryView')
    expect(container.textContent).toContain('도구 사용 현황')
    expect(container.textContent).toContain('ToolMetrics')
    expect(container.textContent).toContain('PromptRegistryPanel')
  })

  it('renders tool usage coverage gap provenance', async () => {
    mocks.toolsData.value = {
      tool_inventory: { tools: [] },
      tool_usage: {
        registered_count: 0,
        distinct_tools_called: 0,
        never_called_count: 0,
        source: 'tool_usage',
        health: 'coverage_gap',
        stale_reason: 'tool_usage_append_failed',
        entry_count: 0,
        coverage_gap_count: 1,
        coverage_gaps: [
          {
            schema: 'masc.telemetry_coverage_gap.v1',
            source: 'tool_usage',
            producer: 'tool_usage_log',
            durable_store: '.masc/tool_usage',
            dashboard_surface: '/api/v1/dashboard/tools',
            stale_reason: 'tool_usage_append_failed',
            error: 'synthetic append failure',
          },
        ],
      },
    }

    render(html`<${Tools} />`, container)
    await flush()

    expect(container.textContent).toContain('coverage gaps 1: tool_usage_append_failed')
    expect(container.textContent).toContain('producer tool_usage_log')
    expect(container.textContent).toContain('store .masc/tool_usage')
    expect(container.textContent).toContain('surface /api/v1/dashboard/tools')
    expect(container.textContent).toContain('error synthetic append failure')
  })
})
