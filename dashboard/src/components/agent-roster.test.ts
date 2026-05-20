import { html } from 'htm/preact'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { AgentRoster, countRuntimeKinds, rosterStateNote } from './agent-roster'
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

function makeAgent(overrides: Partial<Agent> = {}): Agent {
  return {
    name: 'agent-x',
    status: 'active',
    current_task: null,
    ...overrides,
  }
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
      cascade: { state: 'idle' },
      compaction: { stage: 'idle' },
      measurement: {} as KeeperCompositeSnapshot['measurement'],
      invariants: {} as KeeperCompositeSnapshot['invariants'],
      fsm_guard_violations: 0,
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

  it('returns "현재 차단" when blocker is set and no composite is available', () => {
    const note = rosterStateNote(
      k({ runtime_blocker_class: 'synthetic_stall', runtime_blocker_summary: '실제 막힘' }),
      null,
      null,
    )
    expect(note).toEqual({
      label: '현재 차단',
      text: '실제 막힘',
      kind: 'synthetic_stall',
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
        runtime_blocker_class: 'cascade_exhausted',
        runtime_blocker_summary: 'cascade list 소진',
      }),
      compositeWith(attention({ execution_current: true, blocked: true })),
      null,
    )
    expect(note).toEqual({
      label: '현재 차단',
      text: 'cascade list 소진',
      kind: 'cascade_exhausted',
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

  it('falls through to diagnostic error when no blocker and no stale blocker', () => {
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
    expect(note).toEqual({ label: '최근 오류', text: 'tool call failed' })
  })

  it('falls through to monitoring hint when nothing else applies', () => {
    const note = rosterStateNote(
      k({ phase: 'Running' }),
      null,
      '관찰 메모',
    )
    expect(note).toEqual({ label: '상태 메모', text: '관찰 메모' })
  })

  it('paused keeper produces no state note (signaled by badge elsewhere)', () => {
    const note = rosterStateNote(
      k({ paused: true, runtime_blocker_class: 'supervisor_paused' }),
      null,
      null,
    )
    expect(note).toBeNull()
  })

  it('offline keeper produces no state note', () => {
    const note = rosterStateNote(
      k({ phase: 'Crashed', status: 'offline' }),
      null,
      null,
    )
    expect(note).toBeNull()
  })

  it('null keeper returns null', () => {
    expect(rosterStateNote(null, null, null)).toBeNull()
  })
})

describe('countRuntimeKinds', () => {
  it('excludes configured-only paused keepers from live runtime counts', () => {
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
      pausedKeepers: 0,
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
      totalRuntimes: 2,
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
      ;(rows[1] as HTMLButtonElement).click()
    })

    expect(container.querySelector('aside h3')?.textContent).toContain('beta-agent')
    expect(container.textContent).toContain('상세 열기')
  })

  it('uses heartbeat and full keeper model for cards when action/model fallbacks disagree', async () => {
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
        active_model: 'claude_code:auto',
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
    expect(text).not.toContain('claude_code:auto')
    expect(text).not.toContain('마지막 행동 이후')
    expect(text).not.toContain('최근 모델claude')
  })
})
