import { html } from 'htm/preact'
import { render } from 'preact'
import * as Vitest from 'vitest'
import type { DashboardGovernanceResponse, GovernanceCaseBundle } from '../types'

const { afterEach, beforeEach, describe, expect, it } = Vitest

Vitest.vi.mock('./governance-panels', () => ({
  DecisionDetail: () => html`<div data-testid="decision-detail-stub">decision detail</div>`,
  GuardrailPane: () => html`<div data-testid="guardrail-pane-stub">guardrail pane</div>`,
}))

const GOVERNANCE_RENDER_TIMEOUT_MS = 30000

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
  fetchParamAudit: (limit?: number) => Promise<{ entries: [] }>
  fetchGovernanceCaseStatus: (caseId: string) => Promise<GovernanceCaseBundle>
  fetchRuntimeParams: () => Promise<{ parameters: []; surfaces: [] }>
  resolveGovernanceApproval: (id: string, decision: 'approve' | 'reject', reason?: string) => Promise<{ ok: boolean; id: string; decision: 'approve' | 'reject' }>
  submitGovernanceCaseBrief: () => Promise<GovernanceCaseBundle>
  submitGovernancePetition: () => Promise<{ case: { id: string } }>
}) {
  Vitest.vi.resetModules()
  Vitest.vi.doMock('../api', () => api)
  Vitest.vi.doMock('../sse-store', () => ({
    registerGovernanceRefresh: Vitest.vi.fn(),
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
    Vitest.vi.resetModules()
    Vitest.vi.clearAllMocks()
    Vitest.vi.doUnmock('../api')
    Vitest.vi.doUnmock('../sse-store')
  })

  it('renders and refreshes without corrupting the DOM tree', async () => {
    const fetchDashboardGovernance = Vitest.vi.fn<() => Promise<DashboardGovernanceResponse>>()
      .mockResolvedValue(governanceResponse())
    const fetchGovernanceCaseStatus = Vitest.vi.fn<(caseId: string) => Promise<GovernanceCaseBundle>>()
      .mockResolvedValue(governanceBundle())

    const { Governance } = await loadComponentWithApi({
      decideGovernanceExecutionOrder: Vitest.vi.fn().mockResolvedValue(undefined),
      fetchDashboardGovernance,
      fetchParamAudit: Vitest.vi.fn().mockResolvedValue({ entries: [] }),
      fetchGovernanceCaseStatus,
      fetchRuntimeParams: Vitest.vi.fn().mockResolvedValue({ parameters: [], surfaces: [] }),
      resolveGovernanceApproval: Vitest.vi.fn().mockResolvedValue({ ok: true, id: 'appr-1', decision: 'approve' }),
      submitGovernanceCaseBrief: Vitest.vi.fn().mockResolvedValue(governanceBundle()),
      submitGovernancePetition: Vitest.vi.fn().mockResolvedValue({ case: { id: 'gov-case-1' } }),
    })

    expect(() => {
      render(html`<${Governance} />`, container)
    }).not.toThrow()

    await flushUi()

    expect(container.textContent).toContain('거버넌스')
    expect(container.textContent).toContain('Case Load Visualized')
    expect(container.textContent).toContain('Case Status Mix')
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
  }, GOVERNANCE_RENDER_TIMEOUT_MS)

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
      decideGovernanceExecutionOrder: Vitest.vi.fn().mockResolvedValue(undefined),
      fetchDashboardGovernance: Vitest.vi.fn().mockResolvedValue(emptyResponse),
      fetchParamAudit: Vitest.vi.fn().mockResolvedValue({ entries: [] }),
      fetchGovernanceCaseStatus: Vitest.vi.fn().mockResolvedValue(governanceBundle()),
      fetchRuntimeParams: Vitest.vi.fn().mockResolvedValue({ parameters: [], surfaces: [] }),
      resolveGovernanceApproval: Vitest.vi.fn().mockResolvedValue({ ok: true, id: 'appr-1', decision: 'approve' }),
      submitGovernanceCaseBrief: Vitest.vi.fn().mockResolvedValue(governanceBundle()),
      submitGovernancePetition: Vitest.vi.fn().mockResolvedValue({ case: { id: 'gov-case-1' } }),
    })

    render(html`<${Governance} />`, container)
    await flushUi()

    expect(container.textContent).toContain('keeper가 활동 중일 때 자동 생성됩니다')
    // No approval queue items → banner must stay hidden so it's not noisy.
    expect(container.querySelector('[data-testid="keeper-hitl-alert-banner"]')).toBeNull()
  }, 20000)

  it('shows retired guidance when case tracking is disabled', async () => {
    const serverNote = 'Server says governance case tracking is retired; only live judge signals remain.'
    const retiredResponse: DashboardGovernanceResponse = {
      generated_at: '2026-03-26T00:00:00Z',
      case_tracking_available: false,
      note: serverNote,
      summary: {
        judge_online: false,
      },
      items: [],
      activity: [],
      judgments: [],
      pending_actions: [],
    }

    const { Governance } = await loadComponentWithApi({
      decideGovernanceExecutionOrder: Vitest.vi.fn().mockResolvedValue(undefined),
      fetchDashboardGovernance: Vitest.vi.fn().mockResolvedValue(retiredResponse),
      fetchParamAudit: Vitest.vi.fn().mockResolvedValue({ entries: [] }),
      fetchGovernanceCaseStatus: Vitest.vi.fn().mockResolvedValue(governanceBundle()),
      fetchRuntimeParams: Vitest.vi.fn().mockResolvedValue({ parameters: [], surfaces: [] }),
      resolveGovernanceApproval: Vitest.vi.fn().mockResolvedValue({ ok: true, id: 'appr-1', decision: 'approve' }),
      submitGovernanceCaseBrief: Vitest.vi.fn().mockResolvedValue(governanceBundle()),
      submitGovernancePetition: Vitest.vi.fn().mockResolvedValue({ case: { id: 'gov-case-1' } }),
    })

    render(html`<${Governance} />`, container)
    await flushUi()

    expect(container.textContent).toContain(serverNote)
    expect(container.textContent).toContain('judge-only / 최근 판단 0건')
    expect(container.textContent).toContain('Judge 상태')
    expect(container.textContent).toContain('Judge 모델')
    expect(container.textContent).toContain('Live Judge')
    expect(container.textContent).toContain('새로고침')
    expect(container.textContent).not.toContain('keeper가 활동 중일 때 자동 생성됩니다')
    expect(container.textContent).not.toContain('Case Load Visualized')
    expect(container.textContent).not.toContain('청원 콘솔')
    expect(container.textContent).not.toContain('사건 수신함')
    expect(container.textContent).not.toContain('심의 의견 제출')
  }, 20000)

  it('renders judgments section with recommended action', async () => {
    const withJudgments: DashboardGovernanceResponse = {
      generated_at: '2026-03-30T00:00:00Z',
      summary: { cases_open: 0, pending_ruling: 0, ready_auto_execute: 0, needs_human_gate: 0, executed: 0 },
      items: [],
      activity: [],
      judge: { judge_online: true, model_used: 'llama:qwen3.5', keeper_name: 'governance-judge' },
      judgments: [
        {
          judgment_id: 'j-1',
          target_kind: 'agent_health',
          target_id: 'dreamer',
          summary: 'Agent dreamer has been zombie for 30 minutes.',
          confidence: 0.85,
          generated_at: '2026-03-30T00:00:00Z',
          recommended_action: { action_kind: 'recover', resolved_tool: 'masc_operator_confirm', reason: 'zombie agent detected' },
          guardrail_state: { requires_human_gate: true, ready_to_execute: false },
        },
      ],
      pending_actions: [],
    }

    const { Governance } = await loadComponentWithApi({
      decideGovernanceExecutionOrder: Vitest.vi.fn().mockResolvedValue(undefined),
      fetchDashboardGovernance: Vitest.vi.fn().mockResolvedValue(withJudgments),
      fetchParamAudit: Vitest.vi.fn().mockResolvedValue({ entries: [] }),
      fetchGovernanceCaseStatus: Vitest.vi.fn().mockResolvedValue(governanceBundle()),
      fetchRuntimeParams: Vitest.vi.fn().mockResolvedValue({ parameters: [], surfaces: [] }),
      resolveGovernanceApproval: Vitest.vi.fn().mockResolvedValue({ ok: true, id: 'appr-1', decision: 'approve' }),
      submitGovernanceCaseBrief: Vitest.vi.fn().mockResolvedValue(governanceBundle()),
      submitGovernancePetition: Vitest.vi.fn().mockResolvedValue({ case: { id: 'gov-case-1' } }),
    })

    render(html`<${Governance} />`, container)
    await flushUi()

    expect(container.textContent).toContain('AI Judge')
    expect(container.textContent).toContain('agent_health')
    expect(container.textContent).toContain('dreamer')
    expect(container.textContent).toContain('85%')
    expect(container.textContent).toContain('recover')
    expect(container.textContent).toContain('masc_operator_confirm')
    expect(container.textContent).toContain('승인 필요')
    expect(container.textContent).toContain('zombie agent detected')

    const judgeStatus = container.querySelector('[data-testid="judge-status"]')
    expect(judgeStatus).toBeTruthy()
    expect(judgeStatus?.textContent).toContain('온라인')
    expect(judgeStatus?.textContent).toContain('llama:qwen3.5')
  }, 20000)

  it('shows judge offline with error', async () => {
    const offlineJudge: DashboardGovernanceResponse = {
      generated_at: '2026-03-30T00:00:00Z',
      summary: { cases_open: 0, pending_ruling: 0, ready_auto_execute: 0, needs_human_gate: 0, executed: 0 },
      items: [],
      activity: [],
      judge: { judge_online: false, last_error: 'cascade failed: no models available', keeper_name: 'governance-judge' },
      judgments: [],
      pending_actions: [],
    }

    const { Governance } = await loadComponentWithApi({
      decideGovernanceExecutionOrder: Vitest.vi.fn().mockResolvedValue(undefined),
      fetchDashboardGovernance: Vitest.vi.fn().mockResolvedValue(offlineJudge),
      fetchParamAudit: Vitest.vi.fn().mockResolvedValue({ entries: [] }),
      fetchGovernanceCaseStatus: Vitest.vi.fn().mockResolvedValue(governanceBundle()),
      fetchRuntimeParams: Vitest.vi.fn().mockResolvedValue({ parameters: [], surfaces: [] }),
      resolveGovernanceApproval: Vitest.vi.fn().mockResolvedValue({ ok: true, id: 'appr-1', decision: 'approve' }),
      submitGovernanceCaseBrief: Vitest.vi.fn().mockResolvedValue(governanceBundle()),
      submitGovernancePetition: Vitest.vi.fn().mockResolvedValue({ case: { id: 'gov-case-1' } }),
    })

    render(html`<${Governance} />`, container)
    await flushUi()

    const judgeStatus = container.querySelector('[data-testid="judge-status"]')
    expect(judgeStatus).toBeTruthy()
    expect(judgeStatus?.textContent).toContain('오류')
    expect(judgeStatus?.textContent).toContain('cascade failed')
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
      decideGovernanceExecutionOrder: Vitest.vi.fn().mockResolvedValue(undefined),
      fetchDashboardGovernance: Vitest.vi.fn().mockResolvedValue(emptyWithAge),
      fetchParamAudit: Vitest.vi.fn().mockResolvedValue({ entries: [] }),
      fetchGovernanceCaseStatus: Vitest.vi.fn().mockResolvedValue(governanceBundle()),
      fetchRuntimeParams: Vitest.vi.fn().mockResolvedValue({ parameters: [], surfaces: [] }),
      resolveGovernanceApproval: Vitest.vi.fn().mockResolvedValue({ ok: true, id: 'appr-1', decision: 'approve' }),
      submitGovernanceCaseBrief: Vitest.vi.fn().mockResolvedValue(governanceBundle()),
      submitGovernancePetition: Vitest.vi.fn().mockResolvedValue({ case: { id: 'gov-case-1' } }),
    })

    render(html`<${Governance} />`, container)
    await flushUi()

    expect(container.textContent).toContain('마지막 활동: 2시간 전')
    expect(container.textContent).toContain('keeper가 활동 중일 때 자동 생성됩니다')
  }, 20000)

  it('renders keeper approval queue and resolves approval from the dashboard', async () => {
    const withApprovalQueue: DashboardGovernanceResponse = {
      generated_at: '2026-04-09T00:00:00Z',
      case_tracking_available: false,
      note: 'Live judge surface with active keeper approval queue.',
      summary: {
        cases_open: 0,
        pending_ruling: 0,
        ready_auto_execute: 0,
        needs_human_gate: 1,
        executed: 0,
      },
      items: [],
      activity: [],
      judgments: [],
      pending_actions: [],
      approval_queue: [
        {
          id: 'appr-1',
          keeper_name: 'governance-judge',
          tool_name: 'masc_code_delete',
          risk_level: 'critical',
          requested_at: '2026-04-09T00:00:00Z',
          waiting_s: 18,
          input: { path: '/tmp/danger' },
          input_preview: '{"path":"/tmp/danger"}',
        },
      ],
    }

    const resolveGovernanceApproval = Vitest.vi.fn<(id: string, decision: 'approve' | 'reject', reason?: string) => Promise<{ ok: boolean; id: string; decision: 'approve' | 'reject' }>>()
      .mockResolvedValue({ ok: true, id: 'appr-1', decision: 'approve' })
    const fetchDashboardGovernance = Vitest.vi.fn<() => Promise<DashboardGovernanceResponse>>()
      .mockResolvedValue(withApprovalQueue)

    const { Governance } = await loadComponentWithApi({
      decideGovernanceExecutionOrder: Vitest.vi.fn().mockResolvedValue(undefined),
      fetchDashboardGovernance,
      fetchParamAudit: Vitest.vi.fn().mockResolvedValue({ entries: [] }),
      fetchGovernanceCaseStatus: Vitest.vi.fn().mockResolvedValue(governanceBundle()),
      fetchRuntimeParams: Vitest.vi.fn().mockResolvedValue({ parameters: [], surfaces: [] }),
      resolveGovernanceApproval,
      submitGovernanceCaseBrief: Vitest.vi.fn().mockResolvedValue(governanceBundle()),
      submitGovernancePetition: Vitest.vi.fn().mockResolvedValue({ case: { id: 'gov-case-1' } }),
    })

    render(html`<${Governance} />`, container)
    await flushUi()

    expect(container.textContent).toContain('Keeper HITL 승인 대기')
    expect(container.textContent).toContain('governance-judge')
    expect(container.textContent).toContain('masc_code_delete')
    expect(container.textContent).toContain('critical')
    expect(container.textContent).toContain('Approval Input')
    expect(container.textContent).toContain('관리자 승인 대기')
    expect(container.textContent).toContain('1')
    expect(container.textContent).toContain('새로고침')
    expect(container.textContent).not.toContain('Case Load Visualized')
    expect(container.textContent).not.toContain('청원 콘솔')

    // Prominent top banner must render when approval queue is non-empty.
    const banner = container.querySelector('[data-testid="keeper-hitl-alert-banner"]')
    expect(banner).not.toBeNull()
    expect(banner?.textContent).toContain('1건')
    expect(banner?.textContent).toContain('지금 검토')
    expect(banner?.textContent?.toLowerCase()).toContain('critical')

    // Banner precedes the summary strip so it can't be missed.
    const governanceRoot = container.firstElementChild as HTMLElement | null
    expect(governanceRoot?.firstElementChild).toBe(banner)

    // Anchor target on the HITL queue card exists so '지금 검토' can scroll to it.
    expect(container.querySelector('[data-testid="keeper-hitl-approval"]')).not.toBeNull()

    const approveButton = Array.from(container.querySelectorAll('button'))
      .find(button => button.textContent?.trim() === '승인')
    approveButton?.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flushUi()

    expect(resolveGovernanceApproval).toHaveBeenCalledWith('appr-1', 'approve')
    expect(fetchDashboardGovernance).toHaveBeenCalledTimes(2)
  }, 20000)

  it('renders live judge empty state with offline message when retired + judge offline', async () => {
    const retiredOffline: DashboardGovernanceResponse = {
      generated_at: '2026-04-17T00:00:00Z',
      case_tracking_available: false,
      summary: { cases_open: 0, pending_ruling: 0, ready_auto_execute: 0, needs_human_gate: 0, executed: 0 },
      items: [],
      activity: [],
      pending_actions: [],
      judgments: [],
      judge: { judge_online: false, keeper_name: 'governance-judge', model_used: 'qwen3.5:35b' },
    }

    const { Governance } = await loadComponentWithApi({
      decideGovernanceExecutionOrder: Vitest.vi.fn().mockResolvedValue(undefined),
      fetchDashboardGovernance: Vitest.vi.fn().mockResolvedValue(retiredOffline),
      fetchParamAudit: Vitest.vi.fn().mockResolvedValue({ entries: [] }),
      fetchGovernanceCaseStatus: Vitest.vi.fn().mockResolvedValue(governanceBundle()),
      fetchRuntimeParams: Vitest.vi.fn().mockResolvedValue({ parameters: [], surfaces: [] }),
      resolveGovernanceApproval: Vitest.vi.fn().mockResolvedValue({ ok: true, id: 'appr-1', decision: 'approve' }),
      submitGovernanceCaseBrief: Vitest.vi.fn().mockResolvedValue(governanceBundle()),
      submitGovernancePetition: Vitest.vi.fn().mockResolvedValue({ case: { id: 'gov-case-1' } }),
    })

    render(html`<${Governance} />`, container)
    await flushUi()

    const empty = container.querySelector('[data-testid="live-judge-empty"]')
    expect(empty).toBeTruthy()
    expect(empty?.textContent).toContain('AI Judge 오프라인')
    // Keeper name + model chip rendered even when offline so the operator knows which runtime is failing.
    expect(empty?.textContent).toContain('governance-judge')
    expect(empty?.textContent).toContain('qwen3.5:35b')
  }, 20000)

  it('renders live judge empty state with idle message when retired + judge online but no judgments', async () => {
    const retiredIdle: DashboardGovernanceResponse = {
      generated_at: '2026-04-17T00:00:00Z',
      case_tracking_available: false,
      summary: { cases_open: 0, pending_ruling: 0, ready_auto_execute: 0, needs_human_gate: 0, executed: 0, judge_online: true },
      items: [],
      activity: [],
      pending_actions: [],
      judgments: [],
      judge: {
        judge_online: true,
        keeper_name: 'governance-judge',
        generated_at: '2026-04-17T00:00:00Z',
      },
    }

    const { Governance } = await loadComponentWithApi({
      decideGovernanceExecutionOrder: Vitest.vi.fn().mockResolvedValue(undefined),
      fetchDashboardGovernance: Vitest.vi.fn().mockResolvedValue(retiredIdle),
      fetchParamAudit: Vitest.vi.fn().mockResolvedValue({ entries: [] }),
      fetchGovernanceCaseStatus: Vitest.vi.fn().mockResolvedValue(governanceBundle()),
      fetchRuntimeParams: Vitest.vi.fn().mockResolvedValue({ parameters: [], surfaces: [] }),
      resolveGovernanceApproval: Vitest.vi.fn().mockResolvedValue({ ok: true, id: 'appr-1', decision: 'approve' }),
      submitGovernanceCaseBrief: Vitest.vi.fn().mockResolvedValue(governanceBundle()),
      submitGovernancePetition: Vitest.vi.fn().mockResolvedValue({ case: { id: 'gov-case-1' } }),
    })

    render(html`<${Governance} />`, container)
    await flushUi()

    const empty = container.querySelector('[data-testid="live-judge-empty"]')
    expect(empty).toBeTruthy()
    expect(empty?.textContent).toContain('새 입력 대기')
    expect(empty?.textContent).toContain('마지막 판단')
    expect(empty?.textContent).not.toContain('오프라인')
  }, 20000)
})
