import { cleanup, fireEvent, render, screen, within } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { html } from 'htm/preact'

const api = vi.hoisted(() => ({
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
    api.fetchExactLaneRuns.mockResolvedValue({ runs: [], count: 0, generatedAt: 'now' })
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
    api.fetchExactLaneRuns.mockResolvedValue({ runs: [], count: 0, generatedAt: 'now' })
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
    fireEvent.click(within(filters).getByRole('button', { name: 'Judge 0' }))
    expect(screen.queryByText('report_review_verdict')).toBeNull()
  })

  it('joins a librarian run to the exact memory revision and shows changed claims', async () => {
    api.fetchFusionRuns.mockResolvedValue({ runs: [], count: 0, generatedAt: 'now' })
    api.fetchVerificationRuns.mockResolvedValue({ runs: [], count: 0, generatedAt: 'now' })
    api.fetchExactLaneRuns.mockResolvedValue({
      count: 1,
      generatedAt: 'now',
      runs: [{
        runId: 'exact-lib-1',
        lane: 'librarian_exact',
        subjectId: 'trace-1',
        actor: 'kidsnote',
        startedAt: 1786000000,
        input: {
          kind: 'research',
          rawTracePath: '/tmp/raw-traces/librarian-research-1.jsonl',
          payload: { current_fact_count: 1, message_count: 5 },
        },
        status: 'succeeded',
        elapsedSeconds: 2,
        output: {
          before: { facts: [{ claim: '낡은 기억' }] },
          after: {
            revision: 42,
            facts: [{ claim: '새 기억' }],
            change: { added: [{ claim: '새 기억' }], removed: [{ claim: '낡은 기억' }], retained: 0 },
          },
        },
      }],
    })
    rawApi.fetchKeeperRawTrace.mockResolvedValue({
      file: 'librarian-research-1.jsonl',
      totalRecords: 1,
      offset: 0,
      records: [{ ok: true, raw: '{"type":"tool_result","value":"실제 RAW 값"}', record: { type: 'tool_result', value: '실제 RAW 값' } }],
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
    fireEvent.click(run)

    expect(await screen.findByText('추가된 기억 1건')).toBeTruthy()
    expect(container.textContent).toContain('revision 42')
    expect(container.textContent).toContain('새 기억')
    expect(container.textContent).toContain('낡은 기억')
    expect(container.textContent).toContain('새 근거로 대체됨')
    expect(await screen.findByText('Retained RAW JSONL')).toBeTruthy()
    expect(container.textContent).toContain('실제 RAW 값')
    expect(container.textContent).toContain('Execution join')
    expect(container.textContent).not.toContain('TRACE JOIN UNAVAILABLE')
    expect(rawApi.fetchKeeperRawTrace).toHaveBeenCalledWith(
      'kidsnote',
      'librarian-research-1.jsonl',
      expect.objectContaining({ signal: expect.any(AbortSignal), offset: 0, limit: 20 }),
    )
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
      generatedAt: 'now',
      runs: [{
        runId: 'exact-lib-running',
        lane: 'librarian_exact',
        subjectId: 'trace-shared',
        actor: 'full-cycle-probe',
        startedAt: 1786200000,
        input: { kind: 'research', rawTracePath: null, payload: { current_fact_count: 2 } },
        status: 'running',
      }],
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

  it('does not fetch a pre-registered trace candidate when sink creation failed', async () => {
    api.fetchFusionRuns.mockResolvedValue({ runs: [], count: 0, generatedAt: 'now' })
    api.fetchVerificationRuns.mockResolvedValue({ runs: [], count: 0, generatedAt: 'now' })
    api.fetchExactLaneRuns.mockResolvedValue({
      count: 1,
      generatedAt: 'now',
      runs: [{
        runId: 'librarian-research-unavailable',
        lane: 'librarian_exact',
        subjectId: 'trace-unavailable',
        actor: 'rondo',
        startedAt: 1786200000,
        input: {
          kind: 'research',
          rawTracePath: '/tmp/raw-traces/candidate.jsonl',
          payload: { message_count: 1 },
        },
        status: 'failed',
        elapsedSeconds: 0.1,
        output: {
          research: {
            outcome: { kind: 'not_dispatched' },
            raw_trace: { kind: 'unavailable', detail: 'sink create failed' },
          },
        },
        code: 'librarian_failed',
        detail: 'sink create failed',
      }],
    })
    memoryApi.fetchKeeperMemoryJournal.mockResolvedValue({
      keeper: 'rondo', returned: 0, undecodableLines: 0, entries: [],
    })

    render(html`<${InternalAgentsMonitor} />`)
    fireEvent.click(await screen.findByRole('button', { name: /Librarian trace-unavailable/i }))

    expect(await screen.findByText('RAW trace unavailable')).toBeTruthy()
    expect(rawApi.fetchKeeperRawTrace).not.toHaveBeenCalled()
  })
})
