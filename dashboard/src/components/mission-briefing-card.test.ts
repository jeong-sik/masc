import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type {
  DashboardMissionBriefingResponse,
  DashboardMissionResponse,
  OperatorSnapshot,
} from '../types'

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
      current_room: 'default',
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
    session_briefs: [],
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
    room: {
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

    expect(container.textContent).toContain('실제 판단 대상')
    expect(container.textContent).toContain('live-judge')
    expect(container.textContent).toContain('실제 판단 요청 열기')

    const button = Array.from(container.querySelectorAll('button'))
      .find(item => item.textContent?.includes('실제 판단 요청 열기'))
    button?.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flushUi()

    expect(navigateMock).toHaveBeenCalledWith(
      'command',
      expect.objectContaining({
        section: 'intervene',
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
})
