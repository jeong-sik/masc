import { html } from 'htm/preact'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { AgentRoster, countRuntimeKinds } from './agent-roster'
import type { Agent, Keeper } from '../types'
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
    expect(container.textContent).not.toContain('stale mission preview')
    expect(container.textContent).not.toContain('stale keeper brief work')
    expect(container.textContent).not.toContain('stale_tool')
    expect(container.textContent).not.toContain('old blocker that should stay out of the roster')
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
    expect(text).toContain('claude_code:auto')
    expect(text).not.toContain('마지막 행동 이후')
    expect(text).not.toContain('최근 모델claude')
  })
})

