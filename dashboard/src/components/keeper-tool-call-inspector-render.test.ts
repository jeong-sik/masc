import { html } from 'htm/preact'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

void vi
vi.setConfig({ testTimeout: 120_000 })

async function flushUi(): Promise<void> {
  await act(async () => {
    for (let i = 0; i < 4; i += 1) {
      await Promise.resolve()
      await vi.advanceTimersByTimeAsync(0)
    }
  })
}

async function loadInspector(fetchKeeperToolCalls: ReturnType<typeof vi.fn>) {
  vi.resetModules()
  vi.doMock('../api/dashboard', () => ({
    fetchKeeperToolCalls,
  }))
  return import('./keeper-tool-call-inspector')
}

describe('KeeperToolCallInspector render', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    vi.useFakeTimers()
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.clearAllMocks()
    vi.resetModules()
    vi.doUnmock('../api/dashboard')
    vi.useRealTimers()
  })

  it('surfaces copy actions for expanded tool call input and output', async () => {
    const fetchKeeperToolCalls = vi.fn().mockResolvedValue({
      keeper: 'analyst',
      count: 1,
      source: 'tool_call_io',
      health: 'ok',
      entries: [
        {
          ts: 1_777_100_000,
          keeper: 'analyst',
          tool: 'Execute',
          input: { cmd: 'pwd' },
          output: '{"ok":true}',
          success: true,
          duration_ms: 42,
          model: 'claude-code:auto',
        },
      ],
    })

    const { KeeperToolCallInspector } = await loadInspector(fetchKeeperToolCalls)
    await act(async () => {
      render(html`<${KeeperToolCallInspector} keeperName="analyst" />`, container)
      await Promise.resolve()
    })
    await flushUi()

    const rowToggle = container.querySelector('button[aria-expanded="false"]') as HTMLButtonElement | null
    expect(rowToggle).not.toBeNull()
    await act(async () => {
      rowToggle?.click()
      await Promise.resolve()
    })
    await flushUi()

    const inputCopy = container.querySelector('[aria-label="도구 호출 입력 복사"]') as HTMLButtonElement | null
    const outputCopy = container.querySelector('[aria-label="도구 호출 출력 복사"]') as HTMLButtonElement | null
    expect(inputCopy).not.toBeNull()
    expect(outputCopy).not.toBeNull()
    expect(inputCopy?.getAttribute('title')).toBe('도구 호출 입력 복사')
    expect(outputCopy?.getAttribute('title')).toBe('도구 호출 출력 복사')
  })

  it('links safe tool-call file inputs back to the Code IDE route', async () => {
    const fetchKeeperToolCalls = vi.fn().mockResolvedValue({
      keeper: 'analyst',
      count: 1,
      source: 'tool_call_io',
      health: 'ok',
      entries: [
        {
          ts: 1_777_100_000,
          keeper: 'analyst',
          tool: 'keeper_fs_read',
          input: { file_path: 'lib/runtime.ml', line: 12 },
          output: 'file contents',
          success: true,
          duration_ms: 42,
        },
      ],
    })

    const { KeeperToolCallInspector } = await loadInspector(fetchKeeperToolCalls)
    await act(async () => {
      render(html`<${KeeperToolCallInspector} keeperName="analyst" />`, container)
      await Promise.resolve()
    })
    await flushUi()

    const rowToggle = container.querySelector('button[aria-expanded="false"]') as HTMLButtonElement | null
    await act(async () => {
      rowToggle?.click()
      await Promise.resolve()
    })
    await flushUi()

    const codeLink = container.querySelector('[data-testid="keeper-tool-code-link"]') as HTMLButtonElement | null
    expect(codeLink).not.toBeNull()
    expect(codeLink?.textContent).toBe('Code')
    expect(codeLink?.getAttribute('title')).toBe('Code lib/runtime.ml:12')

    await act(async () => {
      codeLink?.click()
      await Promise.resolve()
    })
    expect(window.location.hash).toBe('#code?section=ide-shell&view=source&file=lib%2Fruntime.ml&line=12&surface=Tool&label=keeper_fs_read&source_id=tool%3Aanalyst%3A1777100000%3Akeeper_fs_read&keeper=analyst')
  })

  it('routes nested tool-call evidence to operational IDE surfaces', async () => {
    const fetchKeeperToolCalls = vi.fn().mockResolvedValue({
      keeper: 'analyst',
      count: 1,
      source: 'tool_call_io',
      health: 'ok',
      entries: [
        {
          ts: 1_777_100_000,
          keeper: 'analyst',
          tool: 'keeper_apply_patch',
          input: {
            context: {

              task_id: 'task-runtime',
              board_post_id: 'post-1',
              comment_id: 'comment-1',
            },
            failure_envelope: {
              evidence_ref: {
                file_path: 'lib/runtime.ml',
                line_start: '8',
                pr_number: 15125,
                branch: 'fix/runtime',
                log_id: 'turn-8',
                session_id: 'sess-nested',
                operation_id: 'op-nested',
                worker_run_id: 'wr-nested',
              },
            },
          },
          output: 'patched',
          success: true,
          duration_ms: 42,
        },
      ],
    })

    const { KeeperToolCallInspector } = await loadInspector(fetchKeeperToolCalls)
    await act(async () => {
      render(html`<${KeeperToolCallInspector} keeperName="analyst" />`, container)
      await Promise.resolve()
    })
    await flushUi()

    const rowToggle = container.querySelector('button[aria-expanded="false"]') as HTMLButtonElement | null
    await act(async () => {
      rowToggle?.click()
      await Promise.resolve()
    })
    await flushUi()

    const routeLinks = [...container.querySelectorAll<HTMLButtonElement>('.keeper-tool-route-link')]
    expect(routeLinks.map(link => link.textContent?.trim())).toEqual([
      'Code',
      'Task',
      'Board',
      'Comment',
      'PR',
      'Git',
      'Log',
      'Telemetry',
      'Keeper',
    ])

    await act(async () => {
      routeLinks.find(link => link.textContent?.trim() === 'Code')?.click()
      await Promise.resolve()
    })
    expect(window.location.hash).toBe('#code?section=ide-shell&view=source&file=lib%2Fruntime.ml&line=8&surface=Tool&label=keeper_apply_patch&source_id=tool%3Aanalyst%3A1777100000%3Akeeper_apply_patch&keeper=analyst')

    await act(async () => {
      routeLinks.find(link => link.textContent?.trim() === 'Telemetry')?.click()
      await Promise.resolve()
    })
    expect(window.location.hash).toBe('#monitoring?section=fleet-health&view=event-log&session_id=sess-nested&operation_id=op-nested&worker_run_id=wr-nested&q=turn-8')
  })

  it('renders an activity dossier for recent tool-call evidence', async () => {
    const fetchKeeperToolCalls = vi.fn().mockResolvedValue({
      keeper: 'analyst',
      count: 3,
      source: 'tool_call_io',
      health: 'coverage_gap',
      entry_count: 3,
      entries: [
        {
          ts: 1_777_099_990,
          keeper: 'analyst',
          tool: 'masc_status',
          input: {},
          output: 'ok',
          success: true,
          duration_ms: 24,
        },
        {
          ts: 1_777_100_000,
          keeper: 'analyst',
          tool: 'keeper_fs_read',
          input: { file_path: 'lib/runtime.ml', line: 12 },
          output: 'file contents',
          success: true,
          duration_ms: 42,
        },
        {
          ts: 1_777_100_010,
          keeper: 'analyst',
          tool: 'Execute',
          input: { cmd: 'false', context: { task_id: 'task-runtime' } },
          output: 'exit 1',
          success: false,
          duration_ms: 2_600,
          trace_id: 'trace-runtime',
          turn: 9,
          lane: 'autonomous',
        },
      ],
    })

    const { KeeperToolCallInspector } = await loadInspector(fetchKeeperToolCalls)
    await act(async () => {
      render(html`<${KeeperToolCallInspector} keeperName="analyst" />`, container)
      await Promise.resolve()
    })
    await flushUi()

    const dossier = container.querySelector('[data-testid="keeper-tool-call-dossier"]')
    expect(dossier).not.toBeNull()
    const text = dossier?.textContent ?? ''
    expect(text).toContain('Activity Dossier')
    expect(text).toContain('1 failed / 3')
    expect(text).toContain('latest')
    expect(text).toContain('Execute')
    expect(text).toContain('slow call')
    expect(text).toContain('source health')
    expect(text).toContain('Evidence links')
    expect(text).toContain('Code')
    expect(text).toContain('Task')
  })

  it('does not render Code links for unsafe absolute tool-call file inputs', async () => {
    const fetchKeeperToolCalls = vi.fn().mockResolvedValue({
      keeper: 'analyst',
      count: 1,
      source: 'tool_call_io',
      health: 'ok',
      entries: [
        {
          ts: 1_777_100_000,
          keeper: 'analyst',
          tool: 'keeper_fs_read',
          input: { file_path: '/tmp/runtime.ml', line: 12 },
          output: 'file contents',
          success: true,
          duration_ms: 42,
        },
      ],
    })

    const { KeeperToolCallInspector } = await loadInspector(fetchKeeperToolCalls)
    await act(async () => {
      render(html`<${KeeperToolCallInspector} keeperName="analyst" />`, container)
      await Promise.resolve()
    })
    await flushUi()

    const rowToggle = container.querySelector('button[aria-expanded="false"]') as HTMLButtonElement | null
    await act(async () => {
      rowToggle?.click()
      await Promise.resolve()
    })
    await flushUi()

    expect(container.querySelector('[data-testid="keeper-tool-code-link"]')).toBeNull()
  })

  it('surfaces coverage gap provenance when tool-call IO is stale', async () => {
    const fetchKeeperToolCalls = vi.fn().mockResolvedValue({
      keeper: 'analyst',
      count: 0,
      source: 'tool_call_io',
      health: 'coverage_gap',
      stale_reason: 'tool_call_io_append_failed',
      coverage_gap_count: 1,
      coverage_gaps: [
        {
          source: 'tool_call_io',
          producer: 'keeper_tool_call_log.append',
          durable_store: '.masc/tool_calls',
          dashboard_surface: '/api/v1/keepers/:name/tool-calls',
          stale_reason: 'tool_call_io_append_failed',
          trace_id: 'trace-tool-call-gap',
          error: 'append denied',
        },
      ],
      entries: [],
    })

    const { KeeperToolCallInspector } = await loadInspector(fetchKeeperToolCalls)
    await act(async () => {
      render(html`<${KeeperToolCallInspector} keeperName="analyst" />`, container)
      await Promise.resolve()
    })
    await flushUi()

    expect(container.textContent).toContain('Tool-call log write failed · 1 recorded gap')
    expect(container.textContent).toContain('impact Tool Monitor may undercount keeper tool I/O around this trace.')
    expect(container.textContent).toContain('reason tool_call_io_append_failed')
    expect(container.textContent).toContain('producer keeper_tool_call_log.append')
    expect(container.textContent).toContain('store .masc/tool_calls')
    expect(container.textContent).toContain('surface /api/v1/keepers/:name/tool-calls')
    expect(container.textContent).toContain('trace trace-tool-call-gap')
    expect(container.textContent).toContain('error append denied')
  })
})
