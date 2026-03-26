import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { DashboardGovernanceResponse, GovernanceCaseBundle } from '../types'

async function flushUi(): Promise<void> {
  for (let i = 0; i < 4; i += 1) {
    await Promise.resolve()
    await new Promise(resolve => setTimeout(resolve, 0))
  }
}

function governanceResponse(): DashboardGovernanceResponse {
  return {
    generated_at: '2026-03-24T00:00:00Z',
    summary: {
      cases_open: 1,
      pending_ruling: 1,
      ready_auto_execute: 0,
      needs_human_gate: 0,
      executed: 0,
      blocked: 0,
      oldest_open_case_age_s: 120,
      last_activity_age_s: 60,
      judge_online: true,
      judge_last_seen_at: '2026-03-24T00:00:00Z',
    },
    items: [
      {
        kind: 'case',
        id: 'gov-case-1',
        topic: 'command:governance 렌더링 오류',
        status: 'pending_ruling',
        related_agents: [],
        evidence_refs: [],
        brief_count: 0,
        petition_count: 1,
        truth_summary: '렌더링 중 insertBefore 예외가 발생합니다.',
      },
    ],
    activity: [],
    pending_actions: [],
  }
}

function governanceBundle(): GovernanceCaseBundle {
  return {
    case: {
      id: 'gov-case-1',
      petition_ids: ['petition-1'],
      title: 'command:governance 렌더링 오류',
      status: 'pending_ruling',
      source_refs: [],
      briefs: [],
    },
    petitions: [
      {
        id: 'petition-1',
        case_id: 'gov-case-1',
        title: 'command:governance 렌더링 오류',
        source_refs: [],
      },
    ],
    ruling: null,
    execution_order: null,
  }
}

async function loadComponentWithApi(api: {
  decideGovernanceExecutionOrder: () => Promise<void>
  fetchDashboardGovernance: () => Promise<DashboardGovernanceResponse>
  fetchGovernanceCaseStatus: (caseId: string) => Promise<GovernanceCaseBundle>
  fetchRuntimeParams: () => Promise<{ parameters: []; surfaces: [] }>
  submitGovernanceCaseBrief: () => Promise<GovernanceCaseBundle>
  submitGovernancePetition: () => Promise<{ case: { id: string } }>
}) {
  vi.resetModules()
  vi.doMock('../api', () => api)
  vi.doMock('../sse-store', () => ({
    registerGovernanceRefresh: vi.fn(),
  }))
  return import('./governance')
}

describe('Governance surface', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.resetModules()
    vi.clearAllMocks()
    vi.doUnmock('../api')
    vi.doUnmock('../sse-store')
  })

  it('renders and refreshes without corrupting the DOM tree', async () => {
    const fetchDashboardGovernance = vi.fn<() => Promise<DashboardGovernanceResponse>>()
      .mockResolvedValue(governanceResponse())
    const fetchGovernanceCaseStatus = vi.fn<(caseId: string) => Promise<GovernanceCaseBundle>>()
      .mockResolvedValue(governanceBundle())

    const { Governance } = await loadComponentWithApi({
      decideGovernanceExecutionOrder: vi.fn().mockResolvedValue(undefined),
      fetchDashboardGovernance,
      fetchGovernanceCaseStatus,
      fetchRuntimeParams: vi.fn().mockResolvedValue({ parameters: [], surfaces: [] }),
      submitGovernanceCaseBrief: vi.fn().mockResolvedValue(governanceBundle()),
      submitGovernancePetition: vi.fn().mockResolvedValue({ case: { id: 'gov-case-1' } }),
    })

    expect(() => {
      render(html`<${Governance} />`, container)
    }).not.toThrow()

    await flushUi()

    expect(container.textContent).toContain('거버넌스')
    expect(container.textContent).toContain('command:governance 렌더링 오류')
    expect(fetchDashboardGovernance).toHaveBeenCalledTimes(1)
    expect(fetchGovernanceCaseStatus).toHaveBeenCalledWith('gov-case-1')

    const refreshButton = Array.from(container.querySelectorAll('button'))
      .find(button => button.textContent?.includes('새로고침'))
    refreshButton?.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flushUi()

    expect(fetchDashboardGovernance).toHaveBeenCalledTimes(2)
    expect(fetchGovernanceCaseStatus.mock.calls.filter(([caseId]) => caseId === 'gov-case-1').length)
      .toBeGreaterThanOrEqual(2)
    expect(container.textContent).toContain('command:governance 렌더링 오류')
  }, 20000)

  it('shows keeper guidance when governance feed is empty', async () => {
    const emptyResponse: DashboardGovernanceResponse = {
      generated_at: '2026-03-26T00:00:00Z',
      summary: {
        cases_open: 0,
        pending_ruling: 0,
        ready_auto_execute: 0,
        needs_human_gate: 0,
        executed: 0,
      },
      items: [],
      activity: [],
      pending_actions: [],
    }

    const { Governance } = await loadComponentWithApi({
      decideGovernanceExecutionOrder: vi.fn().mockResolvedValue(undefined),
      fetchDashboardGovernance: vi.fn().mockResolvedValue(emptyResponse),
      fetchGovernanceCaseStatus: vi.fn().mockResolvedValue(governanceBundle()),
      fetchRuntimeParams: vi.fn().mockResolvedValue({ parameters: [], surfaces: [] }),
      submitGovernanceCaseBrief: vi.fn().mockResolvedValue(governanceBundle()),
      submitGovernancePetition: vi.fn().mockResolvedValue({ case: { id: 'gov-case-1' } }),
    })

    render(html`<${Governance} />`, container)
    await flushUi()

    expect(container.textContent).toContain('keeper가 활동 중일 때 자동 생성됩니다')
  }, 20000)

  it('shows last activity age when governance feed is empty but has past activity', async () => {
    const emptyWithAge: DashboardGovernanceResponse = {
      generated_at: '2026-03-26T00:00:00Z',
      summary: {
        cases_open: 0,
        pending_ruling: 0,
        ready_auto_execute: 0,
        needs_human_gate: 0,
        executed: 0,
        last_activity_age_s: 7200,
      },
      items: [],
      activity: [],
      pending_actions: [],
    }

    const { Governance } = await loadComponentWithApi({
      decideGovernanceExecutionOrder: vi.fn().mockResolvedValue(undefined),
      fetchDashboardGovernance: vi.fn().mockResolvedValue(emptyWithAge),
      fetchGovernanceCaseStatus: vi.fn().mockResolvedValue(governanceBundle()),
      fetchRuntimeParams: vi.fn().mockResolvedValue({ parameters: [], surfaces: [] }),
      submitGovernanceCaseBrief: vi.fn().mockResolvedValue(governanceBundle()),
      submitGovernancePetition: vi.fn().mockResolvedValue({ case: { id: 'gov-case-1' } }),
    })

    render(html`<${Governance} />`, container)
    await flushUi()

    expect(container.textContent).toContain('마지막 활동: 2시간 전')
    expect(container.textContent).toContain('keeper가 활동 중일 때 자동 생성됩니다')
  }, 20000)
})
