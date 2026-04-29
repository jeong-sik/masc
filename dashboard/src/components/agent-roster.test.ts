import { html } from 'htm/preact'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  AgentRoster,
  runtimeBadgeClass,
  stageBadgeClass,
  compactModelLabel,
  rosterContextMeta,
  rosterModelMeta,
  rosterStateNote,
  uniqueToolNames,
  keeperRuntimeName,
  isRuntimeBackedKeeper,
  mergeRosterAgent,
  filterAgentRoster,
  countRuntimeKinds,
} from './agent-roster'
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

describe('runtimeBadgeClass', () => {
  it('returns green classes for active', () => {
    expect(runtimeBadgeClass('active')).toContain('text-[var(--color-status-ok)]')
  })

  it('returns yellow classes for attention', () => {
    expect(runtimeBadgeClass('attention')).toContain('text-[var(--color-status-warn)]')
  })

  it('returns purple classes for paused', () => {
    expect(runtimeBadgeClass('paused')).toContain('var(--purple)')
  })

  it('returns dim classes for unknown band', () => {
    expect(runtimeBadgeClass('offline')).toContain('text-[var(--color-fg-disabled)]')
  })
})

describe('stageBadgeClass', () => {
  it('returns accent classes for tool_use', () => {
    expect(stageBadgeClass('tool_use')).toContain('text-[var(--color-accent-fg)]')
  })

  it('returns ok classes for thinking', () => {
    expect(stageBadgeClass('thinking')).toContain('text-[var(--color-status-ok)]')
  })

  it('returns ok classes for scheduled_autonomous', () => {
    expect(stageBadgeClass('scheduled_autonomous')).toContain('text-[var(--color-status-ok)]')
  })

  it('returns purple classes for handoff', () => {
    expect(stageBadgeClass('handoff')).toContain('#c4b5fd')
  })

  it('returns purple classes for compacting', () => {
    expect(stageBadgeClass('compacting')).toContain('#c4b5fd')
  })

  it('returns bad classes for failing', () => {
    expect(stageBadgeClass('failing')).toContain('text-[var(--color-status-err)]')
  })

  it('returns bad classes for crashed', () => {
    expect(stageBadgeClass('crashed')).toContain('text-[var(--color-status-err)]')
  })

  it('returns purple classes for paused stage', () => {
    expect(stageBadgeClass('paused')).toContain('var(--purple)')
  })

  it('returns muted classes for unknown stage', () => {
    expect(stageBadgeClass('idle')).toContain('text-[var(--color-fg-muted)]')
  })
})

describe('compactModelLabel', () => {
  it('returns null for null', () => {
    expect(compactModelLabel(null)).toBeNull()
  })

  it('returns null for undefined', () => {
    expect(compactModelLabel(undefined)).toBeNull()
  })

  it('returns null for empty string', () => {
    expect(compactModelLabel('')).toBeNull()
  })

  it('returns null for whitespace-only string', () => {
    expect(compactModelLabel('   ')).toBeNull()
  })

  it('drops the provider prefix for provider:model labels', () => {
    expect(compactModelLabel('provider:model-name')).toBe('model-name')
  })

  it('returns value as-is for no colon', () => {
    expect(compactModelLabel('claude-sonnet')).toBe('claude-sonnet')
  })

  it('keeps model family and variant after the first colon', () => {
    expect(compactModelLabel('ollama:qwen3.6:35b-a3b-mlx-bf16')).toBe('qwen3.6:35b-a3b-mlx-bf16')
  })

  it('falls back to the provider label when the resolved model is auto', () => {
    expect(compactModelLabel('codex_cli:auto')).toBe('codex')
  })

  it('handles spaces around segments', () => {
    expect(compactModelLabel('provider : model-name')).toBe('model-name')
  })
})

describe('rosterModelMeta', () => {
  it('prefers last_model_used_label when backend provides a display label', () => {
    expect(
      rosterModelMeta({
        last_model_used_label: 'qwen3.6:35b-a3b-mlx-bf16',
        last_model_used: 'ollama:qwen3.6:35b-a3b-mlx-bf16',
        active_model_label: 'codex_cli:auto',
        active_model: 'codex',
      } as Keeper),
    ).toEqual({ label: '최근 모델', value: 'qwen3.6:35b-a3b-mlx-bf16' })
  })

  it('prefers last_model_used as recent model', () => {
    expect(
      rosterModelMeta({
        last_model_used: 'openai:gpt-5.4',
        active_model: 'anthropic:claude-sonnet-4-6',
        model: 'fallback-model',
      } as Keeper),
    ).toEqual({ label: '최근 모델', value: 'openai:gpt-5.4' })
  })

  it('falls back to active_model_label when last model is absent', () => {
    expect(
      rosterModelMeta({
        active_model_label: 'codex_cli:auto',
        active_model: 'codex',
        model: 'fallback-model',
      } as Keeper),
    ).toEqual({ label: '현재 모델', value: 'codex_cli:auto' })
  })

  it('falls back to active_model when last model is absent', () => {
    expect(
      rosterModelMeta({
        active_model: 'anthropic:claude-sonnet-4-6',
        model: 'fallback-model',
      } as Keeper),
    ).toEqual({ label: '현재 모델', value: 'anthropic:claude-sonnet-4-6' })
  })

  it('uses generic model label as last fallback', () => {
    expect(rosterModelMeta({ model: 'fallback-model' } as Keeper)).toEqual({
      label: '모델',
      value: 'fallback-model',
    })
  })

  it('returns null when no model field is populated', () => {
    expect(rosterModelMeta({} as Keeper)).toBeNull()
  })
})

describe('rosterContextMeta', () => {
  it('returns percent and token budget summary when available', () => {
    expect(
      rosterContextMeta({
        context_ratio: 0.112,
        context_tokens: 22000,
        context_max: 200000,
      } as Keeper),
    ).toEqual({
      pct: 11,
      detail: '22.0K / 200.0K',
    })
  })

  it('returns only token count when max is absent', () => {
    expect(
      rosterContextMeta({
        context_ratio: 0.4,
        context_tokens: 4200,
      } as Keeper),
    ).toEqual({
      pct: 40,
      detail: '4.2K',
    })
  })

  it('returns null when ratio is missing', () => {
    expect(rosterContextMeta({ context_tokens: 4200 } as Keeper)).toBeNull()
  })
})

describe('rosterStateNote', () => {
  it('prefers runtime blocker as recent blocker note', () => {
    expect(
      rosterStateNote({
        runtime_blocker_summary: 'Turn wall-clock timeout after 1200s',
      } as Keeper, 'fallback hint'),
    ).toEqual({
      label: '현재 차단',
      text: 'Turn wall-clock timeout after 1200s',
    })
  })

  it('uses diagnostic last_error when blocker is absent', () => {
    expect(
      rosterStateNote({
        name: 'keeper-a',
        status: 'offline',
        diagnostic: {
          last_error: 'provider timeout',
          health_state: 'offline',
          next_action_path: 'probe',
          last_reply_status: 'never',
        },
      } as Keeper),
    ).toEqual({
      label: '최근 오류',
      text: 'provider timeout',
    })
  })

  it('falls back to monitoring hint as state note', () => {
    expect(rosterStateNote(null, '오래 응답이 없어 실제 상태 확인이 필요합니다.')).toEqual({
      label: '상태 메모',
      text: '오래 응답이 없어 실제 상태 확인이 필요합니다.',
    })
  })

  it('ignores historical last_blocker text without a live runtime blocker', () => {
    expect(
      rosterStateNote(
        {
          last_blocker: 'old social-model blocker',
        } as Keeper,
        null,
      ),
    ).toBeNull()
  })

  it('returns null when no note source is available', () => {
    expect(rosterStateNote(null, null)).toBeNull()
  })
})

describe('uniqueToolNames', () => {
  it('returns empty for no groups', () => {
    expect(uniqueToolNames()).toEqual([])
  })

  it('returns empty for null/undefined groups', () => {
    expect(uniqueToolNames(null, undefined)).toEqual([])
  })

  it('collects unique names from single group', () => {
    expect(uniqueToolNames(['a', 'b', 'c'])).toEqual(['a', 'b', 'c'])
  })

  it('deduplicates across groups', () => {
    expect(uniqueToolNames(['a', 'b'], ['b', 'c'])).toEqual(['a', 'b', 'c'])
  })

  it('deduplicates within a group', () => {
    expect(uniqueToolNames(['a', 'a', 'b'])).toEqual(['a', 'b'])
  })

  it('trims whitespace', () => {
    expect(uniqueToolNames([' a ', 'b'])).toEqual(['a', 'b'])
  })

  it('skips empty strings', () => {
    expect(uniqueToolNames(['', 'a', ''])).toEqual(['a'])
  })

  it('preserves first occurrence order', () => {
    expect(uniqueToolNames(['z', 'a'], ['a', 'z', 'b'])).toEqual(['z', 'a', 'b'])
  })
})

describe('keeperRuntimeName', () => {
  it('returns agent_name when present', () => {
    expect(keeperRuntimeName({ name: 'keeper1', agent_name: 'claude-agent' })).toBe('claude-agent')
  })

  it('falls back to name when agent_name is empty', () => {
    expect(keeperRuntimeName({ name: 'keeper1', agent_name: '' })).toBe('keeper1')
  })

  it('falls back to name when agent_name is whitespace', () => {
    expect(keeperRuntimeName({ name: 'keeper1', agent_name: '  ' })).toBe('keeper1')
  })

  it('falls back to name when agent_name is undefined', () => {
    expect(keeperRuntimeName({ name: 'keeper1' })).toBe('keeper1')
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

describe('isRuntimeBackedKeeper', () => {
  it('keeps paused keepers when the supervisor still reports a runtime', () => {
    expect(isRuntimeBackedKeeper({
      paused: true,
      registered: true,
      keepalive_running: false,
    })).toBe(true)
  })

  it('drops paused metas with no registered or keepalive runtime', () => {
    expect(isRuntimeBackedKeeper({
      paused: true,
      registered: false,
      keepalive_running: false,
    })).toBe(false)
  })
})

describe('mergeRosterAgent', () => {
  const baseAgent: Agent = {
    name: 'test-agent',
    status: 'active',
    current_task: null,
  }
  const nextAgent: Agent = {
    name: 'test-agent',
    status: 'idle',
    current_task: 'task-1',
    emoji: '🤖',
    model: 'claude-sonnet',
  }

  it('returns next when existing is undefined', () => {
    expect(mergeRosterAgent(undefined, nextAgent)).toEqual(nextAgent)
  })

  it('prefers existing status over next', () => {
    const result = mergeRosterAgent(baseAgent, nextAgent)
    expect(result.status).toBe('active')
  })

  it('fills in missing fields from next', () => {
    const result = mergeRosterAgent(baseAgent, nextAgent)
    // null ?? 'task-1' = 'task-1' — ?? replaces null/undefined
    expect(result.current_task).toBe('task-1')
    expect(result.emoji).toBe('🤖')
    expect(result.model).toBe('claude-sonnet')
  })

  it('uses existing capabilities when non-empty', () => {
    const existing: Agent = {
      ...baseAgent,
      capabilities: ['tool-a'],
    }
    const next: Agent = { ...nextAgent, capabilities: ['tool-b'] }
    const result = mergeRosterAgent(existing, next)
    expect(result.capabilities).toEqual(['tool-a'])
  })

  it('uses next capabilities when existing is empty', () => {
    const existing: Agent = {
      ...baseAgent,
      capabilities: [],
    }
    const next: Agent = { ...nextAgent, capabilities: ['tool-b'] }
    const result = mergeRosterAgent(existing, next)
    expect(result.capabilities).toEqual(['tool-b'])
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

describe('filterAgentRoster', () => {
  const rows: Agent[] = [
    makeAgent({ name: 'keeper-alpha', model: 'gpt-5.4', current_task: 'review PR #42' }),
    makeAgent({ name: 'keeper-beta', model: 'claude-sonnet-4-6', current_task: null, koreanName: '베타' }),
    makeAgent({ name: 'watcher-gamma', current_task: 'compact memory' }),
  ]

  it('returns the input reference when query is empty', () => {
    expect(filterAgentRoster(rows, '')).toBe(rows)
  })

  it('returns the input reference for whitespace-only query', () => {
    expect(filterAgentRoster(rows, '   ')).toBe(rows)
  })

  it('trims query before matching', () => {
    expect(filterAgentRoster(rows, '  alpha  ')).toHaveLength(1)
  })

  it('matches by name substring (case-insensitive)', () => {
    const result = filterAgentRoster(rows, 'KEEPER')
    expect(result).toHaveLength(2)
    expect(result.map(r => r.name)).toEqual(['keeper-alpha', 'keeper-beta'])
  })

  it('matches by model substring', () => {
    const result = filterAgentRoster(rows, 'claude')
    expect(result.map(r => r.name)).toEqual(['keeper-beta'])
  })

  it('matches by current_task substring', () => {
    const result = filterAgentRoster(rows, 'compact')
    expect(result.map(r => r.name)).toEqual(['watcher-gamma'])
  })

  it('matches by koreanName substring', () => {
    const result = filterAgentRoster(rows, '베타')
    expect(result.map(r => r.name)).toEqual(['keeper-beta'])
  })

  it('returns empty when no field matches', () => {
    expect(filterAgentRoster(rows, 'nonexistent-token')).toHaveLength(0)
  })

  it('does not mutate the input array', () => {
    const copy = rows.slice()
    filterAgentRoster(rows, 'alpha')
    expect(rows).toEqual(copy)
  })

  it('handles rows with null / missing optional fields safely', () => {
    const input: Agent[] = [makeAgent({ name: 'orphan' })]
    expect(filterAgentRoster(input, 'orphan')).toHaveLength(1)
    expect(filterAgentRoster(input, 'anything-else')).toHaveLength(0)
  })

  it('handles empty rows array', () => {
    const empty: Agent[] = []
    expect(filterAgentRoster(empty, 'foo')).toHaveLength(0)
    expect(filterAgentRoster(empty, '')).toBe(empty)
  })
})
