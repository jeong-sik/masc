import { cleanup, fireEvent, render, screen, within } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { html } from 'htm/preact'

const api = vi.hoisted(() => ({
  fetchExactLaneRun: vi.fn(),
  fetchExactLaneRuns: vi.fn(),
  fetchVerificationRuns: vi.fn(),
  fetchFusionRuns: vi.fn(),
}))
const memoryApi = vi.hoisted(() => ({ fetchKeeperMemoryJournal: vi.fn() }))
const rawApi = vi.hoisted(() => ({
  fetchKeeperRawTrace: vi.fn(),
  fetchKeeperRawTraces: vi.fn(),
}))

vi.mock('../api/dashboard', () => api)
vi.mock('../api/dashboard-memory-journal', () => memoryApi)
vi.mock('../api/dashboard-keeper-prompt', () => rawApi)
vi.mock('../sse-store', () => ({
  registerInternalAgentRefresh: vi.fn(() => vi.fn()),
}))

import { InternalAgentsMonitor } from './internal-agents-monitor'
import { keepers, shellRuntimeResolution } from '../store'
import { ApiRequestError } from '../api/core'

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
  keepers.value = []
  shellRuntimeResolution.value = null
})

describe('InternalAgentsMonitor', () => {
  beforeEach(() => {
    rawApi.fetchKeeperRawTraces.mockResolvedValue([])
  })

  it('keeps paused keepers with zero observed runs in the owner matrix', async () => {
    api.fetchExactLaneRuns.mockResolvedValue({ runs: [], count: 0, total: 0, hasMore: false, generatedAt: 'now' })
    api.fetchFusionRuns.mockResolvedValue({ runs: [], count: 0, generatedAt: 'now' })
    api.fetchVerificationRuns.mockResolvedValue({ runs: [], count: 0, generatedAt: 'now' })
    shellRuntimeResolution.value = {
      fleet_safety: {
        paused_keepers_health: { names: ['full-cycle-probe'] },
      },
    } as typeof shellRuntimeResolution.value

    render(html`<${InternalAgentsMonitor} />`)

    const owner = await screen.findByRole('link', { name: 'full-cycle-probe' })
    expect(owner.closest('tr')?.textContent).toContain('없음')
    expect(screen.getByText('0 runs · 1 owners')).toBeTruthy()
  })

  it('expands a verification run and shows its ordered tool evidence', async () => {
    api.fetchExactLaneRuns.mockResolvedValue({ runs: [], count: 0, total: 0, hasMore: false, generatedAt: 'now' })
    api.fetchFusionRuns.mockResolvedValue({ runs: [], count: 0, generatedAt: 'now' })
    api.fetchVerificationRuns.mockResolvedValue({
      count: 1,
      generatedAt: 'now',
      runs: [{
        verificationId: 'vrf-1',
        taskId: 'task-1',
        producer: 'keeper-a',
        authorityKind: 'system_llm_agent',
        authorityActor: 'judge-1',
        startedAt: 1,
        status: 'approved',
        elapsedSeconds: 0.2,
        evaluatorRuntime: 'reviewer-runtime',
        tools: [{
          toolName: 'report_review_verdict',
          input: { verdict: 'APPROVE' },
          disposition: 'completed',
          outputExcerpt: 'Completion verdict recorded: APPROVE',
          outputTruncated: false,
          durationMs: 2,
          finishedAt: 1.15,
        }],
      }],
    })

    render(html`<${InternalAgentsMonitor} />`)
    const run = await screen.findByRole('button', { name: /Verification task-1/i })
    fireEvent.click(run)
    expect(await screen.findByText(/report_review_verdict/)).toBeTruthy()
    expect(screen.getByText(/Completion verdict recorded: APPROVE/)).toBeTruthy()

    const filters = screen.getByRole('group', { name: 'Internal agent filters' })
    fireEvent.click(within(filters).getByRole('button', { name: 'Auto Judge 0' }))
    expect(screen.queryByText('report_review_verdict')).toBeNull()
  })

  it('keeps Auto Judge and Board Attention as separate exact execution kinds', async () => {
    api.fetchFusionRuns.mockResolvedValue({ runs: [], count: 0, generatedAt: 'now' })
    api.fetchVerificationRuns.mockResolvedValue({ runs: [], count: 0, generatedAt: 'now' })
    api.fetchExactLaneRuns.mockResolvedValue({
      count: 2,
      total: 2,
      hasMore: false,
      generatedAt: 'now',
      runs: [
        {
          runId: 'auto-judge-1',
          lane: 'hitl_auto_judge',
          subjectId: 'approval-1',
          actor: 'keeper-a',
          startedAt: 1786000002,
          input: { kind: 'exact', payload: { approval_id: 'approval-1' } },
          status: 'succeeded',
          elapsedSeconds: 0.4,
          output: { decision: 'allow' },
        },
        {
          runId: 'board-attention-1',
          lane: 'board_attention_exact',
          subjectId: 'board-post-1',
          actor: 'keeper-a',
          startedAt: 1786000001,
          input: { kind: 'exact', payload: { post_id: 'board-post-1' } },
          status: 'succeeded',
          elapsedSeconds: 0.7,
          output: { action: 'reply' },
        },
      ],
    })

    const { container } = render(html`<${InternalAgentsMonitor} />`)
    const filters = await screen.findByRole('group', { name: 'Internal agent filters' })

    expect(within(filters).getByRole('button', { name: 'Auto Judge 1' })).toBeTruthy()
    expect(within(filters).getByRole('button', { name: 'Board Attention 1' })).toBeTruthy()
    expect(container.textContent).not.toContain('Board Judge')
    expect(container.querySelector('code[translate="no"]')).toBeNull()

    fireEvent.click(within(filters).getByRole('button', { name: 'Auto Judge 1' }))
    expect(screen.getByRole('button', { name: /Auto Judge approval-1/i })).toBeTruthy()
    expect(screen.queryByRole('button', { name: /Board Attention board-post-1/i })).toBeNull()

    fireEvent.click(within(filters).getByRole('button', { name: 'Board Attention 1' }))
    expect(screen.getByRole('button', { name: /Board Attention board-post-1/i })).toBeTruthy()
    expect(screen.queryByRole('button', { name: /Auto Judge approval-1/i })).toBeNull()
  })

  it('joins a librarian run to the exact memory revision and shows changed claims', async () => {
    api.fetchFusionRuns.mockResolvedValue({ runs: [], count: 0, generatedAt: 'now' })
    api.fetchVerificationRuns.mockResolvedValue({ runs: [], count: 0, generatedAt: 'now' })
    api.fetchExactLaneRuns.mockResolvedValue({
      count: 1,
      total: 1,
      hasMore: false,
      generatedAt: 'now',
      runs: [{
        runId: 'exact-lib-1',
        lane: 'librarian_exact',
        subjectId: 'trace-1',
        actor: 'kidsnote',
        startedAt: 1786000000,
        status: 'succeeded',
        elapsedSeconds: 2,
        selectedSlot: 'librarian-primary',
      }],
    })
    // The listing carries no payloads; opening the row is what fetches them.
    api.fetchExactLaneRun.mockResolvedValue({
      runId: 'exact-lib-1',
      lane: 'librarian_exact',
      subjectId: 'trace-1',
      actor: 'kidsnote',
      startedAt: 1786000000,
      status: 'succeeded',
      elapsedSeconds: 2,
      selectedSlot: 'librarian-primary',
      input: {
        kind: 'exact',
        payload: { current_fact_count: 1, message_count: 5 },
      },
      output: {
        before: { present: true, fact_count: 1 },
        after: {
          revision: 42,
          fact_count: 1,
          change: { added_count: 1, removed_count: 1, retained: 0 },
        },
      },
    })
    memoryApi.fetchKeeperMemoryJournal.mockResolvedValue({
      keeper: 'kidsnote',
      returned: 1,
      undecodableLines: 0,
      entries: [{
        ok: true,
        outcome: 'committed',
        recordedAt: 1786000002,
        revision: 42,
        traceId: 'trace-1',
        sourceKind: 'librarian',
        added: [{ claim: '새 기억', category: 'fact', firstSeen: 1786000001 }],
        removed: [{ claim: '낡은 기억', category: 'blocker', firstSeen: 1785000000 }],
        retained: 0,
        drops: [{ memoryId: 'sha256:old', reason: '새 근거로 대체됨' }],
      }],
    })

    const { container } = render(html`<${InternalAgentsMonitor} />`)
    const run = await screen.findByRole('button', { name: /Librarian trace-1/i })
    const runIdentity = container.querySelector('code[translate="no"]')
    expect(runIdentity?.textContent).toContain('run_id · exact-lib-1')
    expect(runIdentity?.getAttribute('title')).toBe('exact-lib-1')
    fireEvent.click(run)

    expect(await screen.findByText('추가된 기억 1건')).toBeTruthy()
    expect(container.textContent).toContain('revision 42')
    expect(container.textContent).toContain('새 기억')
    expect(container.textContent).toContain('낡은 기억')
    expect(container.textContent).toContain('새 근거로 대체됨')
    expect(container.textContent).toContain('TOOL-FREE')
    expect(container.textContent).toContain('선택 slot librarian-primary')
    expect(container.textContent).toContain('외부 research/RAW 입력을 받지 않습니다')
    expect(memoryApi.fetchKeeperMemoryJournal).toHaveBeenCalledWith(
      'kidsnote',
      500,
      expect.objectContaining({ signal: expect.any(AbortSignal) }),
    )
  })

  it('does not claim an explicit write as the librarian output for the same trace', async () => {
    api.fetchFusionRuns.mockResolvedValue({ runs: [], count: 0, generatedAt: 'now' })
    api.fetchVerificationRuns.mockResolvedValue({ runs: [], count: 0, generatedAt: 'now' })
    api.fetchExactLaneRuns.mockResolvedValue({
      count: 1,
      total: 1,
      hasMore: false,
      generatedAt: 'now',
      runs: [{
        runId: 'exact-lib-running',
        lane: 'librarian_exact',
        subjectId: 'trace-shared',
        actor: 'full-cycle-probe',
        startedAt: 1786200000,
        status: 'running',
      }],
    })
    api.fetchExactLaneRun.mockResolvedValue({
      runId: 'exact-lib-running',
      lane: 'librarian_exact',
      subjectId: 'trace-shared',
      actor: 'full-cycle-probe',
      startedAt: 1786200000,
      status: 'running',
      input: { kind: 'exact', payload: { current_fact_count: 2 } },
    })
    memoryApi.fetchKeeperMemoryJournal.mockResolvedValue({
      keeper: 'full-cycle-probe',
      returned: 1,
      undecodableLines: 0,
      entries: [{
        ok: true,
        outcome: 'committed',
        recordedAt: 1786202863,
        revision: 617,
        traceId: 'trace-shared',
        sourceKind: 'explicit_write',
        added: [{ claim: '실제 도구 체인 성공', category: 'fact', firstSeen: 1786202863 }],
        removed: [],
        retained: 2,
        drops: [],
      }],
    })

    const { container } = render(html`<${InternalAgentsMonitor} />`)
    fireEvent.click(await screen.findByRole('button', { name: /Librarian trace-shared/i }))

    expect(await screen.findByText('같은 trace · exact join 아님')).toBeTruthy()
    expect(container.textContent).toContain('정확히 조인되는 journal 행이 없습니다')
    expect(container.textContent).toContain('explicit_write')
    expect(container.textContent).toContain('revision 617')
    expect(container.textContent).toContain('실제 도구 체인 성공')
  })

  it('states that exact lanes and RAW require an Admin bearer', async () => {
    api.fetchExactLaneRuns.mockRejectedValue(new ApiRequestError({
      method: 'GET',
      path: '/api/v1/dashboard/exact-lane-runs',
      status: 403,
      statusText: 'Forbidden',
    }))
    api.fetchFusionRuns.mockResolvedValue({ runs: [], count: 0, generatedAt: 'now' })
    api.fetchVerificationRuns.mockResolvedValue({ runs: [], count: 0, generatedAt: 'now' })

    const { container } = render(html`<${InternalAgentsMonitor} />`)

    await vi.waitFor(() => {
      expect(container.textContent).toContain('Exact lanes + RAW: Admin 권한 필요')
    })
  })
})
