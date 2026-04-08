import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

void vi

const missionSnapshot = { value: null as Record<string, unknown> | null }
const missionLoading = { value: false }
const refreshMissionSnapshot = vi.fn().mockResolvedValue(undefined)

const namespaceTruth = { value: null as Record<string, unknown> | null }
const namespaceTruthLoading = { value: false }
const refreshNamespaceTruth = vi.fn().mockResolvedValue(undefined)

const topActiveAgents = { value: [] as unknown[] }
const shellMetaCognition = { value: null as Record<string, unknown> | null }
const serverStatus = { value: null as Record<string, unknown> | null }
const navigate = vi.fn()
const navigateToPost = vi.fn()
const connected = { value: true }
const eventCount = { value: 0 }
const lastEvent = { value: null as { ts_unix?: number } | null }

async function flushUi(): Promise<void> {
  await Promise.resolve()
  await Promise.resolve()
}

async function loadOverview() {
  vi.resetModules()
  vi.doMock('../../mission-store', () => ({
    missionSnapshot,
    missionLoading,
    refreshMissionSnapshot,
  }))
  vi.doMock('../../namespace-truth-store', () => ({
    namespaceTruth,
    namespaceTruthLoading,
    refreshNamespaceTruth,
  }))
  vi.doMock('../../observatory-store', () => ({
    topActiveAgents,
  }))
  vi.doMock('../../store', () => ({
    shellMetaCognition,
    serverStatus,
  }))
  vi.doMock('../../sse', () => ({
    journal: [],
    connected,
    eventCount,
    lastEvent,
  }))
  vi.doMock('../../router', () => ({
    navigate,
    navigateToPost,
    hashForRoute: vi.fn().mockReturnValue('#'),
  }))
  vi.doMock('./situation-banner', () => ({
    SituationBanner: () => html`<div>Situation</div>`,
  }))
  vi.doMock('./attention-spotlight', () => ({
    AttentionSpotlight: () => html`<div>Attention</div>`,
  }))
  vi.doMock('./narrative-timeline', () => ({
    NarrativeTimeline: () => html`<div>Narrative</div>`,
  }))
  vi.doMock('./agent-avatar', () => ({
    AgentAvatar: () => html`<div>Avatar</div>`,
  }))
  vi.doMock('../transport-health', () => ({
    TransportHealthPanel: () => html`<div>Transport</div>`,
  }))
  vi.doMock('../perf-snapshot', () => ({
    PerfSnapshotPanel: () => html`<div>Perf</div>`,
  }))
  vi.doMock('../connector-status', () => ({
    ConnectorStatusPanel: () => html`<div>Connector Panel</div>`,
  }))
  return import('./overview')
}

describe('Overview freshness strip', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    vi.spyOn(Date, 'now').mockReturnValue(new Date('2026-03-26T12:10:00Z').getTime())
    container = document.createElement('div')
    document.body.appendChild(container)
    missionLoading.value = false
    namespaceTruthLoading.value = false
    topActiveAgents.value = []
    shellMetaCognition.value = null
    serverStatus.value = null
    connected.value = true
    eventCount.value = 0
    lastEvent.value = null
    missionSnapshot.value = {
      generated_at: '2026-03-26T12:09:00Z',
      summary: {},
      sessions: [],
      session_briefs: [],
      attention_queue: [],
    }
    namespaceTruth.value = {
      generated_at: '2026-03-26T12:08:00Z',
    }
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.clearAllMocks()
    vi.restoreAllMocks()
    vi.resetModules()
    vi.doUnmock('../../mission-store')
    vi.doUnmock('../../namespace-truth-store')
    vi.doUnmock('../../observatory-store')
    vi.doUnmock('../../store')
    vi.doUnmock('../../sse')
    vi.doUnmock('../../router')
    vi.doUnmock('./situation-banner')
    vi.doUnmock('./attention-spotlight')
    vi.doUnmock('./narrative-timeline')
    vi.doUnmock('./agent-avatar')
    vi.doUnmock('../transport-health')
    vi.doUnmock('../perf-snapshot')
    vi.doUnmock('../connector-status')
  })

  it('shows a stale warning when the oldest overview snapshot is over 5 minutes old', async () => {
    namespaceTruth.value = {
      generated_at: '2026-03-26T12:03:00Z',
    }

    const { Overview } = await loadOverview()
    render(html`<${Overview} />`, container)
    await flushUi()

    expect(container.textContent).toContain('Overview Freshness')
    expect(container.textContent).toContain('마지막 갱신:')
    expect(container.textContent).toContain('7분 전')
    expect(container.textContent).toContain('5분 이상 stale')
  }, 15000)

  it('forces both overview data sources to refresh from the action button', async () => {
    const { Overview } = await loadOverview()
    render(html`<${Overview} />`, container)
    await flushUi()

    expect(container.textContent).not.toContain('5분 이상 stale')

    const button = Array.from(container.querySelectorAll('button'))
      .find(candidate => candidate.textContent?.includes('새로고침'))
    button?.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flushUi()

    expect(refreshNamespaceTruth).toHaveBeenCalledWith({ force: true })
    expect(refreshMissionSnapshot).toHaveBeenCalledWith({ force: true })
  }, 15000)

  it('renders the connector operations card as a top-level overview section', async () => {
    const { Overview } = await loadOverview()
    render(html`<${Overview} />`, container)
    await flushUi()

    expect(container.textContent).toContain('Connector Panel')
  }, 15000)

  it('renders the meta-cognition summary card when shell data is available', async () => {
    namespaceTruth.value = {
      generated_at: '2026-03-26T12:08:00Z',
      meta_cognition: {
        latest_digest: {
          post_id: 'post-meta-1',
          title: '[meta-cognition] contested belief requires follow-up',
          created_at: '2026-03-26T12:07:30Z',
          matches_summary: true,
          provenance: 'board',
        },
      },
      focus: {
        label: '주의 필요',
        reason: '집단 인식에 이견이 있습니다: keepers believe masc_* tools are blocked',
        source: 'meta_cognition',
        provenance: 'derived',
        suggested_tab: 'overview',
      },
    }
    shellMetaCognition.value = {
      stagnation_score: 0.72,
      belief_count: 2,
      contested_belief_count: 1,
      dominant_belief: {
        id: 'belief:masc_tools_blocked',
        claim: 'keepers believe masc_* tools are blocked',
        status: 'contested',
        support_agent_count: 2,
      },
      top_tension: {
        id: 'tension:masc_tool_blockage',
        topic: 'keeper-facing masc_* tool blockage',
        severity: 'high',
        needs_operator: true,
      },
      top_desire: {
        id: 'desire:operator_guidance',
        desired_state: 'get operator guidance to unblock current work',
        actionability: 'operator',
      },
    }

    const { Overview } = await loadOverview()
    render(html`<${Overview} />`, container)
    await flushUi()

    expect(container.textContent).toContain('집단 메타인지')
    expect(container.textContent).toContain('정체 72%')
    expect(container.textContent).toContain('이견 1')
    expect(container.textContent).toContain('최근 board digest')
    expect(container.textContent).toContain('게시물 열기')
    expect(container.textContent).toContain('공감대')
    expect(container.textContent).toContain('긴장')
    expect(container.textContent).toContain('욕구')
    expect(container.textContent).toContain('namespace-truth focus')
    expect(container.textContent).toContain('집단 인식에 이견이 있습니다')
    expect(container.textContent).toContain('운영자 개입 필요')

    const digestButton = Array.from(container.querySelectorAll('button'))
      .find(candidate => candidate.textContent?.includes('게시물 열기'))
    digestButton?.dispatchEvent(new MouseEvent('click', { bubbles: true }))

    expect(navigateToPost).toHaveBeenCalledWith('post-meta-1')
  }, 15000)
})

describe('ToolCallHealthPanel', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    vi.spyOn(Date, 'now').mockReturnValue(new Date('2026-03-26T12:10:00Z').getTime())
    container = document.createElement('div')
    document.body.appendChild(container)
    missionLoading.value = false
    namespaceTruthLoading.value = false
    topActiveAgents.value = []
    shellMetaCognition.value = null
    serverStatus.value = null
    connected.value = true
    eventCount.value = 0
    lastEvent.value = null
    missionSnapshot.value = {
      generated_at: '2026-03-26T12:09:00Z',
      summary: {},
      sessions: [],
      session_briefs: [],
      attention_queue: [],
    }
    namespaceTruth.value = {
      generated_at: '2026-03-26T12:08:00Z',
    }
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.clearAllMocks()
    vi.restoreAllMocks()
    vi.resetModules()
    vi.doUnmock('../../mission-store')
    vi.doUnmock('../../namespace-truth-store')
    vi.doUnmock('../../observatory-store')
    vi.doUnmock('../../store')
    vi.doUnmock('../../sse')
    vi.doUnmock('../../router')
    vi.doUnmock('./situation-banner')
    vi.doUnmock('./attention-spotlight')
    vi.doUnmock('./narrative-timeline')
    vi.doUnmock('./agent-avatar')
    vi.doUnmock('../transport-health')
    vi.doUnmock('../perf-snapshot')
    vi.doUnmock('../connector-status')
  })

  it('hides the panel when serverStatus is null', async () => {
    serverStatus.value = null

    const { Overview } = await loadOverview()
    render(html`<${Overview} />`, container)
    await flushUi()

    expect(container.textContent).not.toContain('도구 호출')
    expect(container.textContent).not.toContain('호출')
  }, 15000)

  it('hides the panel when tool_calls is 0', async () => {
    serverStatus.value = {
      tool_call_health: {
        window_hours: 1,
        tool_calls: 0,
        failures: 0,
        failure_rate: 0,
        since_epoch: 1711454400,
      },
    }

    const { Overview } = await loadOverview()
    render(html`<${Overview} />`, container)
    await flushUi()

    expect(container.textContent).not.toContain('도구 호출')
  }, 15000)

  it('shows the panel with correct counts and failure rate when tool_calls > 0', async () => {
    serverStatus.value = {
      tool_call_health: {
        window_hours: 1,
        tool_calls: 42,
        failures: 3,
        failure_rate: 0.0714,
        since_epoch: 1711454400,
      },
    }

    const { Overview } = await loadOverview()
    render(html`<${Overview} />`, container)
    await flushUi()

    expect(container.textContent).toContain('도구 호출')
    expect(container.textContent).toContain('42')
    expect(container.textContent).toContain('3')
    expect(container.textContent).toContain('7.1%')
  }, 15000)

  it('shows 0.0% failure rate when there are no failures', async () => {
    serverStatus.value = {
      tool_call_health: {
        window_hours: 1,
        tool_calls: 10,
        failures: 0,
        failure_rate: 0,
        since_epoch: 1711454400,
      },
    }

    const { Overview } = await loadOverview()
    render(html`<${Overview} />`, container)
    await flushUi()

    expect(container.textContent).toContain('도구 호출')
    expect(container.textContent).toContain('10')
    expect(container.textContent).toContain('0.0%')
  }, 15000)
})
