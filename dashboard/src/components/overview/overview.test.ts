import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const missionSnapshot = { value: null as Record<string, unknown> | null }
const missionLoading = { value: false }
const refreshMissionSnapshot = vi.fn().mockResolvedValue(undefined)

const roomTruth = { value: null as Record<string, unknown> | null }
const roomTruthLoading = { value: false }
const refreshRoomTruth = vi.fn().mockResolvedValue(undefined)

const topActiveAgents = { value: [] as unknown[] }
const navigate = vi.fn()
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
  vi.doMock('../../room-truth-store', () => ({
    roomTruth,
    roomTruthLoading,
    refreshRoomTruth,
  }))
  vi.doMock('../../observatory-store', () => ({
    topActiveAgents,
  }))
  vi.doMock('../../sse', () => ({
    journal: [],
    connected,
    eventCount,
    lastEvent,
  }))
  vi.doMock('../../router', () => ({
    navigate,
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
  return import('./overview')
}

describe('Overview freshness strip', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    vi.spyOn(Date, 'now').mockReturnValue(new Date('2026-03-26T12:10:00Z').getTime())
    container = document.createElement('div')
    document.body.appendChild(container)
    missionLoading.value = false
    roomTruthLoading.value = false
    topActiveAgents.value = []
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
    roomTruth.value = {
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
    vi.doUnmock('../../room-truth-store')
    vi.doUnmock('../../observatory-store')
    vi.doUnmock('../../sse')
    vi.doUnmock('../../router')
    vi.doUnmock('./situation-banner')
    vi.doUnmock('./attention-spotlight')
    vi.doUnmock('./narrative-timeline')
    vi.doUnmock('./agent-avatar')
    vi.doUnmock('../transport-health')
    vi.doUnmock('../perf-snapshot')
  })

  it('shows a stale warning when the oldest overview snapshot is over 5 minutes old', async () => {
    roomTruth.value = {
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

    expect(refreshRoomTruth).toHaveBeenCalledWith({ force: true })
    expect(refreshMissionSnapshot).toHaveBeenCalledWith({ force: true })
  }, 15000)
})
