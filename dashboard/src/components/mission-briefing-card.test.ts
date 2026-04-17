import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type {
  DashboardMissionBriefingResponse,
  DashboardMissionResponse,
  OperatorSnapshot,
} from '../types'

void vi

async function flushUi(): Promise<void> {
  for (let i = 0; i < 4; i += 1) {
    await Promise.resolve()
    await new Promise(resolve => setTimeout(resolve, 0))
  }
}

function sampleMission(): DashboardMissionResponse {
  return {
    generated_at: '2026-03-31T00:00:00Z',
    summary: {
      room_health: 'warn',
      namespace: 'default',
    },
    sessions: [
      {
        session_id: 'ts-1234',
        goal: 'stabilize dashboard',
        blocker_summary: 'judge path missing',
      },
    ],
    attention_queue: [
      {
        id: 'attn-1',
        kind: 'judge_gap',
        severity: 'warn',
        summary: '판단 에이전트 경로가 보이지 않습니다.',
        target_type: 'keeper',
        related_session_ids: ['ts-1234'],
        evidence_preview: [],
      },
    ],
    internal_signals: [],
    agent_briefs: [],
    keeper_briefs: [],
  } as unknown as DashboardMissionResponse
}

function sampleBriefing(): DashboardMissionBriefingResponse {
  return {
    generated_at: '2026-03-31T00:00:00Z',
    cached: false,
    stale: false,
    refreshing: false,
    status: 'ok',
    summary: '판단 카드가 deterministic 요약만 보여주고 있습니다.',
    provenance: 'narrative',
    authoritative: false,
    model: 'deterministic',
    ttl_sec: 300,
    criteria: [],
    metadata_gap_count: 2,
    metadata_gaps: [
      {
        scope_type: 'keeper',
        scope_id: 'live-judge',
        severity: 'watch',
        summary: '실제 판단 경로가 UI에서 드러나지 않습니다.',
      },
    ],
    sections: [
      {
        label: 'watch',
        status: 'warn',
        summary: '판단이 브리핑 카드 안에서 고정된 텍스트처럼 보입니다.',
        evidence: ['dashboard/src/components/mission-briefing-card.ts'],
        signal_class: 'mixed',
      },
    ],
    error: null,
    last_error: null,
  } as unknown as DashboardMissionBriefingResponse
}

function sampleOperatorSnapshot(): OperatorSnapshot {
  return {
    root: {
      paused: false,
    },
    sessions: [],
    keepers: [
      {
        name: 'live-judge',
        status: 'running',
        model: 'glm-5',
        last_model_used: 'glm-5',
      },
    ],
    operator_judge_runtime: {
      enabled: true,
      judge_online: true,
      refreshing: false,
      generated_at: '2026-03-31T00:00:00Z',
      expires_at: '2026-03-31T00:05:00Z',
      model_used: 'glm-5',
      keeper_name: 'live-judge',
      last_error: null,
    },
    persistent_agents: [],
    recent_messages: [],
    pending_confirms: [],
    available_actions: [],
  } as unknown as OperatorSnapshot
}

async function loadMissionBriefingCard(navigateMock = vi.fn()) {
  vi.resetModules()
  vi.doMock('../router', () => ({
    navigate: navigateMock,
  }))
  const missionStore = await import('../mission-store')
  const operatorStore = await import('../operator-store')
  const sharedStore = await import('../store')
  const workflowContext = await import('../workflow-context')
  const module = await import('./mission-briefing-card')
  return {
    navigateMock,
    missionStore,
    operatorStore,
    sharedStore,
    workflowContext,
    ...module,
  }
}

describe('MissionBriefingCard', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    sessionStorage.clear()
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(async () => {
    render(null, container)
    container.remove()
    vi.resetModules()
    vi.clearAllMocks()
    vi.doUnmock('../router')
  })

  it('prefers the live judge runtime keeper when building a live report target', async () => {
    const { resolveLiveJudgeTarget } = await loadMissionBriefingCard()
    const target = resolveLiveJudgeTarget(sampleOperatorSnapshot(), [
      {
        name: 'fallback-keeper',
        status: 'running',
        model: 'llama',
      } as never,
    ])

    expect(target).toEqual({
      name: 'live-judge',
      model: 'glm-5',
      source: 'judge_runtime',
      online: true,
    })
  }, 40000)

  it('falls back to available keepers and returns null when none are usable', async () => {
    const { resolveLiveJudgeTarget } = await loadMissionBriefingCard()

    const fallbackTarget = resolveLiveJudgeTarget(
      {
        ...sampleOperatorSnapshot(),
        operator_judge_runtime: {
          ...sampleOperatorSnapshot().operator_judge_runtime,
          keeper_name: '',
        },
        keepers: [],
      },
      [
        {
          name: 'fallback-keeper',
          status: 'running',
          model: 'glm-fallback',
        } as never,
      ],
    )

    expect(fallbackTarget).toEqual({
      name: 'fallback-keeper',
      model: 'glm-fallback',
      source: 'keeper',
      online: true,
    })

    const unavailableTarget = resolveLiveJudgeTarget(
      {
        ...sampleOperatorSnapshot(),
        operator_judge_runtime: null,
        keepers: [
          {
            name: 'offline-keeper',
            status: 'offline',
            model: 'glm-offline',
          },
        ],
      } as unknown as OperatorSnapshot,
      [],
    )

    expect(unavailableTarget).toBeNull()
  }, 40000)

  it('does not mark judge runtime online when runtime and keeper state are both unknown', async () => {
    const { resolveLiveJudgeTarget } = await loadMissionBriefingCard()
    const target = resolveLiveJudgeTarget(
      {
        ...sampleOperatorSnapshot(),
        operator_judge_runtime: {
          ...sampleOperatorSnapshot().operator_judge_runtime,
          judge_online: false,
          keeper_name: 'orphan-judge',
        },
        keepers: [],
      },
      [],
    )

    expect(target).toEqual({
      name: 'orphan-judge',
      model: 'glm-5',
      source: 'judge_runtime',
      online: false,
    })
  }, 40000)

  it('builds a safe situation report even when mission facts are sparse', async () => {
    const { buildLiveJudgeSituationReport } = await loadMissionBriefingCard()
    const report = buildLiveJudgeSituationReport({
      mission: {
        ...sampleMission(),
        sessions: [],
        attention_queue: [],
        summary: {
          ...sampleMission().summary,
          namespace: null,
          room_health: 'unknown',
        },
      } as unknown as DashboardMissionResponse,
      briefing: null,
      target: {
        name: 'live-judge',
        model: 'glm-5',
        source: 'judge_runtime',
        online: true,
      },
    })

    expect(report).toContain('[상황 보고] live-judge · glm-5')
    expect(report).toContain('- namespace: default')
    expect(report).toContain('- sessions: 0, attention: 0, blockers: 0')
    expect(report).toContain('live 판단을 해 주세요.')
  }, 20000)

  it('opens intervene with a prefilled live judgment report', async () => {
    const navigateMock = vi.fn()
    const {
      MissionBriefingCard,
      missionStore,
      operatorStore,
      sharedStore,
      workflowContext,
    } = await loadMissionBriefingCard(navigateMock)

    missionStore.missionSnapshot.value = sampleMission()
    missionStore.missionBriefing.value = sampleBriefing()
    missionStore.missionBriefingError.value = null
    missionStore.missionBriefingLoading.value = false
    operatorStore.operatorSnapshot.value = sampleOperatorSnapshot()
    sharedStore.keepers.value = [
      {
        name: 'live-judge',
        status: 'running',
        model: 'glm-5',
        last_model_used: 'glm-5',
      } as never,
    ]

    render(html`<${MissionBriefingCard} />`, container)
    await flushUi()

    expect(container.textContent).toContain('live-judge')
    expect(container.textContent).toContain('실제 판단 요청')

    const button = Array.from(container.querySelectorAll('button'))
      .find(item => item.textContent?.includes('실제 판단 요청'))
    button?.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flushUi()

    expect(navigateMock).toHaveBeenCalledWith(
      'command',
      expect.objectContaining({
        section: 'operations',
        action_type: 'keeper_message',
        target_type: 'keeper',
        target_id: 'live-judge',
      }),
    )

    const payload = workflowContext.dashboardWorkflowContext.value?.suggested_payload as Record<string, unknown> | null
    expect(payload?.message).toContain('[상황 보고] live-judge · glm-5')
    expect(payload?.message).toContain('deterministic 요약')
    expect(payload?.message).toContain('답변 형식: 1) 지금 위험 1-3개 2) 바로 필요한 조치 3) 놓친 관측 공백')
  }, 20000)

  it('uses mission keeper briefs as a fallback without forcing operator snapshot state', async () => {
    const navigateMock = vi.fn()
    const {
      MissionBriefingCard,
      missionStore,
      operatorStore,
      sharedStore,
      workflowContext,
    } = await loadMissionBriefingCard(navigateMock)

    missionStore.missionSnapshot.value = {
      ...sampleMission(),
      keeper_briefs: [
        {
          name: 'mission-judge',
          status: 'running',
        },
      ],
    } as unknown as DashboardMissionResponse
    missionStore.missionBriefing.value = sampleBriefing()
    missionStore.missionBriefingError.value = null
    missionStore.missionBriefingLoading.value = false
    operatorStore.operatorSnapshot.value = null
    sharedStore.keepers.value = []

    render(html`<${MissionBriefingCard} />`, container)
    await flushUi()

    expect(container.textContent).toContain('mission-judge')

    const button = Array.from(container.querySelectorAll('button'))
      .find(item => item.textContent?.includes('실제 판단 요청'))
    button?.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flushUi()

    expect(navigateMock).toHaveBeenCalledWith(
      'command',
      expect.objectContaining({
        section: 'operations',
        action_type: 'keeper_message',
        target_type: 'keeper',
        target_id: 'mission-judge',
      }),
    )

    const payload = workflowContext.dashboardWorkflowContext.value?.suggested_payload as Record<string, unknown> | null
    expect(payload?.message).toContain('[상황 보고] mission-judge')
  }, 20000)
})

describe('filterMetadataGaps', () => {
  type Gap = {
    kind: string
    summary: string
    scope_type: 'session' | 'keeper' | 'agent'
    scope_id?: string | null
    severity: 'info' | 'watch'
  }

  const sampleGaps = (): Gap[] => [
    {
      kind: 'missing_model',
      summary: '판단 키퍼 모델이 비어 있습니다.',
      scope_type: 'keeper',
      scope_id: 'live-judge',
      severity: 'watch',
    },
    {
      kind: 'stale_snapshot',
      summary: '세션 스냅샷이 오래되었습니다.',
      scope_type: 'session',
      scope_id: 'ts-4242',
      severity: 'info',
    },
    {
      kind: 'no_briefing',
      summary: 'Agent briefing has been missing for GraphRAG.',
      scope_type: 'agent',
      scope_id: null,
      severity: 'info',
    },
  ]

  it('returns the input reference when query is empty', async () => {
    const { filterMetadataGaps } = await import('./mission-briefing-card')
    const gaps = sampleGaps()
    expect(filterMetadataGaps(gaps, '')).toBe(gaps)
  })

  it('returns the input reference when query is whitespace only', async () => {
    const { filterMetadataGaps } = await import('./mission-briefing-card')
    const gaps = sampleGaps()
    expect(filterMetadataGaps(gaps, '   \t\n ')).toBe(gaps)
  })

  it('trims the query before matching', async () => {
    const { filterMetadataGaps } = await import('./mission-briefing-card')
    const result = filterMetadataGaps(sampleGaps(), '  live-judge  ')
    expect(result).toHaveLength(1)
    expect(result[0]?.scope_id).toBe('live-judge')
  })

  it('matches case-insensitively on summary', async () => {
    const { filterMetadataGaps } = await import('./mission-briefing-card')
    const result = filterMetadataGaps(sampleGaps(), 'GRAPHRAG')
    expect(result).toHaveLength(1)
    expect(result[0]?.kind).toBe('no_briefing')
  })

  it('matches a substring of scope_id', async () => {
    const { filterMetadataGaps } = await import('./mission-briefing-card')
    const result = filterMetadataGaps(sampleGaps(), 'ts-42')
    expect(result).toHaveLength(1)
    expect(result[0]?.scope_id).toBe('ts-4242')
  })

  it('matches a substring of kind', async () => {
    const { filterMetadataGaps } = await import('./mission-briefing-card')
    const result = filterMetadataGaps(sampleGaps(), 'stale')
    expect(result).toHaveLength(1)
    expect(result[0]?.kind).toBe('stale_snapshot')
  })

  it('matches severity exactly for watch keyword', async () => {
    const { filterMetadataGaps } = await import('./mission-briefing-card')
    const result = filterMetadataGaps(sampleGaps(), 'watch')
    expect(result).toHaveLength(1)
    expect(result[0]?.severity).toBe('watch')
  })

  it('matches severity exactly for info keyword and returns both info gaps', async () => {
    const { filterMetadataGaps } = await import('./mission-briefing-card')
    const result = filterMetadataGaps(sampleGaps(), 'info')
    expect(result).toHaveLength(2)
    expect(result.every(item => item.severity === 'info')).toBe(true)
  })

  it('returns an empty array when nothing matches', async () => {
    const { filterMetadataGaps } = await import('./mission-briefing-card')
    expect(filterMetadataGaps(sampleGaps(), 'zzzz-nonexistent')).toEqual([])
  })

  it('does not mutate the input array', async () => {
    const { filterMetadataGaps } = await import('./mission-briefing-card')
    const gaps = sampleGaps()
    const snapshot = gaps.map(item => ({ ...item }))
    filterMetadataGaps(gaps, 'live-judge')
    expect(gaps).toEqual(snapshot)
  })
})
