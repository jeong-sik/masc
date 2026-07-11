import { html } from 'htm/preact'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import * as Vitest from 'vitest'
import type { DashboardGovernanceResponse, GovernanceCaseBundle } from '../types'

const { afterEach, beforeEach, describe, expect, it, vi } = Vitest

async function flushUi(): Promise<void> {
  for (let i = 0; i < 4; i += 1) {
    await Promise.resolve()
    await new Promise(resolve => setTimeout(resolve, 0))
  }
}

async function flushUiWithFakeTimers(): Promise<void> {
  await act(async () => {
    for (let i = 0; i < 4; i += 1) {
      await Promise.resolve()
      await vi.advanceTimersByTimeAsync(0)
    }
  })
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
  resolveGovernanceApproval: (id: string, decision: 'approve' | 'reject', reason?: string) => Promise<{ ok: boolean; id: string; decision: 'approve' | 'reject' }>
  submitGovernanceCaseBrief: () => Promise<GovernanceCaseBundle>
  submitGovernancePetition: () => Promise<{ case: { id: string } }>
}) {
  Vitest.vi.resetModules()
  Vitest.vi.doMock('../api', () => api)
  Vitest.vi.doMock('../api/dashboard-governance', () => api)
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
    Vitest.vi.doUnmock('../api/dashboard-governance')
    Vitest.vi.doUnmock('../sse-store')
  })

  it('renders live judge surface without retired banner or case tracking controls', async () => {
    const response: DashboardGovernanceResponse = {
      generated_at: '2026-03-26T00:00:00Z',
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
      fetchDashboardGovernance: Vitest.vi.fn().mockResolvedValue(response),
      fetchGovernanceCaseStatus: Vitest.vi.fn().mockResolvedValue(governanceBundle()),
      resolveGovernanceApproval: Vitest.vi.fn().mockResolvedValue({ ok: true, id: 'appr-1', decision: 'approve' }),
      submitGovernanceCaseBrief: Vitest.vi.fn().mockResolvedValue(governanceBundle()),
      submitGovernancePetition: Vitest.vi.fn().mockResolvedValue({ case: { id: 'gov-case-1' } }),
    })

    render(html`<${Governance} />`, container)
    await flushUi()

    expect(container.textContent).toContain('judge-only / 0 recent judgments')
    expect(container.textContent).toContain('Judge Status')
    expect(container.textContent).toContain('Judge Runtime')
    expect(container.textContent).toContain('Live Judgment')
    expect(container.textContent).toContain('Refresh')
    expect(container.querySelector('[data-testid="governance-retired-banner"]')).toBeNull()
    expect(container.textContent).not.toContain('retired')
    expect(container.textContent).not.toContain('(retired)')
    expect(container.textContent).not.toContain('Case Load Visualized')
    expect(container.textContent).not.toContain('청원 콘솔')
    expect(container.textContent).not.toContain('사건 수신함')
    expect(container.textContent).not.toContain('심의 의견 제출')
  }, 20000)

  it('wraps the governance view in the v2 command surface class', async () => {
    const response: DashboardGovernanceResponse = {
      generated_at: '2026-03-26T00:00:00Z',
      summary: { judge_online: false },
      items: [],
      activity: [],
      judgments: [],
      pending_actions: [],
    }

    const { Governance } = await loadComponentWithApi({
      decideGovernanceExecutionOrder: Vitest.vi.fn().mockResolvedValue(undefined),
      fetchDashboardGovernance: Vitest.vi.fn().mockResolvedValue(response),
      fetchGovernanceCaseStatus: Vitest.vi.fn().mockResolvedValue(governanceBundle()),
      resolveGovernanceApproval: Vitest.vi.fn().mockResolvedValue({ ok: true, id: 'appr-1', decision: 'approve' }),
      submitGovernanceCaseBrief: Vitest.vi.fn().mockResolvedValue(governanceBundle()),
      submitGovernancePetition: Vitest.vi.fn().mockResolvedValue({ case: { id: 'gov-case-1' } }),
    })

    render(html`<${Governance} />`, container)
    await flushUi()

    expect(container.querySelector('.v2-command-surface')).not.toBeNull()
    expect(container.querySelector('.v2-command-panel')).not.toBeNull()
    expect(container.querySelector('.v2-command-toolbar')).not.toBeNull()
  }, 20000)

  it('marks raw banner panels with v2-command-panel', async () => {
    const response: DashboardGovernanceResponse = {
      generated_at: '2026-03-26T00:00:00Z',
      summary: {
        judge_online: false,
        oldest_open_case_age_s: 90000,
        last_activity_age_s: 90000,
      },
      items: [],
      activity: [],
      judgments: [],
      pending_actions: [],
      approval_queue: [
        {
          id: 'appr-1',
          keeper_name: 'governance-judge',
          tool_name: 'tool_edit_file',
          risk_level: 'critical',
          requested_at: '2026-03-26T00:00:00Z',
          waiting_s: 18,
        },
      ],
    }

    const { Governance } = await loadComponentWithApi({
      decideGovernanceExecutionOrder: Vitest.vi.fn().mockResolvedValue(undefined),
      fetchDashboardGovernance: Vitest.vi.fn().mockResolvedValue(response),
      fetchGovernanceCaseStatus: Vitest.vi.fn().mockResolvedValue(governanceBundle()),
      resolveGovernanceApproval: Vitest.vi.fn().mockResolvedValue({ ok: true, id: 'appr-1', decision: 'approve' }),
      submitGovernanceCaseBrief: Vitest.vi.fn().mockResolvedValue(governanceBundle()),
      submitGovernancePetition: Vitest.vi.fn().mockResolvedValue({ case: { id: 'gov-case-1' } }),
    })

    render(html`<${Governance} />`, container)
    await flushUi()

    expect(
      Array.from(container.querySelectorAll('.v2-command-panel')).some(
        el => el.textContent?.includes('All open cases are older than'),
      ),
    ).toBe(true)

    const hitlBanner = container.querySelector('[data-testid="keeper-hitl-alert-banner"]') as HTMLElement | null
    expect(hitlBanner?.classList.contains('v2-command-panel')).toBe(true)
  }, 20000)

  it('auto-refreshes the live judge surface while visible', async () => {
    const response: DashboardGovernanceResponse = {
      generated_at: '2026-04-21T00:00:00Z',
      summary: { judge_online: true },
      items: [],
      activity: [],
      judgments: [],
      pending_actions: [],
      judge: { judge_online: true, model_used: 'gemini', keeper_name: 'governance-judge' },
    }
    const originalVisibility = Object.getOwnPropertyDescriptor(Document.prototype, 'visibilityState')
    const fetchDashboardGovernance = vi.fn<() => Promise<DashboardGovernanceResponse>>()
      .mockResolvedValue(response)

    vi.useFakeTimers()
    Object.defineProperty(document, 'visibilityState', {
      configurable: true,
      get: () => 'visible',
    })

    try {
      const { Governance } = await loadComponentWithApi({
        decideGovernanceExecutionOrder: vi.fn().mockResolvedValue(undefined),
        fetchDashboardGovernance,
        fetchGovernanceCaseStatus: vi.fn().mockResolvedValue(governanceBundle()),
        resolveGovernanceApproval: vi.fn().mockResolvedValue({ ok: true, id: 'appr-1', decision: 'approve' }),
        submitGovernanceCaseBrief: vi.fn().mockResolvedValue(governanceBundle()),
        submitGovernancePetition: vi.fn().mockResolvedValue({ case: { id: 'gov-case-1' } }),
      })

      await act(async () => {
        render(html`<${Governance} />`, container)
        await Promise.resolve()
      })
      await flushUiWithFakeTimers()

      expect(fetchDashboardGovernance).toHaveBeenCalledTimes(1)
      expect(container.textContent).toContain('Auto-refresh 30s')

      await vi.advanceTimersByTimeAsync(30_000)
      await flushUiWithFakeTimers()

      expect(fetchDashboardGovernance).toHaveBeenCalledTimes(2)
    } finally {
      vi.clearAllTimers()
      vi.useRealTimers()
      if (originalVisibility) {
        Object.defineProperty(document, 'visibilityState', originalVisibility)
      }
    }
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
          target_id: 'alice',
          summary: 'Agent alice has been zombie for 30 minutes.',
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
      fetchGovernanceCaseStatus: Vitest.vi.fn().mockResolvedValue(governanceBundle()),
      resolveGovernanceApproval: Vitest.vi.fn().mockResolvedValue({ ok: true, id: 'appr-1', decision: 'approve' }),
      submitGovernanceCaseBrief: Vitest.vi.fn().mockResolvedValue(governanceBundle()),
      submitGovernancePetition: Vitest.vi.fn().mockResolvedValue({ case: { id: 'gov-case-1' } }),
    })

    render(html`<${Governance} />`, container)
    await flushUi()

    expect(container.textContent).toContain('AI Judge')
    expect(container.textContent).toContain('agent_health')
    expect(container.textContent).toContain('alice')
    expect(container.textContent).toContain('85%')
    expect(container.textContent).toContain('recover')
    expect(container.textContent).toContain('masc_operator_confirm')
    expect(container.textContent).toContain('Approval required')
    expect(container.textContent).toContain('zombie agent detected')

    const judgeStatus = container.querySelector('[data-testid="judge-status"]')
    expect(judgeStatus).toBeTruthy()
    expect(judgeStatus?.textContent).toContain('Online')
    expect(judgeStatus?.textContent).not.toContain('llama:qwen3.5')
  }, 20000)

  it('shows judge offline with error', async () => {
    const offlineJudge: DashboardGovernanceResponse = {
      generated_at: '2026-03-30T00:00:00Z',
      summary: { cases_open: 0, pending_ruling: 0, ready_auto_execute: 0, needs_human_gate: 0, executed: 0 },
      items: [],
      activity: [],
      judge: { judge_online: false, last_error: 'runtime failed: no models available', keeper_name: 'governance-judge' },
      judgments: [],
      pending_actions: [],
    }

    const { Governance } = await loadComponentWithApi({
      decideGovernanceExecutionOrder: Vitest.vi.fn().mockResolvedValue(undefined),
      fetchDashboardGovernance: Vitest.vi.fn().mockResolvedValue(offlineJudge),
      fetchGovernanceCaseStatus: Vitest.vi.fn().mockResolvedValue(governanceBundle()),
      resolveGovernanceApproval: Vitest.vi.fn().mockResolvedValue({ ok: true, id: 'appr-1', decision: 'approve' }),
      submitGovernanceCaseBrief: Vitest.vi.fn().mockResolvedValue(governanceBundle()),
      submitGovernancePetition: Vitest.vi.fn().mockResolvedValue({ case: { id: 'gov-case-1' } }),
    })

    render(html`<${Governance} />`, container)
    await flushUi()

    const judgeStatus = container.querySelector('[data-testid="judge-status"]')
    expect(judgeStatus).toBeTruthy()
    expect(judgeStatus?.textContent).toContain('Error')
    expect(judgeStatus?.textContent).toContain('runtime failed')
    expect(judgeStatus?.classList.contains('v2-command-panel')).toBe(true)
  }, 20000)

  it('renders stale-visible judge status without collapsing to offline error', async () => {
    const staleVisible: DashboardGovernanceResponse = {
      generated_at: '2026-04-23T00:00:00Z',
      summary: { cases_open: 0, pending_ruling: 0, ready_auto_execute: 0, needs_human_gate: 0, executed: 0 },
      items: [],
      activity: [],
      judge: {
        judge_online: true,
        refreshing: false,
        status: 'stale_visible',
        degraded_reason: 'timeout',
        cached_judgments_visible: true,
        last_error: 'Execution timed out after 60.0s',
        keeper_name: 'governance-judge',
        model_used: 'glm:test',
        generated_at: '2026-04-23T00:00:00Z',
      },
      judgments: [],
      pending_actions: [],
      approval_queue: [],
    }

    const { Governance } = await loadComponentWithApi({
      decideGovernanceExecutionOrder: Vitest.vi.fn().mockResolvedValue(undefined),
      fetchDashboardGovernance: Vitest.vi.fn().mockResolvedValue(staleVisible),
      fetchGovernanceCaseStatus: Vitest.vi.fn().mockResolvedValue(governanceBundle()),
      resolveGovernanceApproval: Vitest.vi.fn().mockResolvedValue({ ok: true, id: 'appr-1', decision: 'approve' }),
      submitGovernanceCaseBrief: Vitest.vi.fn().mockResolvedValue(governanceBundle()),
      submitGovernancePetition: Vitest.vi.fn().mockResolvedValue({ case: { id: 'gov-case-1' } }),
    })

    render(html`<${Governance} />`, container)
    await flushUi()

    const judgeStatus = container.querySelector('[data-testid="judge-status"]')
    expect(judgeStatus).toBeTruthy()
    expect(judgeStatus?.textContent).toContain('Using cache')
    expect(judgeStatus?.textContent).toContain('Execution timed out')
    expect(container.textContent).toContain('fresh-judgment cache')
    expect(container.textContent).not.toContain('AI Judge is offline')
  }, 20000)

  it('renders keeper approval queue and resolves approval from the dashboard', async () => {
    const withApprovalQueue: DashboardGovernanceResponse = {
      generated_at: '2026-04-09T00:00:00Z',
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
          tool_name: 'tool_edit_file',
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
      fetchGovernanceCaseStatus: Vitest.vi.fn().mockResolvedValue(governanceBundle()),
      resolveGovernanceApproval,
      submitGovernanceCaseBrief: Vitest.vi.fn().mockResolvedValue(governanceBundle()),
      submitGovernancePetition: Vitest.vi.fn().mockResolvedValue({ case: { id: 'gov-case-1' } }),
    })

    render(html`<${Governance} />`, container)
    await flushUi()

    expect(container.textContent).toContain('Keeper HITL Approval Queue')
    expect(container.textContent).toContain('governance-judge')
    expect(container.textContent).toContain('tool_edit_file')
    expect(container.textContent).toContain('critical')
    expect(container.textContent).toContain('Approval Input')
    expect(container.textContent).toContain('Admin Queue')
    expect(container.textContent).toContain('1')
    expect(container.textContent).toContain('Refresh')
    expect(container.textContent).not.toContain('Case Load Visualized')
    expect(container.textContent).not.toContain('청원 콘솔')

    // Prominent top banner must render when approval queue is non-empty.
    const banner = container.querySelector('[data-testid="keeper-hitl-alert-banner"]')
    expect(banner).not.toBeNull()
    expect(banner?.textContent).toContain('1')
    expect(banner?.textContent).toContain('Review now')
    expect(banner?.textContent?.toLowerCase()).toContain('critical')

    // Banner precedes the summary strip so it can't be missed.
    const governanceRoot = container.firstElementChild as HTMLElement | null
    expect(governanceRoot?.firstElementChild).toBe(banner)

    // Anchor target on the HITL queue card exists so "Review now" can scroll to it.
    expect(container.querySelector('[data-testid="keeper-hitl-approval"]')).not.toBeNull()

    const approveButton = Array.from(container.querySelectorAll('button'))
      .find(button => button.textContent?.trim() === 'Approve')
    approveButton?.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flushUi()

    expect(resolveGovernanceApproval).toHaveBeenCalledWith('appr-1', 'approve', false)
    expect(fetchDashboardGovernance).toHaveBeenCalledTimes(2)
  }, 20000)

  it('renders live judge empty state with offline message when retired + judge offline', async () => {
    const retiredOffline: DashboardGovernanceResponse = {
      generated_at: '2026-04-17T00:00:00Z',
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
      fetchGovernanceCaseStatus: Vitest.vi.fn().mockResolvedValue(governanceBundle()),
      resolveGovernanceApproval: Vitest.vi.fn().mockResolvedValue({ ok: true, id: 'appr-1', decision: 'approve' }),
      submitGovernanceCaseBrief: Vitest.vi.fn().mockResolvedValue(governanceBundle()),
      submitGovernancePetition: Vitest.vi.fn().mockResolvedValue({ case: { id: 'gov-case-1' } }),
    })

    render(html`<${Governance} />`, container)
    await flushUi()

    const empty = container.querySelector('[data-testid="live-judge-empty"]')
    expect(empty).toBeTruthy()
    expect(empty?.textContent).toContain('AI Judge is offline')
    expect(empty?.textContent).toContain('governance-judge')
    expect(empty?.textContent).not.toContain('qwen3.5:35b')
  }, 20000)

  it('renders live judge empty state with idle message when retired + judge online but no judgments', async () => {
    const retiredIdle: DashboardGovernanceResponse = {
      generated_at: '2026-04-17T00:00:00Z',
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
      fetchGovernanceCaseStatus: Vitest.vi.fn().mockResolvedValue(governanceBundle()),
      resolveGovernanceApproval: Vitest.vi.fn().mockResolvedValue({ ok: true, id: 'appr-1', decision: 'approve' }),
      submitGovernanceCaseBrief: Vitest.vi.fn().mockResolvedValue(governanceBundle()),
      submitGovernancePetition: Vitest.vi.fn().mockResolvedValue({ case: { id: 'gov-case-1' } }),
    })

    render(html`<${Governance} />`, container)
    await flushUi()

    const empty = container.querySelector('[data-testid="live-judge-empty"]')
    expect(empty).toBeTruthy()
    expect(empty?.textContent).toContain('Waiting for new input')
    expect(empty?.textContent).toContain('Last judgment')
    expect(empty?.textContent).not.toContain('Offline')
  }, 20000)

  it('renders keeper HITL empty state with judge-offline context when queue is empty and judge is offline', async () => {
    const hitlEmptyOffline: DashboardGovernanceResponse = {
      generated_at: '2026-04-17T00:00:00Z',
      summary: { cases_open: 0, pending_ruling: 0, ready_auto_execute: 0, needs_human_gate: 0, executed: 0, judge_online: false },
      items: [],
      activity: [],
      pending_actions: [],
      judgments: [],
      approval_queue: [],
      judge: { judge_online: false, keeper_name: 'governance-judge', model_used: 'qwen3.5:35b' },
    }

    const { Governance } = await loadComponentWithApi({
      decideGovernanceExecutionOrder: Vitest.vi.fn().mockResolvedValue(undefined),
      fetchDashboardGovernance: Vitest.vi.fn().mockResolvedValue(hitlEmptyOffline),
      fetchGovernanceCaseStatus: Vitest.vi.fn().mockResolvedValue(governanceBundle()),
      resolveGovernanceApproval: Vitest.vi.fn().mockResolvedValue({ ok: true, id: 'appr-1', decision: 'approve' }),
      submitGovernanceCaseBrief: Vitest.vi.fn().mockResolvedValue(governanceBundle()),
      submitGovernancePetition: Vitest.vi.fn().mockResolvedValue({ case: { id: 'gov-case-1' } }),
    })

    render(html`<${Governance} />`, container)
    await flushUi()

    const empty = container.querySelector('[data-testid="keeper-hitl-empty"]')
    expect(empty).toBeTruthy()
    expect(empty?.textContent).toContain('AI Judge is offline')
    expect(empty?.textContent).toContain('keeper is running')
    expect(empty?.textContent).toContain('governance-judge')
    expect(empty?.textContent).not.toContain('qwen3.5:35b')
  }, 20000)

  it('renders keeper HITL empty state with healthy-idle context when queue is empty and judge is active', async () => {
    const hitlEmptyHealthy: DashboardGovernanceResponse = {
      generated_at: '2026-04-17T00:00:00Z',
      summary: { cases_open: 0, pending_ruling: 0, ready_auto_execute: 0, needs_human_gate: 0, executed: 0, judge_online: true },
      items: [],
      activity: [],
      pending_actions: [],
      judgments: [],
      approval_queue: [],
      judge: {
        judge_online: true,
        keeper_name: 'governance-judge',
        generated_at: '2026-04-17T00:00:00Z',
      },
    }

    const { Governance } = await loadComponentWithApi({
      decideGovernanceExecutionOrder: Vitest.vi.fn().mockResolvedValue(undefined),
      fetchDashboardGovernance: Vitest.vi.fn().mockResolvedValue(hitlEmptyHealthy),
      fetchGovernanceCaseStatus: Vitest.vi.fn().mockResolvedValue(governanceBundle()),
      resolveGovernanceApproval: Vitest.vi.fn().mockResolvedValue({ ok: true, id: 'appr-1', decision: 'approve' }),
      submitGovernanceCaseBrief: Vitest.vi.fn().mockResolvedValue(governanceBundle()),
      submitGovernancePetition: Vitest.vi.fn().mockResolvedValue({ case: { id: 'gov-case-1' } }),
    })

    render(html`<${Governance} />`, container)
    await flushUi()

    const empty = container.querySelector('[data-testid="keeper-hitl-empty"]')
    expect(empty).toBeTruthy()
    expect(empty?.textContent).toContain('No tool calls exceed the risk threshold')
    expect(empty?.textContent).toContain('system is operating normally')
    expect(empty?.textContent).toContain('Last judge activity')
    expect(empty?.textContent).not.toContain('Offline')
  }, 20000)
})
