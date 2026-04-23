import { html } from 'htm/preact'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import * as Vitest from 'vitest'
import type { DashboardGovernanceResponse, GovernanceCaseBundle, KeeperApprovalQueueItem } from '../types'
import { filterApprovalQueue } from './governance'

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

    expect(container.textContent).toContain('judge-only / 최근 판단 0건')
    expect(container.textContent).toContain('Judge 상태')
    expect(container.textContent).toContain('Judge 모델')
    expect(container.textContent).toContain('Live Judge')
    expect(container.textContent).toContain('새로고침')
    expect(container.querySelector('[data-testid="governance-retired-banner"]')).toBeNull()
    expect(container.textContent).not.toContain('retired')
    expect(container.textContent).not.toContain('(retired)')
    expect(container.textContent).not.toContain('Case Load Visualized')
    expect(container.textContent).not.toContain('청원 콘솔')
    expect(container.textContent).not.toContain('사건 수신함')
    expect(container.textContent).not.toContain('심의 의견 제출')
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
      expect(container.textContent).toContain('30초 자동 갱신')

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
      fetchGovernanceCaseStatus: Vitest.vi.fn().mockResolvedValue(governanceBundle()),
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
      fetchGovernanceCaseStatus: Vitest.vi.fn().mockResolvedValue(governanceBundle()),
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
      fetchGovernanceCaseStatus: Vitest.vi.fn().mockResolvedValue(governanceBundle()),
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
    expect(empty?.textContent).toContain('AI Judge 오프라인')
    expect(empty?.textContent).toContain('governance-judge')
    expect(empty?.textContent).toContain('qwen3.5:35b')
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
    expect(empty?.textContent).toContain('새 입력 대기')
    expect(empty?.textContent).toContain('마지막 판단')
    expect(empty?.textContent).not.toContain('오프라인')
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
    expect(empty?.textContent).toContain('AI Judge 오프라인')
    expect(empty?.textContent).toContain('keeper 기동 여부')
    expect(empty?.textContent).toContain('governance-judge')
    expect(empty?.textContent).toContain('qwen3.5:35b')
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
    expect(empty?.textContent).toContain('위험도 threshold를 넘는 tool call이 없습니다')
    expect(empty?.textContent).toContain('시스템이 정상 작동 중')
    expect(empty?.textContent).toContain('마지막 judge 활동')
    expect(empty?.textContent).not.toContain('오프라인')
  }, 20000)
})

describe('filterApprovalQueue', () => {
  function makeItem(overrides: Partial<KeeperApprovalQueueItem> = {}): KeeperApprovalQueueItem {
    return {
      id: 'approval-x',
      keeper_name: 'keeper-x',
      tool_name: 'shell',
      risk_level: 'medium',
      requested_at: null,
      waiting_s: 0,
      ...overrides,
    }
  }

  const items: readonly KeeperApprovalQueueItem[] = [
    makeItem({ id: 'a', keeper_name: 'keeper-alpha', tool_name: 'shell', risk_level: 'critical' }),
    makeItem({ id: 'b', keeper_name: 'keeper-beta', tool_name: 'fs_write', risk_level: 'high' }),
    makeItem({ id: 'c', keeper_name: 'watcher-gamma', tool_name: 'shell', risk_level: 'medium' }),
    makeItem({ id: 'd', keeper_name: 'watcher-delta', tool_name: 'http_fetch', risk_level: 'low' }),
  ]

  it('returns the input reference when query is empty', () => {
    expect(filterApprovalQueue(items, '')).toBe(items)
  })

  it('returns the input reference for whitespace-only query', () => {
    expect(filterApprovalQueue(items, '   ')).toBe(items)
  })

  it('matches by keeper_name substring (case-insensitive)', () => {
    const result = filterApprovalQueue(items, 'KEEPER')
    expect(result.map(item => item.id)).toEqual(['a', 'b'])
  })

  it('matches by tool_name substring', () => {
    const result = filterApprovalQueue(items, 'shell')
    expect(result.map(item => item.id)).toEqual(['a', 'c'])
  })

  it('matches by risk_level substring', () => {
    const result = filterApprovalQueue(items, 'critical')
    expect(result.map(item => item.id)).toEqual(['a'])
  })

  it('returns empty when no field matches', () => {
    expect(filterApprovalQueue(items, 'nonexistent-token')).toHaveLength(0)
  })

  it('trims query before matching', () => {
    expect(filterApprovalQueue(items, '  alpha  ')).toHaveLength(1)
  })

  it('matches high risk level without matching "high" in other fields', () => {
    const result = filterApprovalQueue(items, 'high')
    expect(result.map(item => item.id)).toEqual(['b'])
  })

  it('does not mutate the input array', () => {
    const copy = items.slice()
    filterApprovalQueue(items, 'alpha')
    expect(items).toEqual(copy)
  })

  it('returns empty array for empty input with any query', () => {
    expect(filterApprovalQueue([], 'anything')).toHaveLength(0)
  })
})
