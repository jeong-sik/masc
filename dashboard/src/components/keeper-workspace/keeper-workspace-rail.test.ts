import { cleanup, fireEvent, render, waitFor } from '@testing-library/preact'
import { html } from 'htm/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { shellAuthSummary, tasks } from '../../store'
import { navigate } from '../../router'
import { callMcpTool } from '../../api/mcp'
import { fetchKeeperCompactionSnapshots, fetchRuntimeProviders } from '../../api/dashboard'
import { requestConfirm } from '../common/confirm-dialog'
import { KeeperWorkspaceRail } from './keeper-workspace-rail'
import type { Keeper, Task } from '../../types'
import { resetRuntimeCatalog } from '../../lib/runtime-catalog-resource'
import {
  compactionSnapshots,
  hydrateCompactionSnapshots,
  recordManualCompaction,
} from './compaction-snapshots'

// The recent-tool-calls section now lazy-loads via fetchKeeperToolCalls (rather
// than rendering keeper.recent_tool_names). Stub it so these rail tests never hit
// the network; its rendering is covered directly in keeper-workspace-tool-calls.test.ts.
vi.mock('../../api/dashboard', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../api/dashboard')>()
  return {
    ...actual,
    fetchKeeperToolCalls: vi.fn().mockResolvedValue({
      keeper: 'masc-improver',
      count: 0,
      source: 'tool_call_io',
      entries: [],
    }),
    fetchRuntimeProviders: vi.fn().mockResolvedValue({ providers: [] }),
    fetchKeeperCompactionSnapshots: vi.fn().mockResolvedValue({
      schema: 'keeper.compaction_snapshots.v1',
      keeper: 'masc-improver',
      source: 'runtime_manifest|keeper_meta',
      producer: 'keeper_runtime_manifest|keeper_meta_store',
      limit: 25,
      count: 1,
      read_error_count: 0,
      read_errors: [],
      scan_truncated: false,
      items: [
        {
          id: 'manifest:trace-cmp:event_bus_correlated:2026-06-26T03:03:00Z',
          keeper: 'masc-improver',
          ts_iso: '2026-06-26T03:03:00Z',
          ts_unix: 1_782_444_580,
          trace_id: 'trace-cmp',
          keeper_turn_id: 12,
          source: 'runtime_manifest',
          trigger: 'proactive(85%)',
          runtime_id: 'oas-seoul-1',
          display_runtime: 'oas-seoul-1',
          before_tokens: 210000,
          after_tokens: 120000,
          saved_tokens: 90000,
          compaction_id: 'cmp-42',
          compaction_source: 'event_bus',
          status: 'observed',
          links: { receipt_path: null, checkpoint_path: null, tool_call_log_path: null },
        },
      ],
    }),
  }
})

vi.mock('../../router', () => ({
  navigate: vi.fn(),
}))

vi.mock('../../api/mcp', () => ({
  callMcpTool: vi.fn().mockResolvedValue('{"before_tokens":1000,"after_tokens":800,"phase_after":"Running"}'),
}))

vi.mock('../common/confirm-dialog', () => ({
  requestConfirm: vi.fn().mockResolvedValue(true),
}))

function mkKeeper(partial: Partial<Keeper>): Keeper {
  return { name: 'masc-improver', status: 'running', ...partial } as Keeper
}
function mkTask(partial: Partial<Task>): Task {
  return { id: 'T-0', title: 'task', ...partial } as Task
}

beforeEach(() => {
  tasks.value = [
    mkTask({ id: 'T-4412', title: '세그먼트 리텐션 대시보드', status: 'in_progress', assignee: 'masc-improver' }),
    mkTask({ id: 'T-9999', title: '남의 태스크', status: 'todo', assignee: 'someone-else' }),
  ]
})

afterEach(() => {
  cleanup()
  tasks.value = []
  shellAuthSummary.value = null
  compactionSnapshots.value = {}
  vi.clearAllMocks()
  vi.useRealTimers()
  resetRuntimeCatalog()
})

describe('KeeperWorkspaceRail', () => {
  const keeper = mkKeeper({
    active_model_label: 'sonnet-4.6',
    runtime_canonical: 'oas·seoul-1',
    context_ratio: 0.62,
    context_tokens: 124000,
    context_max: 200000,
    compaction_profile: 'balanced',
    compaction_ratio_gate: 0.72,
    compaction_message_gate: 120,
    recent_tool_names: ['masc_amplitude_query', 'masc_board_metrics'],
  })

  it('renders the runtime vitals (throughput section removed)', () => {
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${keeper} />`)
    // The 처리량 (throughput) section was removed from the keeper rail as
    // low-signal in the detail view; the 런타임 section keeps its vitals.
    expect(container.textContent).not.toContain('처리량')
    expect(container.textContent).toContain('런타임')
    expect(container.textContent).toContain('sonnet-4.6')
    expect(container.textContent).toContain('oas·seoul-1')
  })

  it('no longer renders the Selected-runtime top card (removed from the rail)', () => {
    const k = mkKeeper({ status: 'offline', lifecycle_phase: 'Paused' })
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${k} />`)
    // The top card duplicated the 런타임/컨텍스트 sections below it. Its inline
    // lifecycle actions (pause/resume/wakeup/boot) are not lost — they remain in
    // the roster row menu + keeper action panel.
    expect(container.querySelector('.kw-fleet-aside')).toBeNull()
    expect(container.querySelector('.kw-fleet-aside-state')).toBeNull()
    expect(container.querySelector('.kw-fleet-actions')).toBeNull()
    expect(container.querySelector('.kw-fleet-chat')).toBeNull()
    expect(container.textContent).not.toContain('대화 콘솔 열기')
  })

  it('shows the model line as missing when no model was reported', () => {
    const k = mkKeeper({ runtime_canonical: 'runpod_gemma' })
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${k} />`)
    expect(container.textContent).toContain('런타임')
    expect(container.textContent).toContain('runpod_gemma')
    // v2 always renders the model cell; when no model is reported it falls back
    // to an em-dash rather than omitting the line.
    expect(container.querySelector('.rtc-model')).not.toBeNull()
    expect(container.querySelector('.rtc-model')?.textContent).toContain('—')
  })

  it('renders multimodal and effort adjustability from the runtime catalog capabilities', async () => {
    vi.mocked(fetchRuntimeProviders).mockResolvedValueOnce({
      providers: [
        {
          provider: 'ollama_cloud.minimax-m3',
          runtime_id: 'ollama_cloud.minimax-m3',
          model_api_name: 'minimax-m3',
          max_context: 524288,
          tools_support: true,
          thinking_support: true,
          streaming: true,
          supports_multimodal_inputs: true,
          supports_image_input: false,
          supports_reasoning_budget: true,
          thinking_control_format: 'reasoning-effort',
          models: ['minimax-m3'],
        },
      ],
    } as unknown as Awaited<ReturnType<typeof fetchRuntimeProviders>>)

    const k = mkKeeper({ runtime_canonical: 'ollama_cloud.minimax-m3' })
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${k} />`)

    await waitFor(() => {
      expect(container.querySelector('[data-effort-mode="reasoning-effort"]')).not.toBeNull()
    })

    const multimodalFlag = Array.from(container.querySelectorAll('.rtc-flag')).find(node =>
      node.textContent?.includes('multimodal'),
    )
    expect(multimodalFlag).not.toBeUndefined()
    expect(multimodalFlag?.className).toContain('on')

    const effort = container.querySelector('[data-effort-mode="reasoning-effort"]')
    expect(effort?.textContent).toContain('reasoning-effort')
    expect(effort?.textContent).toContain('조정 가능')
    // the "no source" stub is replaced once the catalog reports capabilities
    expect(container.textContent).not.toContain('조정 정보 미수신')
  })

  it('renders the context-window occupancy percent', () => {
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${keeper} />`)
    const meter = container.querySelector('.meter') as HTMLElement | null

    expect(container.textContent).toContain('컨텍스트')
    // The "윈도우 사용량" label was removed as redundant under "컨텍스트".
    expect(container.textContent).not.toContain('윈도우 사용량')
    expect(container.textContent).toContain('62%')
    expect(container.textContent).toContain('124.0k')
    expect(meter).not.toBeNull()
    expect(meter?.getAttribute('role')).toBe('meter')
    expect(meter?.getAttribute('aria-label')).toBe('컨텍스트 윈도우 사용률')
    expect(meter?.getAttribute('aria-valuenow')).toBe('62')
  })

  it('lists only the keeper-owned tasks', () => {
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${keeper} />`)
    expect(container.textContent).toContain('T-4412')
    expect(container.textContent).not.toContain('T-9999')
  })

  it('renders owned task status in the top row and title on its own line', () => {
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${keeper} />`)
    // v2 renames .kw-tasktag → .tasktag and .kw-tasktag-row → .tasktag-top.
    const tag = container.querySelector('.tasktag') as HTMLElement | null
    expect(tag).not.toBeNull()
    const row = tag?.querySelector('.tasktag-top')
    expect(row).not.toBeNull()
    expect(row?.textContent).toContain('T-4412')
    expect(row?.textContent).toContain('in_progress')
    // Title lives outside the top row on its own .ttl line.
    expect(row?.textContent).not.toContain('세그먼트 리텐션 대시보드')
    expect(tag?.querySelector('.ttl')?.textContent).toContain('세그먼트 리텐션 대시보드')
  })

  it('does not render the throughput card (removed from the keeper rail)', () => {
    const k = mkKeeper({
      metrics_series: [{ wall_tokens_per_second: 10 }, { wall_tokens_per_second: 64 }] as unknown as Keeper['metrics_series'],
    })
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${k} />`)
    expect(container.querySelector('.tps-card')).toBeNull()
    expect(container.querySelector('.tps-spark')).toBeNull()
    expect(container.textContent).not.toContain('처리량')
  })

  it('opens the planning task detail when an owned task is clicked', () => {
    const { getByRole } = render(html`<${KeeperWorkspaceRail} keeper=${keeper} />`)
    fireEvent.click(getByRole('button', { name: /태스크 열기: T-4412/ }))
    expect(navigate).toHaveBeenCalledWith('workspace', { section: 'planning', task: 'T-4412' })
  })

  it('renders the attention section from live blocked-task signal', () => {
    const k = mkKeeper({ blocked_task_count: 2 })
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${k} />`)
    expect(container.textContent).toContain('주의')
    expect(container.textContent).toContain('차단된 태스크 2건')
  })

  it('omits the attention section when there is nothing to surface', () => {
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${keeper} />`)
    expect(container.textContent).not.toContain('차단된 태스크')
  })

  it('uses explicit attention reason text instead of a vague maintenance label', () => {
    const k = mkKeeper({ needs_attention: true, attention_reason: 'approval_pending', next_human_action: 'resolve_approval' })
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${k} />`)
    expect(container.textContent).toContain('approval_pending · resolve_approval')
    expect(container.textContent).not.toContain('점검이 필요합니다')
  })

  it('labels unqualified attention flags as missing cause data', () => {
    const k = mkKeeper({ needs_attention: true })
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${k} />`)
    expect(container.textContent).toContain('runtime_attention.needs_attention=true · 원인/조치 미수신')
    expect(container.textContent).not.toContain('점검이 필요합니다')
  })

  it('renders the auto-compact threshold label', () => {
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${keeper} />`)
    // With meter data the gate renders as the "compact NN%" meter mark.
    expect(container.textContent).toContain('compact 72%')
    // The meter mark also exposes the gate percentage via its label element.
    expect(container.querySelector('.meter-mark-lbl')?.textContent).toContain('compact 72%')
  })

  it('renders context metrics as missing when only a zero default exists', () => {
    const k = mkKeeper({ context_ratio: 0, compaction_count: 0, last_compaction_ago_s: 0 })
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${k} />`)
    // v2 collapses the missing-context state into a single "윈도우 사용률 미수신"
    // empty card (.ctx-empty); no fake usage meter and no usage percentage.
    expect(container.textContent).toContain('윈도우 사용률 미수신')
    expect(container.querySelector('.ctx-empty')).not.toBeNull()
    expect(container.textContent).not.toContain('윈도우 사용량')
    expect(container.querySelector('.meter')).toBeNull()
    const button = container.querySelector('.cmp-run') as HTMLButtonElement | null
    expect(button).not.toBeNull()
    expect(button?.disabled).toBe(true)
  })

  it('shows token-only context without a fake window percentage', () => {
    const k = mkKeeper({ context_ratio: 0, context_tokens: 37800 })
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${k} />`)
    expect(container.textContent).toContain('윈도우 사용률 미수신')
    expect(container.textContent).toContain('37.8k')
    expect(container.textContent).not.toContain('윈도우 사용량')
    expect(container.querySelector('.meter')).toBeNull()
  })

  it('runs overflow compaction without force through the existing MCP tool', async () => {
    shellAuthSummary.value = { effective_role: 'worker', default_role: 'worker' } as typeof shellAuthSummary.value
    // Use lifecycle_phase (the canonical wire field per Keeper type —
    // `phaseTokenFromKeeper` reads `keeperDisplayStatus(keeper)` which
    // routes through `lifecycle_phase`, not the deprecated `phase` alias).
    const { getByRole } = render(html`<${KeeperWorkspaceRail} keeper=${mkKeeper({ ...keeper, lifecycle_phase: 'Overflowed' })} />`)
    fireEvent.click(getByRole('button', { name: /지금 컴팩트/ }))

    await waitFor(() => {
      expect(callMcpTool).toHaveBeenCalledWith('masc_keeper_compact', {
        name: 'masc-improver',
        force: false,
      })
    })
    expect(requestConfirm).not.toHaveBeenCalled()
  })

  it('confirms before forcing compaction on running keepers', async () => {
    shellAuthSummary.value = { effective_role: 'worker', default_role: 'worker' } as typeof shellAuthSummary.value
    const { getByRole } = render(html`<${KeeperWorkspaceRail} keeper=${mkKeeper({ ...keeper, lifecycle_phase: 'Running' })} />`)
    fireEvent.click(getByRole('button', { name: /지금 컴팩트/ }))

    await waitFor(() => {
      expect(requestConfirm).toHaveBeenCalledWith(expect.objectContaining({
        title: 'Force keeper compact',
        confirmText: 'Force compact',
      }))
      expect(callMcpTool).toHaveBeenCalledWith('masc_keeper_compact', {
        name: 'masc-improver',
        force: true,
      })
    })
  })

  it('does not compact running keepers when force confirmation is cancelled', async () => {
    vi.mocked(requestConfirm).mockResolvedValueOnce(false)
    shellAuthSummary.value = { effective_role: 'worker', default_role: 'worker' } as typeof shellAuthSummary.value
    const { getByRole } = render(html`<${KeeperWorkspaceRail} keeper=${mkKeeper({ ...keeper, lifecycle_phase: 'Running' })} />`)
    fireEvent.click(getByRole('button', { name: /지금 컴팩트/ }))

    await waitFor(() => expect(requestConfirm).toHaveBeenCalled())
    expect(callMcpTool).not.toHaveBeenCalled()
  })

  it('opens the compaction inspector overlay from the context rail and hydrates durable snapshots', async () => {
    const { container, findByTestId } = render(html`<${KeeperWorkspaceRail} keeper=${keeper} />`)
    const btn = Array.from(container.querySelectorAll('.cmp-open')).find(
      el => el.textContent?.includes('before/after'),
    ) as HTMLElement | undefined
    expect(btn).toBeTruthy()
    fireEvent.click(btn as HTMLElement)
    expect(container.querySelector('.turn-overlay')).toBeTruthy()
    expect(container.textContent).toContain('컴팩션 스냅샷')
    await waitFor(() => expect(container.textContent).toContain('210.0k'))
    expect(container.querySelector('[data-testid="compaction-scan-diagnostics"]')).toBeNull()
    const coverage = await findByTestId('compaction-coverage-status')
    expect(coverage.textContent).toContain('표시 1/1')
    expect(coverage.textContent).toContain('source=runtime_manifest|keeper_meta')
    expect(coverage.textContent).toContain('producer=keeper_runtime_manifest|keeper_meta_store')
    expect(container.textContent).toContain('proactive(85%)')
    expect(container.textContent).toContain('runtime_manifest · observed')
    expect(container.textContent).toContain('trace-cmp#12')
  })

  it('renders live durable compaction snapshots even when token counts are missing', async () => {
    vi.mocked(fetchKeeperCompactionSnapshots).mockResolvedValueOnce({
      schema: 'keeper.compaction_snapshots.v1',
      keeper: 'masc-improver',
      source: 'runtime_manifest|keeper_meta',
      producer: 'keeper_runtime_manifest|keeper_meta_store',
      limit: 25,
      count: 1,
      read_error_count: 1,
      read_errors: [
        { scope: 'runtime_manifest_row:trace-cmp.jsonl:1', error: 'unknown event: "old_event"' },
      ],
      scan_truncated: true,
      items: [
        {
          id: 'manifest:trace-live:context_compacted:2026-06-03T11:01:24Z',
          keeper: 'masc-improver',
          ts_iso: '2026-06-03T11:01:24Z',
          ts_unix: 1_780_464_084,
          trace_id: 'trace-live',
          keeper_turn_id: null,
          source: 'runtime_manifest',
          trigger: 'pre_dispatch_hygiene',
          runtime_id: null,
          display_runtime: 'pre_dispatch_hygiene',
          before_tokens: null,
          after_tokens: null,
          saved_tokens: null,
          compaction_id: null,
          compaction_source: 'pre_dispatch_hygiene',
          status: 'compacted',
          links: { receipt_path: null, checkpoint_path: null, tool_call_log_path: null },
        },
      ],
    })

    const { container, findByTestId } = render(html`<${KeeperWorkspaceRail} keeper=${keeper} />`)
    const btn = Array.from(container.querySelectorAll('.cmp-open')).find(
      el => el.textContent?.includes('before/after'),
    ) as HTMLElement | undefined
    expect(btn).toBeTruthy()
    fireEvent.click(btn as HTMLElement)

    const diagnostics = await findByTestId('compaction-scan-diagnostics')
    expect(diagnostics.textContent).toContain('manifest row 1개')
    expect(diagnostics.textContent).toContain('scan budget')
    const coverage = await findByTestId('compaction-coverage-status')
    expect(coverage.textContent).toContain('표시 1/1')
    expect(coverage.textContent).toContain('더 오래된 snapshot은 누락')
    expect(container.textContent).toContain('pre_dispatch_hygiene')
    expect(container.textContent).toContain('runtime_manifest · compacted')
    expect(container.textContent).toContain('trace-live')
    expect(container.textContent).toContain('before/after token count가 없습니다')
    expect(container.textContent).not.toContain('아직 이 keeper에서 durable compaction snapshot이 없습니다.')
  })

  it('surfaces compaction snapshot scan diagnostics when successful payload has no items', async () => {
    vi.mocked(fetchKeeperCompactionSnapshots).mockResolvedValueOnce({
      schema: 'keeper.compaction_snapshots.v1',
      keeper: 'masc-improver',
      source: 'runtime_manifest|keeper_meta',
      producer: 'keeper_runtime_manifest|keeper_meta_store',
      limit: 25,
      count: 0,
      read_error_count: 2,
      read_errors: [
        { scope: 'runtime_manifest_row:trace-a.jsonl:1', error: 'unknown event: "memory_injected"' },
        { scope: 'runtime_manifest_row:trace-a.jsonl:2', error: 'unknown event: "memory_flushed"' },
      ],
      scan_truncated: true,
      items: [],
    })

    const { container, findByTestId } = render(html`<${KeeperWorkspaceRail} keeper=${keeper} />`)
    const btn = Array.from(container.querySelectorAll('.cmp-open')).find(
      el => el.textContent?.includes('before/after'),
    ) as HTMLElement | undefined
    expect(btn).toBeTruthy()
    fireEvent.click(btn as HTMLElement)

    const diagnostics = await findByTestId('compaction-scan-diagnostics')
    expect(diagnostics.textContent).toContain('manifest row 2개')
    expect(diagnostics.textContent).toContain('unknown event: "memory_injected"')
    expect(diagnostics.textContent).toContain('scan budget')
    const coverage = await findByTestId('compaction-coverage-status')
    expect(coverage.textContent).toContain('표시 0/0')
    expect(container.textContent).toContain('아직 이 keeper에서 durable compaction snapshot이 없습니다.')
    expect(container.textContent).toContain('api_count=0 · decoded=0')
  })

  it('distinguishes empty durable compaction results from decoded schema drift', async () => {
    vi.mocked(fetchKeeperCompactionSnapshots).mockResolvedValueOnce({
      schema: 'keeper.compaction_snapshots.v1',
      keeper: 'masc-improver',
      source: 'runtime_manifest|keeper_meta',
      producer: 'keeper_runtime_manifest|keeper_meta_store',
      limit: 25,
      count: 2,
      read_error_count: 0,
      read_errors: [],
      scan_truncated: false,
      items: [],
    })

    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${keeper} />`)
    const btn = Array.from(container.querySelectorAll('.cmp-open')).find(
      el => el.textContent?.includes('before/after'),
    ) as HTMLElement | undefined
    expect(btn).toBeTruthy()
    fireEvent.click(btn as HTMLElement)

    await waitFor(() => expect(container.textContent).toContain('API는 masc-improver snapshot 2건을 보고'))
    expect(container.querySelector('[data-testid="compaction-coverage-status"]')?.textContent).toContain('표시 0/2')
    expect(container.textContent).toContain('api_count=2 · decoded=0')
    expect(container.textContent).toContain('source=runtime_manifest|keeper_meta')
  })

  it('keeps newly recorded optimistic compactions above older durable snapshots', () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date('2026-06-27T10:00:00Z'))

    recordManualCompaction('masc-improver', 1000, 800, 'runtime-a')
    hydrateCompactionSnapshots('masc-improver', [
      {
        id: 'manifest:old:event_bus_correlated:2026-06-26T03:03:00Z',
        keeper: 'masc-improver',
        ts_iso: '2026-06-26T03:03:00Z',
        ts_unix: 1_782_444_580,
        trace_id: 'old',
        keeper_turn_id: 1,
        source: 'runtime_manifest',
        trigger: 'proactive(85%)',
        runtime_id: 'runtime-old',
        display_runtime: 'runtime-old',
        before_tokens: 210000,
        after_tokens: 120000,
        saved_tokens: 90000,
        compaction_id: 'cmp-old',
        compaction_source: 'event_bus',
        status: 'observed',
        links: { receipt_path: null, checkpoint_path: null, tool_call_log_path: null },
      },
    ])

    const snapshots = compactionSnapshots.value['masc-improver'] ?? []
    expect(snapshots[0]?.source).toBe('manual')
    expect(snapshots[0]?.atIso).toBe('2026-06-27T10:00:00.000Z')
    expect(snapshots[1]?.source).toBe('backend')
  })

  it('opens the memory inspector overlay from the context rail', () => {
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${keeper} />`)
    const btn = Array.from(container.querySelectorAll('.cmp-open')).find(
      el => el.textContent?.includes('메모리 보기'),
    ) as HTMLElement | undefined
    expect(btn).toBeTruthy()
    fireEvent.click(btn as HTMLElement)
    expect(container.querySelector('.turn-overlay')).toBeTruthy()
    expect(container.textContent).toContain('Keeper 메모리')
  })

  it('shows the empty state when no tasks are owned', () => {
    tasks.value = []
    const { container } = render(html`<${KeeperWorkspaceRail} keeper=${keeper} />`)
    expect(container.textContent).toContain('할당된 태스크 없음')
  })
})
