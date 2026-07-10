import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { html } from 'htm/preact'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { AgentRoster, countRuntimeKinds, rosterBlockerDisplay, rosterStateNote } from './agent-roster'
import type { Agent, Keeper } from '../types'
import type { KeeperCompositeSnapshot } from '../api/schemas/keeper-composite'
import {
  agents,
  keepers,
  executionLoaded,
  executionLoading,
  executionError,
  shellCounts,
  serverStatus,
} from '../store'
import { missionSnapshot } from '../mission-signals'
import { namespaceTruth } from '../namespace-truth-store'
import { fleetCompositeSnapshot } from '../composite-signals'

function makeAgent(overrides: Partial<Agent> = {}): Agent {
  return {
    name: 'agent-x',
    status: 'active',
    current_task: null,
    ...overrides,
  }
}

function makeCompositeSnapshot(
  overrides: Partial<KeeperCompositeSnapshot> = {},
): KeeperCompositeSnapshot {
  return {
    keeper: 'sangsu',
    correlation_id: 'keeper:sangsu:1',
    run_id: 'r-1',
    ts: 0,
    phase: 'running',
    turn_phase: 'idle',
    decision: { stage: 'undecided' },
    runtime: { state: 'idle' },
    compaction: { stage: 'accumulating' },
    measurement: { captured: false },
    invariants: {
      phase_turn_alignment: true,
      no_runtime_before_measurement: true,
      compaction_atomicity: true,
      event_priority_monotone: true,
      phase_derivation_agreement: true,
    },
    fsm_guard_violations: 0,
    fsm_guard_violation_breakdown: [],
    is_live: false,
    live_turn: null,
    last_outcome: null,
    recommended_actions: [],
    ...overrides,
  } as KeeperCompositeSnapshot
}

async function flushUi(): Promise<void> {
  await act(async () => {
    await Promise.resolve()
  })
}

describe('rosterStateNote — RFC-0135 §1.1 typed-state conditioning', () => {
  function k(overrides: Partial<Keeper> = {}): Keeper {
    return {
      name: 'lifecycle-worker',
      status: 'active',
      ...overrides,
    } as Keeper
  }

  function compositeWith(
    runtimeAttention: NonNullable<KeeperCompositeSnapshot['runtime_attention']>,
    extras: Partial<KeeperCompositeSnapshot> = {},
  ): KeeperCompositeSnapshot {
    return {
      correlation_id: 'c',
      run_id: 'r',
      ts: 0,
      phase: 'Stable',
      turn_phase: 'idle',
      decision: { stage: 'idle' },
      runtime: { state: 'idle' },
      compaction: { stage: 'idle' },
      measurement: {} as KeeperCompositeSnapshot['measurement'],
      invariants: {} as KeeperCompositeSnapshot['invariants'],
      fsm_guard_violations: 0,
      fsm_guard_violation_breakdown: [],
      is_live: false,
      last_outcome: null,
      recommended_actions: [],
      runtime_attention: runtimeAttention,
      ...extras,
    } as KeeperCompositeSnapshot
  }

  function attention(
    partial: Partial<NonNullable<KeeperCompositeSnapshot['runtime_attention']>> = {},
  ): NonNullable<KeeperCompositeSnapshot['runtime_attention']> {
    return {
      state: 'active',
      needs_attention: false,
      blocked: false,
      reason: null,
      raw_phase: null,
      is_live: true,
      source: 'test',
      ...partial,
    }
  }

  it('returns "상태 추정" for synthetic_stall when no composite is available', () => {
    const note = rosterStateNote(
      k({ runtime_blocker_class: 'synthetic_stall', runtime_blocker_summary: '합성 상태 정체' }),
      null,
      null,
    )
    expect(note).toEqual({
      label: '상태 추정',
      text: '합성 상태 정체',
      kind: 'synthetic_stall',
    })
  })

  it('shows a pending approval gate before stale runtime blocker summaries', () => {
    const note = rosterStateNote(
      k({
        runtime_blocker_class: 'turn_timeout',
        runtime_blocker_summary: '턴 응답 만료',
        current_gate: {
          kind: 'approval_required',
          source: 'audit_approvals',
          tool: 'Write',
          risk: 'high',
          disposition_reason: 'waiting_approval',
        },
      }),
      null,
      null,
    )
    expect(note).toEqual({
      label: '승인 대기',
      text: '도구 Write · 위험도 high · 사유 waiting_approval',
    })
  })

  it('RFC §1.1 EXACT — blocker set BUT receipt is stale (execution_current=false) → 이전 차단', () => {
    // The exact 2026-05-19 lifecycle-worker scenario. Backend emits
    // execution_current=false (`server_dashboard_http.ml:1061-1074`)
    // when the latest receipt is from a prior turn while a newer live
    // turn is in progress (`receipt_at < live_started_at`). The blocker
    // class belongs to the prior turn — demoted to "이전 차단" so the
    // headline matches what the detail panel shows ("턴 진행 중 ·
    // executing live").
    //
    // PR-4 originally encoded this scenario with `execution_current=true`,
    // which inverted the semantics; PR-5 fixes the typed SSOT axis and
    // realigns this fixture with backend reality.
    const note = rosterStateNote(
      k({
        phase: 'Running',
        runtime_blocker_class: 'synthetic_stall',
        runtime_blocker_summary: '잔여 marker',
      }),
      compositeWith(
        attention({
          execution_current: false,
          stale_execution_receipt: true,
          blocked: false,
        }),
        { turn_phase: 'executing', is_live: true },
      ),
      null,
    )
    expect(note).toEqual({
      label: '이전 차단',
      text: '이전 턴 차단 (synthetic_stall) — 현재는 실행 중',
      kind: 'synthetic_stall',
    })
  })

  it('genuine stuck — blocker set AND receipt is current (execution_current=true) → 현재 차단', () => {
    const note = rosterStateNote(
      k({
        phase: 'Running',
        runtime_blocker_class: 'runtime_exhausted',
        runtime_blocker_summary: 'runtime list 소진',
      }),
      compositeWith(attention({ execution_current: true, blocked: true })),
      null,
    )
    expect(note).toEqual({
      label: '현재 차단',
      text: 'runtime list 소진',
      kind: 'runtime_exhausted',
    })
  })

  it('class without summary surfaces typed reason in fallback message', () => {
    const note = rosterStateNote(
      k({ runtime_blocker_class: 'heartbeat_failures' }),
      null,
      null,
    )
    expect(note).toEqual({
      label: '현재 차단',
      text: '차단 종류: heartbeat_failures (요약 메시지 없음)',
      kind: 'heartbeat_failures',
    })
  })

  it('running keeper with diagnostic error shows "이전 오류" (not current)', () => {
    const note = rosterStateNote(
      k({
        phase: 'Running',
        diagnostic: {
          last_error: 'tool call failed',
          health_state: 'degraded',
          next_action_path: 'recover',
          last_reply_status: 'error',
        },
      }),
      compositeWith(attention({ execution_current: true })),
      null,
    )
    expect(note).toEqual({ label: '이전 오류', text: 'tool call failed' })
  })

  it('offline keeper with diagnostic error shows "최근 오류"', () => {
    const note = rosterStateNote(
      k({
        phase: 'Crashed',
        status: 'offline',
        diagnostic: {
          last_error: 'fiber died',
          health_state: 'degraded',
          next_action_path: 'recover',
          last_reply_status: 'error',
        },
      }),
      null,
      null,
    )
    expect(note).toEqual({ label: '최근 오류', text: 'fiber died' })
  })

  it('falls through to monitoring hint when nothing else applies', () => {
    const note = rosterStateNote(
      k({ phase: 'Running' }),
      null,
      '관찰 메모',
    )
    expect(note).toEqual({ label: '참고', text: '관찰 메모' })
  })

  it('paused keeper surfaces its blocker reason in the state note', () => {
    const note = rosterStateNote(
      k({ paused: true, runtime_blocker_class: 'supervisor_paused' }),
      null,
      null,
    )
    expect(note).toEqual({
      label: '일시정지 원인',
      text: 'Supervisor가 keeper를 일시정지한 상태라 재개 조건을 확인해야 합니다.',
      kind: 'supervisor_paused',
    })
  })

  it('offline keeper produces no state note', () => {
    const note = rosterStateNote(
      k({ phase: 'Crashed', status: 'offline' }),
      null,
      null,
    )
    expect(note).toBeNull()
  })

  it('offline keeper with assigned task shows interrupted work label', () => {
    const note = rosterStateNote(
      k({ phase: 'Crashed', status: 'offline', agent: { current_task: 'task-001', exists: true } }),
      null,
      null,
    )
    expect(note).toEqual({ label: '작업 중단', text: '할당된 작업이 있으나 keeper가 crashed 상태입니다' })
  })

  it('null keeper returns null', () => {
    expect(rosterStateNote(null, null, null)).toBeNull()
  })
})

describe('rosterBlockerDisplay', () => {
  it('turns raw blocker code into an operator label and hint', () => {
    const note = {
      label: '현재 차단',
      text: 'fiber_unresolved',
      kind: 'fiber_unresolved',
    }
    const display = rosterBlockerDisplay(note, {
      name: 'executor',
      status: 'active',
      runtime_blocker_class: 'fiber_unresolved',
      runtime_blocker_summary: 'fiber_unresolved',
    } as Keeper)

    expect(display.cell).toBe('현재 차단: Fiber 미해결')
    expect(display.detail).toBe('Keeper fiber가 종료 상태를 확정하지 못해 supervisor 확인이 필요합니다.')
    expect(display.title).toContain('fiber_unresolved')
  })

  it('keeps real summary text instead of replacing it with the generic hint', () => {
    const display = rosterBlockerDisplay(
      {
        label: '현재 차단',
        text: 'runtime list 소진',
        kind: 'runtime_exhausted',
      },
      {
        name: 'echo',
        status: 'active',
        runtime_blocker_class: 'runtime_exhausted',
      } as Keeper,
    )

    expect(display.cell).toBe('현재 차단: 런타임 후보 소진')
    expect(display.detail).toBe('runtime list 소진')
  })
})

describe('countRuntimeKinds', () => {
  it('keeps configured paused keepers as detail rows without counting them as running', () => {
    const result = countRuntimeKinds(
      [],
      [
        {
          name: 'taskmaster',
          status: 'active',
          registered: true,
          keepalive_running: true,
        } as Keeper,
        {
          name: 'verifier',
          status: 'paused',
          paused: true,
          registered: false,
          keepalive_running: false,
        } as Keeper,
      ],
    )

    expect(result).toEqual({
      agents: 0,
      keepers: 1,
      pausedKeepers: 1,
      transientKeepers: 0,
      offlineKeepers: 0,
      keeperRows: 2,
      totalRuntimes: 2,
    })
  })

  it('keeps paused keeper runtime truth when live agent presence still exists', () => {
    const result = countRuntimeKinds(
      [
        makeAgent({
          name: 'keeper-sangsu-agent',
          status: 'busy',
        }),
      ],
      [
        {
          name: 'sangsu',
          agent_name: 'keeper-sangsu-agent',
          status: 'offline',
          phase: 'Paused',
          pipeline_stage: 'paused',
          paused: false,
          registered: false,
          keepalive_running: false,
        } as Keeper,
      ],
    )

    expect(result).toEqual({
      agents: 0,
      keepers: 0,
      pausedKeepers: 1,
      transientKeepers: 0,
      offlineKeepers: 0,
      keeperRows: 1,
      totalRuntimes: 1,
    })
  })

  it('collapses keeper-owned generated sub-op aliases when agent meta carries keeper identity', () => {
    const result = countRuntimeKinds(
      [
        makeAgent({
          name: 'ramarama-fierce-panda',
          agent_type: 'ramarama',
          keeper_name: 'ramarama',
          keeper_id: 'keeper-uuid-1',
        }),
      ],
      [
        {
          name: 'ramarama',
          keeper_id: 'keeper-uuid-1',
          agent_name: 'keeper-ramarama-agent',
          status: 'active',
        } as Keeper,
      ],
    )

    expect(result).toEqual({
      agents: 0,
      keepers: 1,
      pausedKeepers: 0,
      transientKeepers: 0,
      offlineKeepers: 0,
      keeperRows: 1,
      totalRuntimes: 1,
    })
  })

  it('classifies generated keeper nicknames as the canonical keeper when names match', () => {
    const result = countRuntimeKinds(
      [
        makeAgent({
          name: 'keeper-taskmaster-agent',
          agent_type: 'agent',
        }),
        makeAgent({
          name: 'taskmaster-proud-bear',
          agent_type: 'taskmaster',
        }),
      ],
      [
        {
          name: 'taskmaster',
          agent_name: 'keeper-taskmaster-agent',
          status: 'active',
        } as Keeper,
      ],
    )

    expect(result).toEqual({
      agents: 0,
      keepers: 1,
      pausedKeepers: 0,
      transientKeepers: 0,
      offlineKeepers: 0,
      keeperRows: 1,
      totalRuntimes: 1,
    })
  })

  it('does not classify arbitrary hyphenated agents as matching keeper prefixes', () => {
    const result = countRuntimeKinds(
      [
        makeAgent({
          name: 'foo-bar',
          agent_type: 'agent',
        }),
      ],
      [
        {
          name: 'foo',
          agent_name: 'keeper-foo-agent',
          status: 'active',
        } as Keeper,
      ],
    )

    expect(result).toEqual({
      agents: 1,
      keepers: 1,
      pausedKeepers: 0,
      transientKeepers: 0,
      offlineKeepers: 0,
      keeperRows: 1,
      totalRuntimes: 2,
    })
  })

  it('does not count offline non-paused keeper rows as running fibers', () => {
    const runningKeepers = Array.from({ length: 2 }, (_, index) => ({
      name: `running-${index}`,
      status: 'active',
      registered: true,
      keepalive_running: true,
    } as Keeper))
    const pausedKeepers = Array.from({ length: 6 }, (_, index) => ({
      name: `paused-${index}`,
      status: 'paused',
      paused: true,
      registered: true,
      keepalive_running: false,
    } as Keeper))
    const offlineKeepers = Array.from({ length: 9 }, (_, index) => ({
      name: `offline-${index}`,
      status: 'offline',
      registered: true,
      keepalive_running: false,
    } as Keeper))

    const result = countRuntimeKinds([], [
      ...runningKeepers,
      ...pausedKeepers,
      ...offlineKeepers,
    ])

    expect(result).toEqual({
      agents: 0,
      keepers: 2,
      pausedKeepers: 6,
      transientKeepers: 0,
      offlineKeepers: 9,
      keeperRows: 17,
      totalRuntimes: 17,
    })
  })

  it('does not absorb transient keeper rows into offline counts', () => {
    const result = countRuntimeKinds(
      [],
      [
        {
          name: 'runner',
          status: 'active',
          phase: 'Running',
          pipeline_stage: 'idle',
          keepalive_running: true,
        } as Keeper,
        {
          name: 'compact',
          status: 'busy',
          phase: 'Compacting',
          pipeline_stage: 'compacting',
          keepalive_running: true,
        } as Keeper,
        {
          name: 'handoff',
          status: 'busy',
          phase: 'HandingOff',
          pipeline_stage: 'handoff',
          keepalive_running: true,
        } as Keeper,
        {
          name: 'paused',
          status: 'paused',
          phase: 'Paused',
          pipeline_stage: 'paused',
          paused: true,
          keepalive_running: false,
        } as Keeper,
        {
          name: 'offline',
          status: 'offline',
          phase: 'Offline',
          pipeline_stage: 'offline',
          keepalive_running: false,
        } as Keeper,
      ],
    )

    expect(result).toEqual({
      agents: 0,
      keepers: 1,
      pausedKeepers: 1,
      transientKeepers: 2,
      offlineKeepers: 1,
      keeperRows: 5,
      totalRuntimes: 5,
    })
  })

  it('counts Draining-phase keepers under pausedKeepers (band SSOT, not isKeeperPaused)', () => {
    // RFC-0295 §5.3 (iter-6): The Draining phase routes to the `paused` band
    // in `keeperBand()` and the rail paint, filter chip, and count chip must
    // all derive from the same `band` SSOT. `isKeeperPaused()` is the
    // action-layer predicate (operator-pause vs. operator-stop) and does
    // NOT include Draining — so a Draining keeper is `isKeeperPaused =
    // false` but `band === 'paused'`. The count must follow the band.
    const result = countRuntimeKinds(
      [],
      [
        {
          name: 'runner',
          status: 'active',
          phase: 'Running',
          pipeline_stage: 'idle',
          keepalive_running: true,
        } as Keeper,
        {
          name: 'drain',
          // Crucially NO `paused: true` flag, NO `phase: 'Paused'`, NO
          // `pipeline_stage: 'paused'` — Draining is operator-initiated
          // stop, not pause.
          status: 'busy',
          phase: 'Draining',
          pipeline_stage: 'draining',
          keepalive_running: true,
        } as Keeper,
        {
          name: 'rester',
          status: 'paused',
          phase: 'Paused',
          pipeline_stage: 'paused',
          paused: true,
          keepalive_running: false,
        } as Keeper,
      ],
    )

    // Drain band = paused → counted under pausedKeepers.
    // Rester band = paused → counted under pausedKeepers.
    // Runner band = active → counted under keepers (runningKeepers).
    // No transient (Draining is not in TRANSIENT_KEEPER_PHASES after iter-5).
    // No offline.
    expect(result).toEqual({
      agents: 0,
      keepers: 1,
      pausedKeepers: 2,
      transientKeepers: 0,
      offlineKeepers: 0,
      keeperRows: 3,
      totalRuntimes: 3,
    })
  })

  it('uses composite snapshots when counting transient keeper rows', () => {
    const composite = makeCompositeSnapshot({
      keeper: 'compact',
      correlation_id: 'keeper:compact:1',
      phase: 'compacting',
    })
    const result = countRuntimeKinds(
      [],
      [
        {
          name: 'compact',
          status: 'active',
          phase: 'Running',
          pipeline_stage: 'idle',
          keepalive_running: true,
        } as Keeper,
      ],
      new Map([['compact', composite]]),
    )

    expect(result).toEqual({
      agents: 0,
      keepers: 0,
      pausedKeepers: 0,
      transientKeepers: 1,
      offlineKeepers: 0,
      keeperRows: 1,
      totalRuntimes: 1,
    })
  })
})

describe('AgentRoster live-only cards', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    agents.value = []
    keepers.value = []
    executionLoaded.value = true
    executionLoading.value = false
    executionError.value = null
    shellCounts.value = null
    serverStatus.value = null
    namespaceTruth.value = null
    missionSnapshot.value = null
    fleetCompositeSnapshot.value = null
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.useRealTimers()
    agents.value = []
    keepers.value = []
    executionLoaded.value = false
    executionLoading.value = false
    executionError.value = null
    shellCounts.value = null
    serverStatus.value = null
    namespaceTruth.value = null
    missionSnapshot.value = null
    fleetCompositeSnapshot.value = null
  })

  it('renders keeper cards from live runtime data and ignores stale mission brief fields', async () => {
    agents.value = [
      makeAgent({
        name: 'codex-mcp-client',
        current_task: 'agent fallback task',
        model: 'gpt-5.4',
      }),
    ]
    keepers.value = [
      {
        name: 'nick0cave',
        agent_name: 'codex-mcp-client',
        status: 'idle',
        last_heartbeat: '2026-04-23T09:59:00Z',
        last_autonomous_action_at: '2026-04-23T09:58:00Z',
        last_activity_ago_s: 75,
        recent_output_preview: 'live runtime output preview',
        recent_input_preview: 'live runtime input preview',
        recent_tool_names: ['keeper_task_claim'],
        latest_tool_call_count: 1,
        tool_audit_at: '2026-04-23T09:58:30Z',
        last_blocker: 'old blocker that should stay out of the roster',
      } as Keeper,
    ]
    missionSnapshot.value = {
      generated_at: '2026-04-23T09:00:00Z',
      summary: {},
      incidents: [],
      recommended_actions: [],
      command_focus: {},
      operator_targets: {},
      attention_queue: [],
      sessions: [],
      agent_briefs: [
        {
          agent_name: 'codex-mcp-client',
          current_work: 'stale mission work',
          recent_output_preview: 'stale mission preview',
          last_activity_at: '2026-04-23T06:00:00Z',
        },
      ],
      keeper_briefs: [
        {
          name: 'nick0cave',
          agent_name: 'codex-mcp-client',
          current_work: 'stale keeper brief work',
          latest_tool_names: ['stale_tool'],
          last_autonomous_action_at: '2026-04-23T06:00:00Z',
        },
      ],
      internal_signals: [],
    } as any

    await act(async () => {
      render(html`<${AgentRoster} />`, container)
    })
    await flushUi()

    expect(container.textContent).toContain('live runtime output preview')
    expect(container.textContent).toContain('keeper_task_claim')
    expect(container.textContent).toContain('Cognition')
    expect(container.textContent).toContain('Tool Access')
    expect(container.textContent).toContain('Runtime Trace')
    expect(container.textContent).not.toContain('stale mission preview')
    expect(container.textContent).not.toContain('stale keeper brief work')
    expect(container.textContent).not.toContain('stale_tool')
    expect(container.textContent).not.toContain('old blocker that should stay out of the roster')
  })

  it('labels workspace agents, keeper fibers, configured keepers, and task owners as separate surfaces', async () => {
    agents.value = [
      makeAgent({
        name: 'dashboard',
        status: 'active',
      }),
    ]
    keepers.value = [
      {
        name: 'sangsu',
        agent_name: 'keeper-sangsu-agent',
        status: 'active',
        phase: 'Running',
        pipeline_stage: 'idle',
        keepalive_running: true,
      } as Keeper,
    ]

    await act(async () => {
      render(html`<${AgentRoster} />`, container)
    })
    await flushUi()

    const text = container.textContent ?? ''
    expect(text).toContain('workspace agents ≠ keeper fibers')
    expect(text).toContain('configured keeper ≠ running fiber')
    expect(text).toContain('task owner ≠ live agent')
    expect(text).toContain('runtime rows')
  })

  it('treats keeper-only rows as first-class runtime rows when agent registry is empty', async () => {
    agents.value = []
    keepers.value = [
      {
        name: 'albini',
        agent_name: 'keeper-albini-agent',
        status: 'idle',
        phase: 'Running',
        pipeline_stage: 'idle',
        recent_tool_names: ['keeper_tools_list'],
      } as Keeper,
    ]

    await act(async () => {
      render(html`<${AgentRoster} keeperFilter="keeper-only" />`, container)
    })
    await flushUi()

    const text = container.textContent ?? ''
    expect(text).toContain('albini')
    expect(text).toContain('keeper_tools_list')
    expect(text).not.toContain('Source mismatch')
    expect(text).not.toContain('agent registry 0')
    expect(text).not.toContain('파생')
  })

  it('renders paused configured keepers even without live agent presence', async () => {
    agents.value = []
    keepers.value = [
      {
        name: 'albini',
        agent_name: 'keeper-albini-agent',
        status: 'paused',
        phase: 'Paused',
        pipeline_stage: 'paused',
        paused: true,
        registered: false,
        keepalive_running: false,
      } as Keeper,
      {
        name: 'rondo',
        agent_name: 'keeper-rondo-agent',
        status: 'idle',
        phase: 'Running',
        pipeline_stage: 'idle',
        keepalive_running: true,
      } as Keeper,
      {
        name: 'qa-king',
        agent_name: 'keeper-qa-king-agent',
        status: 'offline',
        phase: 'Offline',
        pipeline_stage: 'offline',
        keepalive_running: false,
      } as Keeper,
    ]

    await act(async () => {
      render(html`<${AgentRoster} keeperFilter="keeper-only" />`, container)
    })
    await flushUi()

    const rows = container.querySelectorAll('[data-testid="keeper-operations-row"]')
    const text = container.textContent ?? ''
    expect(rows.length).toBe(3)
    expect(text).toContain('albini')
    expect(text).toContain('rondo')
    expect(text).toContain('qa-king')
    expect(text).toContain('일시정지')
    expect(text).toContain('재개 대기')
    expect(text).toContain('오프라인')
    expect(text).toContain('기동 필요')
    expect(text).not.toContain('상세 상태 부분 동기화')
  })

  it('paints a per-row tone rail keyed to runtime band (keeper-v2 Fleet)', async () => {
    keepers.value = [
      {
        name: 'runner', agent_name: 'keeper-runner-agent', status: 'idle',
        phase: 'Running', pipeline_stage: 'idle', keepalive_running: true,
      } as Keeper,
      {
        name: 'rester', agent_name: 'keeper-rester-agent', status: 'paused',
        phase: 'Paused', pipeline_stage: 'paused', paused: true, keepalive_running: false,
      } as Keeper,
      {
        name: 'gone', agent_name: 'keeper-gone-agent', status: 'offline',
        phase: 'Offline', pipeline_stage: 'offline', keepalive_running: false,
      } as Keeper,
      {
        name: 'compact', agent_name: 'keeper-compact-agent', status: 'busy',
        phase: 'Compacting', pipeline_stage: 'compacting', keepalive_running: true,
      } as Keeper,
      {
        name: 'handoff', agent_name: 'keeper-handoff-agent', status: 'busy',
        phase: 'HandingOff', pipeline_stage: 'handoff', keepalive_running: true,
      } as Keeper,
      {
        name: 'drain', agent_name: 'keeper-drain-agent', status: 'busy',
        phase: 'Draining', pipeline_stage: 'draining', keepalive_running: true,
      } as Keeper,
      {
        name: 'restart', agent_name: 'keeper-restart-agent', status: 'busy',
        phase: 'Restarting', pipeline_stage: 'restarting', keepalive_running: true,
      } as Keeper,
    ]
    agents.value = []

    await act(async () => {
      render(html`<${AgentRoster} keeperFilter="keeper-only" />`, container)
    })
    await flushUi()

    const rows = Array.from(
      container.querySelectorAll('[data-testid="keeper-operations-row"]'),
    ) as HTMLElement[]
    expect(rows.length).toBe(7)
    // every row carries a tone the rail CSS can paint
    // RFC-0295: `busy` joins the valid set after the RuntimeBand 5th-value
    // extension; the CSS `[data-tone="busy"]` selectors in fleet.css are now
    // reachable from a transient-phase keeper.
    const valid = new Set(['ok', 'warn', 'bad', 'idle', 'busy'])
    expect(rows.every(r => valid.has(r.getAttribute('data-tone') ?? ''))).toBe(true)
    const toneByName = (name: string) =>
      rows.find(r => r.textContent?.includes(name))?.getAttribute('data-tone')
    // band → tone: paused=warn, offline=idle (the unambiguous bands).
    // RFC-0295 §5.3: Draining routes to `paused` band → warn rail (matches
    // prototype `data.jsx:37,49` `pause` glyph / `warn` tone pairing). It
    // is NOT in the transient group, so the transient-count chip drops
    // from 4 to 3.
    expect(toneByName('rester')).toBe('warn')
    expect(toneByName('gone')).toBe('idle')
    expect(toneByName('drain')).toBe('warn')
    for (const name of ['compact', 'handoff', 'restart']) {
      expect(toneByName(name)).toBe('busy')
    }
    const text = container.textContent ?? ''
    expect(text).toContain('전이 중 · 3')
    expect(text).toContain('일시정지 rows 2')
    expect(text).toContain('전이 rows 3')
    expect(text).toContain('transient')
    expect(text).toContain('오프라인 rows 1')
  })

  it('does not show keeper boot hints on offline non-keeper agent rows', async () => {
    agents.value = [
      makeAgent({
        name: 'mission-shadow',
        status: 'offline',
      }),
    ]
    keepers.value = []

    await act(async () => {
      render(html`<${AgentRoster} keeperFilter="agent-only" />`, container)
    })
    await flushUi()

    const text = container.textContent ?? ''
    expect(text).toContain('mission-shadow')
    expect(text).toContain('오프라인')
    expect(text).toContain('연결 없음')
    expect(text).not.toContain('기동 필요')
  })

  it('does not report source mismatch on default keeper ops when keeper projection has rows', async () => {
    agents.value = []
    keepers.value = [
      {
        name: 'albini',
        status: 'idle',
        phase: 'Running',
        pipeline_stage: 'idle',
        recent_tool_names: ['keeper_board_list'],
      } as Keeper,
    ]

    await act(async () => {
      render(html`<${AgentRoster} />`, container)
    })
    await flushUi()

    const text = container.textContent ?? ''
    expect(text).toContain('albini')
    expect(text).not.toContain('Source mismatch')
    expect(text).not.toContain('keeper projection 1')
    expect(text).not.toContain('파생')
  })

  it('does not expose synthetic implementation labels in agent rows', async () => {
    agents.value = [makeAgent({ name: 'runtime-shadow', synthetic: true })]
    keepers.value = []

    await act(async () => {
      render(html`<${AgentRoster} />`, container)
    })
    await flushUi()

    const text = container.textContent ?? ''
    expect(text).toContain('runtime-shadow')
    expect(text).not.toContain('파생')
  })

  it('renders the operations list with a selected detail pane', async () => {
    agents.value = [
      makeAgent({ name: 'alpha-agent', current_task: 'alpha task' }),
      makeAgent({ name: 'beta-agent', current_task: 'beta task' }),
    ]

    await act(async () => {
      render(html`<${AgentRoster} />`, container)
    })
    await flushUi()

    const rows = container.querySelectorAll('[data-testid="keeper-operations-row"]')
    expect(rows.length).toBe(2)
    expect(container.querySelector('aside h3')?.textContent).toContain('alpha-agent')

    await act(async () => {
      ;(rows[1] as HTMLElement).click()
    })

    expect(container.querySelector('aside h3')?.textContent).toContain('beta-agent')
    expect(container.textContent).toContain('상세 열기')
  })

  it('applies v2 monitoring marker classes to roster surfaces and rows', async () => {
    agents.value = [
      makeAgent({ name: 'alpha-agent', current_task: 'alpha task' }),
    ]

    await act(async () => {
      render(html`<${AgentRoster} />`, container)
    })
    await flushUi()

    expect(container.querySelector('aside.v2-monitoring-panel')).not.toBeNull()
    expect(container.querySelector('section.v2-monitoring-panel')).not.toBeNull()
    expect(container.querySelector('[data-testid="keeper-operations-row"]')?.classList.contains('v2-monitoring-roster-row')).toBe(true)
    expect(container.querySelector('button.v2-monitoring-action')?.textContent).toContain('상세 열기')
  })

  it('explains roster axes and renders blocker labels before raw codes', async () => {
    agents.value = [
      makeAgent({ name: 'keeper-executor-agent', status: 'active' }),
    ]
    keepers.value = [
      {
        name: 'executor',
        agent_name: 'keeper-executor-agent',
        status: 'active',
        runtime_blocker_class: 'fiber_unresolved',
        runtime_blocker_summary: 'fiber_unresolved',
      } as Keeper,
    ]

    await act(async () => {
      render(html`<${AgentRoster} keeperFilter="keeper-only" />`, container)
    })
    await flushUi()

    const text = container.textContent ?? ''
    expect(text).toContain('운영판정')
    // 2026-05-27: "현재 단계" 컬럼이 "차단 · 단계" 통합 컬럼으로 합쳐졌고, 종전
    // "차단 근거" 라벨도 같은 컬럼명으로 변경됨. 통합 라벨 한 곳만 확인하고,
    // 추가로 액션 컬럼 헤더가 노출되는지 검증한다.
    expect(text).toContain('차단 · 단계')
    expect(text).toContain('액션')
    expect(text).toContain('현재 차단: Fiber 미해결')
    expect(text).toContain('Keeper fiber가 종료 상태를 확정하지 못해 supervisor 확인이 필요합니다.')
  })

  it('lets paused runtime truth override stale busy agent presence', async () => {
    agents.value = [
      makeAgent({
        name: 'keeper-executor-agent',
        status: 'busy',
        current_task: 'task-463',
        last_seen: '2026-05-24T14:01:04Z',
      }),
    ]
    keepers.value = [
      {
        name: 'executor',
        agent_name: 'keeper-executor-agent',
        status: 'paused',
        phase: 'Paused',
        pipeline_stage: 'paused',
        paused: true,
        registered: false,
        keepalive_running: false,
        runtime_blocker_class: 'runtime_exhausted',
        runtime_blocker_summary: 'runtime_exhausted',
        agent: {
          exists: true,
          status: 'busy',
          current_task: 'task-463',
          last_seen: '2026-05-24T14:01:04Z',
        },
      } as Keeper,
    ]

    await act(async () => {
      render(html`<${AgentRoster} keeperFilter="keeper-only" />`, container)
    })
    await flushUi()

    const row = container.querySelector('[data-testid="keeper-operations-row"]') as HTMLElement
    const presence = row.querySelector('[data-agent-presence]') as HTMLElement
    expect(presence.dataset.presenceRawStatus).toBe('paused')
    expect(presence.dataset.presenceState).toBe('paused')
    expect(presence.dataset.presenceLabel).toBe('일시정지')
    expect(presence.textContent).toContain('오래된 작업 신호 task-463')

    const labels = Array.from(container.querySelectorAll('[data-agent-presence]'))
      .map(el => (el as HTMLElement).dataset.presenceLabel)
    expect(labels).not.toContain('작업 중')

    const text = container.textContent ?? ''
    expect(text).toContain('일시정지 원인: 런타임 후보 소진')
    expect(text).toContain('런타임 후보가 모두 소진되어 runtime 상태 확인이 필요합니다.')
  })

  it('projects live composite turns into keeper operation presence', async () => {
    agents.value = [
      makeAgent({
        name: 'keeper-sangsu-agent',
        status: 'active',
      }),
    ]
    keepers.value = [
      {
        name: 'sangsu',
        agent_name: 'keeper-sangsu-agent',
        status: 'active',
        phase: 'Running',
        pipeline_stage: 'idle',
        registered: true,
        keepalive_running: true,
      } as Keeper,
    ]
    fleetCompositeSnapshot.value = {
      generated_at: 1,
      count: 1,
      snapshots: [
        makeCompositeSnapshot({
          keeper: 'sangsu',
          is_live: true,
          turn_phase: 'executing',
          live_turn: {
            turn_id: 686,
            started_at: 1_781_184_817,
            last_progress_at: 1_781_184_843,
            last_progress_kind: 'sse_thinking_delta',
          },
        }),
      ],
    }

    await act(async () => {
      render(html`<${AgentRoster} keeperFilter="keeper-only" />`, container)
    })
    await flushUi()

    const row = container.querySelector('[data-testid="keeper-operations-row"]') as HTMLElement
    const presence = row.querySelector('[data-agent-presence]') as HTMLElement
    expect(presence.dataset.presenceRawStatus).toBe('busy')
    expect(presence.dataset.presenceState).toBe('working')
    expect(presence.dataset.presenceLabel).toBe('작업 중')
    expect(presence.textContent).toContain('executing live')
  })

  it('projects non-live composite keepers as waiting instead of busy', async () => {
    agents.value = [
      makeAgent({
        name: 'keeper-sangsu-agent',
        status: 'active',
      }),
    ]
    keepers.value = [
      {
        name: 'sangsu',
        agent_name: 'keeper-sangsu-agent',
        status: 'active',
        phase: 'Running',
        pipeline_stage: 'idle',
        registered: true,
        keepalive_running: true,
      } as Keeper,
    ]
    fleetCompositeSnapshot.value = {
      generated_at: 1,
      count: 1,
      snapshots: [
        makeCompositeSnapshot({
          keeper: 'sangsu',
          is_live: false,
          turn_phase: 'idle',
          live_turn: null,
        }),
      ],
    }

    await act(async () => {
      render(html`<${AgentRoster} keeperFilter="keeper-only" />`, container)
    })
    await flushUi()

    const row = container.querySelector('[data-testid="keeper-operations-row"]') as HTMLElement
    const presence = row.querySelector('[data-agent-presence]') as HTMLElement
    expect(presence.dataset.presenceRawStatus).toBe('idle')
    expect(presence.dataset.presenceState).toBe('idle')
    expect(presence.dataset.presenceLabel).toBe('대기')
    expect(presence.textContent).toContain('대기 중')
  })

  // #16 (38-bug campaign PR-5): a keeper actively executing a *reactively
  // woken* turn must render distinctly from one on its own proactive
  // cadence — the whole point of exposing typed `run_state`.
  it('surfaces the reactive wake cause from run_state for an in-turn keeper', async () => {
    agents.value = [makeAgent({ name: 'keeper-sangsu-agent', status: 'active' })]
    keepers.value = [
      {
        name: 'sangsu',
        agent_name: 'keeper-sangsu-agent',
        status: 'active',
        phase: 'Running',
        pipeline_stage: 'idle',
        registered: true,
        keepalive_running: true,
      } as Keeper,
    ]
    fleetCompositeSnapshot.value = {
      generated_at: 1,
      count: 1,
      snapshots: [
        makeCompositeSnapshot({
          keeper: 'sangsu',
          is_live: true,
          turn_phase: 'executing',
          live_turn: {
            turn_id: 686,
            started_at: 1_781_184_817,
            last_progress_at: 1_781_184_843,
            last_progress_kind: 'sse_thinking_delta',
          },
          run_state: {
            kind: 'in_turn',
            wake_kind: 'woken',
            stimulus_kinds: ['board_signal'],
            started_at: 1_781_184_817,
            active_tool_count: 1,
          },
        }),
      ],
    }

    await act(async () => {
      render(html`<${AgentRoster} keeperFilter="keeper-only" />`, container)
    })
    await flushUi()

    const row = container.querySelector('[data-testid="keeper-operations-row"]') as HTMLElement
    const presence = row.querySelector('[data-agent-presence]') as HTMLElement
    expect(presence.dataset.presenceRawStatus).toBe('busy')
    expect(presence.textContent).toContain('executing live')
    expect(presence.textContent).toContain('반응형')
  })

  it('surfaces the queue depth from run_state for a waiting keeper', async () => {
    agents.value = [makeAgent({ name: 'keeper-sangsu-agent', status: 'active' })]
    keepers.value = [
      {
        name: 'sangsu',
        agent_name: 'keeper-sangsu-agent',
        status: 'active',
        phase: 'Running',
        pipeline_stage: 'idle',
        registered: true,
        keepalive_running: true,
      } as Keeper,
    ]
    fleetCompositeSnapshot.value = {
      generated_at: 1,
      count: 1,
      snapshots: [
        makeCompositeSnapshot({
          keeper: 'sangsu',
          is_live: false,
          turn_phase: 'idle',
          live_turn: null,
          run_state: { kind: 'waiting', queue_depth: 2, skip_reasons: ['cooldown_pending'] },
        }),
      ],
    }

    await act(async () => {
      render(html`<${AgentRoster} keeperFilter="keeper-only" />`, container)
    })
    await flushUi()

    const row = container.querySelector('[data-testid="keeper-operations-row"]') as HTMLElement
    const presence = row.querySelector('[data-agent-presence]') as HTMLElement
    expect(presence.dataset.presenceRawStatus).toBe('idle')
    expect(presence.textContent).toContain('큐 2')
  })

  it('uses heartbeat and shared runtime labels for cards when action/model fallbacks disagree', async () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date('2026-04-24T18:00:00Z'))
    agents.value = [
      makeAgent({
        name: 'keeper-sangsu-agent',
        status: 'active',
        last_seen: '2026-04-24T17:55:00Z',
        model: 'claude',
      }),
    ]
    keepers.value = [
      {
        name: 'sangsu',
        agent_name: 'keeper-sangsu-agent',
        status: 'active',
        runtime_canonical: 'oas.primary',
        active_model: 'claude-code:auto',
        model: 'claude',
        last_heartbeat: '2026-04-24T17:54:00Z',
        last_autonomous_action_at: '2026-04-24T12:00:00Z',
        last_activity_ago_s: 21_600,
        recent_output_preview: '지금 필요한 코드 변경을 바로 만들고 결과를 확인한다.',
        recent_tool_names: ['keeper_tasks_list'],
      } as Keeper,
    ]

    await act(async () => {
      render(html`<${AgentRoster} keeperFilter="keeper-only" />`, container)
    })
    await flushUi()

    const text = container.textContent ?? ''
    expect(text).toContain('sangsu')
    expect(text).toContain('하트비트')
    expect(text).toContain('6분 전')
    expect(text).toContain('oas.primary')
    expect(text).not.toContain('claude-code:auto')
    expect(text).not.toContain('마지막 행동 이후')
    expect(text).not.toContain('최근 모델claude')
  })

  it('lists live recommended-action attention reasons in the selected keeper aside', async () => {
    agents.value = [makeAgent({ name: 'keeper-sangsu-agent', status: 'active' })]
    keepers.value = [
      {
        name: 'sangsu',
        agent_name: 'keeper-sangsu-agent',
        status: 'active',
        phase: 'Running',
        registered: true,
        keepalive_running: true,
      } as Keeper,
    ]
    fleetCompositeSnapshot.value = {
      generated_at: 1,
      count: 1,
      snapshots: [
        makeCompositeSnapshot({
          keeper: 'sangsu',
          runtime_attention: {
            state: 'blocked',
            needs_attention: true,
            blocked: true,
            reason: 'runtime candidates exhausted',
            raw_phase: null,
            is_live: true,
            source: 'runtime',
          },
          recommended_actions: [
            {
              action_type: 'keeper_recover',
              target_type: 'keeper',
              target_id: 'sangsu',
              severity: 'bad',
              reason: 'Resolve keeper tool-route contract blocker: runtime candidates exhausted',
            },
            {
              action_type: 'keeper_probe',
              target_type: 'keeper',
              target_id: 'sangsu',
              severity: 'warn',
              reason: 'Inspect keeper tool-route contract blocker: runtime candidates exhausted',
            },
            {
              action_type: 'operator_ping',
              target_type: 'operator',
              target_id: null,
              severity: 'warn',
              reason: 'operator-only action must not leak into the keeper aside',
            },
          ],
        }),
      ],
    }

    await act(async () => {
      render(html`<${AgentRoster} keeperFilter="keeper-only" />`, container)
    })
    await flushUi()

    const attn = container.querySelector('.fl-attn-list') as HTMLElement
    expect(attn).not.toBeNull()
    const items = attn.querySelectorAll('.fl-attn-item')
    // operator-targeted action is excluded — only keeper-targeted reasons render
    expect(items.length).toBe(2)
    expect(container.textContent).toContain('주의 · 2')
    expect(attn.textContent).toContain('Resolve keeper tool-route contract blocker')
    expect(attn.textContent).toContain('Inspect keeper tool-route contract blocker')
    expect(attn.textContent).not.toContain('operator-only action must not leak')
    // sev dot coding follows the recommended-action severity: recover→bad, probe→warn
    const sevs = Array.from(items).map(item => item.getAttribute('data-sev'))
    expect(sevs).toEqual(['bad', 'warn'])
  })

  it('omits the aside attention list when no live recommended actions target the keeper', async () => {
    agents.value = [makeAgent({ name: 'keeper-sangsu-agent', status: 'active' })]
    keepers.value = [
      {
        name: 'sangsu',
        agent_name: 'keeper-sangsu-agent',
        status: 'active',
        phase: 'Running',
        registered: true,
        keepalive_running: true,
      } as Keeper,
    ]
    fleetCompositeSnapshot.value = {
      generated_at: 1,
      count: 1,
      snapshots: [makeCompositeSnapshot({ keeper: 'sangsu', recommended_actions: [] })],
    }

    await act(async () => {
      render(html`<${AgentRoster} keeperFilter="keeper-only" />`, container)
    })
    await flushUi()

    expect(container.querySelector('.fl-attn-list')).toBeNull()
    expect(container.textContent).not.toContain('주의 · ')
  })

  it('surfaces the honest worktree-isolation badge for local-sandbox keepers', async () => {
    agents.value = [makeAgent({ name: 'keeper-sangsu-agent', status: 'active' })]
    keepers.value = [
      {
        name: 'sangsu',
        agent_name: 'keeper-sangsu-agent',
        keeper_id: 'sangsu-uuid-77',
        status: 'active',
        phase: 'Running',
        registered: true,
        keepalive_running: true,
        sandbox_profile: 'local',
      } as Keeper,
    ]

    await act(async () => {
      render(html`<${AgentRoster} keeperFilter="keeper-only" />`, container)
    })
    await flushUi()

    const row = container.querySelector('[data-testid="keeper-operations-row"]') as HTMLElement
    const badge = row.querySelector('.fl-sandbox') as HTMLElement
    expect(badge).not.toBeNull()
    expect(row.textContent).toContain('worktree 격리')
    // honest label: git worktree isolation is not an OS security boundary
    expect(badge.getAttribute('title')).toContain('OS sandbox 없음')
    // the runtime alias / keeper id no longer occupies the row ns slot
    expect((row.querySelector('.fl-ns') as HTMLElement).textContent).not.toContain('sangsu-uuid-77')
  })

  it('keeps the keeper id namespace line when no local sandbox profile is present', async () => {
    agents.value = [makeAgent({ name: 'keeper-sangsu-agent', status: 'active' })]
    keepers.value = [
      {
        name: 'sangsu',
        agent_name: 'keeper-sangsu-agent',
        keeper_id: 'sangsu-uuid-77',
        status: 'active',
        phase: 'Running',
        registered: true,
        keepalive_running: true,
        sandbox_profile: null,
      } as Keeper,
    ]

    await act(async () => {
      render(html`<${AgentRoster} keeperFilter="keeper-only" />`, container)
    })
    await flushUi()

    const row = container.querySelector('[data-testid="keeper-operations-row"]') as HTMLElement
    expect(row.querySelector('.fl-sandbox')).toBeNull()
    expect(row.querySelector('.fl-ns')?.textContent).toContain('sangsu-uuid-77')
  })

  it('vendors the fleet responsive column-shedding and attention-list styles', () => {
    const css = readFileSync(resolve(__dirname, '../styles/keeper-v2/fleet.css'), 'utf8')
    expect(css).toContain('@media (max-width: 1320px) and (min-width: 1101px)')
    expect(css).toContain('@media (max-width: 720px)')
    expect(css).toContain('.fl-attn-list')
    expect(css).toContain('.fl-attn-item[data-sev="bad"]')
  })
})
