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

  // A keeper moved from local to docker keeps one trace, so the two eras sit in
  // the same list. Reading a pre-move failure as a post-move one is the mistake
  // this filter exists to stop, so the filter has to actually drop rows.
  it('filters tool calls by the sandbox each one recorded', async () => {
    const entry = (tool: string, sandbox: string) => ({
      ts: 1_777_100_000,
      keeper: 'code-reviewer',
      tool,
      input: {},
      output: '{"ok":true}',
      success: true,
      duration_ms: 1,
      sandbox_profile: sandbox,
    })
    const fetchKeeperToolCalls = vi.fn().mockResolvedValue({
      keeper: 'code-reviewer',
      count: 2,
      source: 'tool_call_io',
      health: 'ok',
      entries: [entry('BeforeTheMove', 'local'), entry('AfterTheMove', 'docker')],
    })

    const { KeeperToolCallInspector } = await loadInspector(fetchKeeperToolCalls)
    await act(async () => {
      render(html`<${KeeperToolCallInspector} keeperName="code-reviewer" />`, container)
      await Promise.resolve()
    })
    await flushUi()

    expect(container.textContent).toContain('BeforeTheMove')
    expect(container.textContent).toContain('AfterTheMove')

    // Offered from the data, so a third profile would appear here on its own.
    const select = container.querySelector('select[aria-label="샌드박스 필터"]') as HTMLSelectElement | null
    expect(select).not.toBeNull()
    expect([...(select?.options ?? [])].map(o => o.value)).toEqual(['', 'docker', 'local'])

    await act(async () => {
      if (select) {
        select.value = 'docker'
        select.dispatchEvent(new Event('change', { bubbles: true }))
      }
      await Promise.resolve()
    })
    await flushUi()

    expect(container.textContent).toContain('AfterTheMove')
    expect(container.textContent).not.toContain('BeforeTheMove')
  })

  // One profile means nothing to choose between, so the select stays away --
  // but which sandbox it was still answers a question. A keeper configured for
  // docker whose calls all say local is the case worth seeing, and dropping the
  // row drops exactly that.
  it('names the sandbox when every call ran in the same one', async () => {
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
          input: {},
          output: '{"ok":true}',
          success: true,
          duration_ms: 1,
          sandbox_profile: 'docker',
        },
      ],
    })

    const { KeeperToolCallInspector } = await loadInspector(fetchKeeperToolCalls)
    await act(async () => {
      render(html`<${KeeperToolCallInspector} keeperName="analyst" />`, container)
      await Promise.resolve()
    })
    await flushUi()

    expect(container.querySelector('select[aria-label="샌드박스 필터"]')).toBeNull()
    expect(container.textContent).toContain('샌드박스: docker')
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

  // A tool that behaved unexpectedly is one an operator wants to open, and
  // the row alone did not say which file to open. The server derives the path
  // from the tool name; a built-in ships no file and sends no field, so the
  // line is absent rather than showing an empty path.
  it('names the file a tool was defined in, and omits the line for a built-in', async () => {
    const entry = (tool: string, definition_source?: string) => ({
      ts: 1_777_100_000,
      keeper: 'analyst',
      tool,
      input: {},
      output: '{}',
      success: true,
      duration_ms: 12,
      ...(definition_source === undefined ? {} : { definition_source }),
    })
    const fetchKeeperToolCalls = vi.fn().mockResolvedValue({
      keeper: 'analyst',
      count: 2,
      source: 'tool_call_io',
      health: 'ok',
      entries: [entry('keeper_broadcast', 'tools/keeper_broadcast.toml'), entry('Execute')],
    })

    const { KeeperToolCallInspector } = await loadInspector(fetchKeeperToolCalls)
    await act(async () => {
      render(html`<${KeeperToolCallInspector} keeperName="analyst" />`, container)
      await Promise.resolve()
    })
    await flushUi()

    const toggles = Array.from(
      container.querySelectorAll('button[aria-expanded="false"]'),
    ) as HTMLButtonElement[]
    expect(toggles.length).toBeGreaterThanOrEqual(2)
    await act(async () => {
      toggles.forEach(toggle => toggle.click())
      await Promise.resolve()
    })
    await flushUi()

    expect(container.textContent).toContain('tools/keeper_broadcast.toml')
    expect(container.textContent?.match(/defined in:/g)?.length ?? 0).toBe(1)
  })

  it('links recorded path targets back to the Code IDE route', async () => {
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
          // The recorded action_radius mirrors the input's path (the server
          // derives it from the input at record time). The client reads only
          // the recorded value: the input's line number is not re-parsed, so
          // the link carries no line.
          input: { file_path: 'lib/runtime.ml', line: 12 },
          output: 'file contents',
          success: true,
          duration_ms: 42,
          action_radius: {
            action_key: 'keeper_fs_read',
            target_kind: 'path',
            target_path: 'lib/runtime.ml',
            observed_paths: ['lib/runtime.ml'],
            error: null,
          },
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
    expect(codeLink?.getAttribute('title')).toBe('Code lib/runtime.ml')

    await act(async () => {
      codeLink?.click()
      await Promise.resolve()
    })
    expect(window.location.hash).toBe('#code?section=ide-shell&view=source&file=lib%2Fruntime.ml&surface=Tool&label=keeper_fs_read&source_id=tool%3Aanalyst%3A1777100000%3Akeeper_fs_read&keeper=analyst')
  })

  it('routes recorded identity fields to operational IDE surfaces', async () => {
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
          input: { patch: '...' },
          output: 'patched',
          success: true,
          duration_ms: 42,
          task_id: 'task-runtime',
          goal_ids: ['goal-runtime'],
          session_id: 'sess-nested',
          action_radius: {
            action_key: 'keeper_apply_patch',
            target_kind: 'path',
            target_path: 'lib/runtime.ml',
            observed_paths: ['lib/runtime.ml'],
            error: null,
          },
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
      'Goal',
      'Task',
      'Telemetry',
      'Keeper',
    ])

    await act(async () => {
      routeLinks.find(link => link.textContent?.trim() === 'Code')?.click()
      await Promise.resolve()
    })
    expect(window.location.hash).toBe('#code?section=ide-shell&view=source&file=lib%2Fruntime.ml&surface=Tool&label=keeper_apply_patch&source_id=tool%3Aanalyst%3A1777100000%3Akeeper_apply_patch&keeper=analyst')

    await act(async () => {
      routeLinks.find(link => link.textContent?.trim() === 'Telemetry')?.click()
      await Promise.resolve()
    })
    expect(window.location.hash).toBe('#monitoring?section=fleet-health&view=event-log&session_id=sess-nested')
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
          action_radius: {
            action_key: 'keeper_fs_read',
            target_kind: 'path',
            target_path: 'lib/runtime.ml',
            observed_paths: ['lib/runtime.ml'],
            error: null,
          },
        },
        {
          ts: 1_777_100_010,
          keeper: 'analyst',
          tool: 'Execute',
          input: { cmd: 'false' },
          output: 'exit 1',
          success: false,
          duration_ms: 2_600,
          task_id: 'task-runtime',
          trace_id: 'trace-runtime',
          tool_use_id: '',
          turn: 9,
          planned_index: 4,
          batch_index: 0,
          batch_size: 2,
          execution_mode: 'concurrent',
          disposition: 'failed',
          composition_tool: 'keeper_research_pipeline',
          composition_run_id: 'run-42',
          composition_node_id: 'publish_report',
          composition_execution: 'inline',
          parent_tool_use_id: 'outer-7',
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
    expect(text).toContain(
      'turn 9 · plan 4 · batch 0 · size 2 · mode concurrent · result failed',
    )
    expect(text).toContain('composition keeper_research_pipeline')
    expect(text).toContain('node publish_report')
    expect(text).toContain('execution inline')
    expect(text).toContain('parent_tool_use_id outer-7')
    const compositionRow = container.querySelector('[data-composition-node="publish_report"]')
    expect(compositionRow).not.toBeNull()
    expect(compositionRow?.getAttribute('data-composition-run')).toBe('run-42')
    expect(compositionRow?.getAttribute('data-composition-execution')).toBe('inline')
    expect(compositionRow?.getAttribute('data-tool-call-disposition')).toBe('failed')
    expect(compositionRow?.textContent).toContain('↳ publish_report · inline')
  })

  it('renders a typed deferred composition action without counting it as failed', async () => {
    const fetchKeeperToolCalls = vi.fn().mockResolvedValue({
      keeper: 'analyst',
      count: 1,
      source: 'tool_call_io',
      health: 'fresh',
      entry_count: 1,
      entries: [
        {
          ts: 1_777_100_020,
          keeper: 'analyst',
          tool: 'keeper_board_await',
          input: {},
          output: 'waiting',
          success: false,
          duration_ms: 15,
          disposition: 'deferred',
          composition_tool: 'keeper_watch_pipeline',
          composition_run_id: 'run-43',
          composition_node_id: 'wait_for_board',
          composition_execution: 'async',
          parent_tool_use_id: 'outer-8',
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
    expect(dossier?.textContent).toContain('1 deferred / 1')
    expect(dossier?.textContent).toContain('no failed calls in this window')
    expect(container.querySelector('[title="deferred"]')?.textContent).toBe('D')
    expect(container.querySelector('[data-composition-node="wait_for_board"]')).not.toBeNull()
  })

  it('does not promote Execute cwd targets to Code links', async () => {
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
          input: { argv: ['git', 'status'], cwd: 'repos/masc' },
          output: 'clean',
          success: true,
          duration_ms: 42,
          // Recorded shape for Execute rows: the writer stores the cwd as
          // target_path and says so with target_kind "directory" (masc#29013).
          // It used to say "path", which a file target also says.
          action_radius: {
            action_key: 'Execute',
            target_kind: 'directory',
            target_path: 'repos/masc',
            observed_paths: ['repos/masc'],
            error: null,
          },
          route_evidence: {
            descriptor_id: 'agent.execute',
          },
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

  it('does not render Code links for unsafe absolute recorded target paths', async () => {
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
          action_radius: {
            action_key: 'keeper_fs_read',
            target_kind: 'path',
            target_path: '/tmp/runtime.ml',
            observed_paths: ['/tmp/runtime.ml'],
            error: null,
          },
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

  it('renders recorded execution evidence blocks in the expanded row', async () => {
    const fetchKeeperToolCalls = vi.fn().mockResolvedValue({
      keeper: 'analyst',
      count: 1,
      source: 'tool_call_io',
      health: 'ok',
      entries: [
        {
          ts: 1_777_100_000,
          keeper: 'analyst',
          tool: 'keeper_time_now',
          input: {},
          output: '{"now_iso":"2026-08-18T05:00:00Z"}',
          success: true,
          duration_ms: 1,
          thinking_enabled: true,
          prompt_fingerprint: '464ce7b3280c24fe1cbdcd990a70db87',
          runtime_contract: {
            agent_name: 'keeper-analyst-agent',
            generation: 1,
            sandbox_root: '/sandbox/analyst/',
            sandbox_roots: ['.masc/playground/analyst/'],
            network_mode: 'inherit',
            runtime_profile: 'ollama_cloud.example-model',
            path_resolution: { read_implicit_cwd: false, read_explicit_cwd_supported: true },
          },
          action_radius: {
            action_key: 'keeper_time_now',
            target_kind: 'tool',
            target_path: null,
            observed_paths: [],
            error: null,
          },
          route_evidence: {
            descriptor_id: 'keeper.time.now',
            capability_id: 'keeper_time_now',
            executor: 'in_process',
            backend: 'ocaml_runtime',
            runtime_handler: 'tool_time_now',
            readonly: true,
            receipt_labels: { lane: 'meta' },
          },
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

    const evidence = container.querySelector('[data-testid="tool-call-evidence"]')
    expect(evidence).not.toBeNull()
    const text = evidence?.textContent ?? ''
    expect(text).toContain('route evidence')
    expect(text).toContain('keeper.time.now')
    expect(text).toContain('in_process')
    expect(text).toContain('ocaml_runtime')
    expect(text).toContain('tool_time_now')
    expect(text).toContain('lane=meta')
    expect(text).toContain('runtime contract')
    expect(text).toContain('/sandbox/analyst/')
    expect(text).toContain('.masc/playground/analyst/')
    expect(text).toContain('inherit')
    expect(text).toContain('read_implicit_cwd=false read_explicit_cwd_supported=true')
    expect(text).toContain('action radius')
    expect(text).toContain('target kind')

    expect(container.textContent).toContain('invocation:')
    expect(container.textContent).toContain('thinking on')
    expect(container.textContent).toContain('prompt 464ce7b3280c')
  })

  it('nests composition children under the composite parent row', async () => {
    const fetchKeeperToolCalls = vi.fn().mockResolvedValue({
      keeper: 'analyst',
      count: 3,
      source: 'tool_call_io',
      health: 'ok',
      entries: [
        {
          ts: 1_777_100_000,
          keeper: 'analyst',
          tool: 'keeper_time_now',
          input: {},
          output: 'now',
          success: true,
          duration_ms: 1,
          composition_tool: 'keeper_compose_mission-snapshot',
          composition_run_id: 'run-1',
          composition_node_id: 'clock',
          composition_execution: 'inline',
          parent_tool_use_id: 'call_parent',
          disposition: 'completed',
        },
        {
          ts: 1_777_100_005,
          keeper: 'analyst',
          tool: 'masc_board_stats',
          input: {},
          output: 'stats',
          success: true,
          duration_ms: 2,
          composition_tool: 'keeper_compose_mission-snapshot',
          composition_run_id: 'run-1',
          composition_node_id: 'board',
          composition_execution: 'inline',
          parent_tool_use_id: 'call_parent',
          disposition: 'completed',
        },
        {
          ts: 1_777_100_010,
          keeper: 'analyst',
          tool: 'keeper_compose_mission-snapshot',
          input: {},
          output: 'snapshot',
          success: true,
          duration_ms: 12,
          tool_use_id: 'call_parent',
        },
      ],
    })

    const { KeeperToolCallInspector } = await loadInspector(fetchKeeperToolCalls)
    await act(async () => {
      render(html`<${KeeperToolCallInspector} keeperName="analyst" />`, container)
      await Promise.resolve()
    })
    await flushUi()

    const childGroup = container.querySelector('[data-composition-children="call_parent"]')
    expect(childGroup).not.toBeNull()
    expect(childGroup?.querySelector('[data-composition-node="clock"]')).not.toBeNull()
    expect(childGroup?.querySelector('[data-composition-node="board"]')).not.toBeNull()
    // The children render only inside the parent's group, not as top-level rows.
    expect(container.querySelectorAll('[data-composition-node="clock"]')).toHaveLength(1)
    const parentRow = childGroup?.parentElement
    expect(parentRow?.textContent).toContain('keeper_compose_mission-snapshot')
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
