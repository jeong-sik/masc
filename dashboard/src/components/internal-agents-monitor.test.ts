import { cleanup, fireEvent, render, screen, within } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { html } from 'htm/preact'

const api = vi.hoisted(() => ({
  fetchExactLaneRun: vi.fn(),
  fetchExactLaneRuns: vi.fn(),
  fetchVerificationRuns: vi.fn(),
  fetchFusionRuns: vi.fn(),
  fetchStandaloneLanes: vi.fn(),
}))
const memoryApi = vi.hoisted(() => ({ fetchKeeperMemoryJournal: vi.fn() }))
const rawApi = vi.hoisted(() => ({
  fetchKeeperRawTrace: vi.fn(),
  fetchKeeperRawTraces: vi.fn(),
}))
const sse = vi.hoisted(() => ({ refresh: null as null | (() => void) }))

vi.mock('../api/dashboard', () => api)
vi.mock('../api/dashboard-memory-journal', () => memoryApi)
vi.mock('../api/dashboard-keeper-prompt', () => rawApi)
vi.mock('../sse-store', () => ({
  registerInternalAgentRefresh: vi.fn((refresh: () => void) => {
    sse.refresh = refresh
    return vi.fn()
  }),
}))

import {
  InternalAgentsMonitor,
  librarianInputEvidence,
  renderCapturedLibrarianPrompt,
} from './internal-agents-monitor'
import { keepers, shellRuntimeResolution } from '../store'
import { ApiRequestError } from '../api/core'

const journalFact = (claim: string, category: 'fact' | 'blocker', firstSeen: number) => ({
  claim,
  category,
  firstSeen,
  lastSeen: firstSeen,
  reinforcement: 0,
  origin: { kind: 'injected' as const, traceId: 'trace-1' },
  basis: { kind: 'observed' as const },
})

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
  keepers.value = []
  shellRuntimeResolution.value = null
  sse.refresh = null
})

describe('Librarian prompt evidence', () => {
  it('reconstructs the rendered prompt from the captured template and actual sections', () => {
    const evidence = librarianInputEvidence({
      message_count: 2,
      actual_input: {
        prompt: {
          key: 'librarian',
          source: 'override',
          file_path: '/config/prompts/librarian.md',
          effective_template: 'Memory={{ current_memory }}\nHistory={{conversation_history}}',
          rendered_bytes: 30,
          rendered_sha256: 'a'.repeat(64),
        },
        rendered_prompt_variables: {
          current_memory: '[m1] keep this',
          conversation_history: 'user: hello {{literal}}',
        },
      },
    })
    expect(evidence).not.toBeNull()
    expect(renderCapturedLibrarianPrompt(evidence!)).toBe(
      'Memory=[m1] keep this\nHistory=user: hello {{literal}}',
    )
    expect(evidence?.promptSource).toBe('override')
    expect(evidence?.messageCount).toBe(2)
  })
})

describe('InternalAgentsMonitor', () => {
  beforeEach(() => {
    rawApi.fetchKeeperRawTraces.mockResolvedValue([])
    api.fetchStandaloneLanes.mockResolvedValue({
      schema: 'masc.standalone_llm_lanes.v1',
      generatedAt: 'now',
      observedAtUnix: 1,
      observationOnly: true,
      exactRunProjectionCount: 0,
      exactRunSourceTotal: 0,
      exactRunProjectionTruncated: false,
      lanes: [],
    })
  })

  it('shows configured, running, and no-retained-observation lanes without controlling them', async () => {
    api.fetchExactLaneRuns.mockResolvedValue({ runs: [], count: 0, total: 0, hasMore: false, generatedAt: 'now' })
    api.fetchFusionRuns.mockResolvedValue({ runs: [], count: 0, generatedAt: 'now' })
    api.fetchVerificationRuns.mockResolvedValue({ runs: [], count: 0, generatedAt: 'now' })
    const lane = (overrides: Record<string, unknown>) => ({
      laneId: 'board_attention_exact',
      label: 'Board Attention',
      required: true,
      observationOnly: true,
      configured: true,
      configurationState: 'ready',
      admittedSlots: ['qwen3-5-cloud'],
      cliSlots: [],
      droppedSlots: [],
      admissionError: null,
      status: 'idle',
      retainedRunCount: 4,
      runningCount: 0,
      succeededCount: 4,
      failedCount: 0,
      cancelledCount: 0,
      lastStartedAt: 10,
      lastTerminalAt: 12,
      lastOutcome: 'succeeded',
      p50ElapsedSeconds: 2,
      selectedSlots: [{ slotId: 'qwen3-5-cloud', count: 4 }],
      ...overrides,
    })
    api.fetchStandaloneLanes.mockResolvedValue({
      schema: 'masc.standalone_llm_lanes.v1',
      generatedAt: 'now',
      observedAtUnix: 20,
      observationOnly: true,
      exactRunProjectionCount: 4,
      exactRunSourceTotal: 4,
      exactRunProjectionTruncated: false,
      lanes: [
        lane({ status: 'running', runningCount: 1 }),
        lane({ laneId: 'hitl_auto_judge', label: 'HITL Auto Judge' }),
        lane({ laneId: 'librarian_exact', label: 'Librarian', status: 'no_retained_observation', retainedRunCount: 0, lastStartedAt: null, lastTerminalAt: null, lastOutcome: null, p50ElapsedSeconds: null, selectedSlots: [] }),
        lane({ laneId: 'verifier_exact', label: 'Verifier', required: false }),
      ],
    })

    const { container } = render(html`<${InternalAgentsMonitor} />`)

    expect(await screen.findByText('READ-ONLY OBSERVATION')).toBeTruthy()
    const matrix = await screen.findByTestId('standalone-lane-matrix')
    expect(within(matrix).getAllByText('Running')).toHaveLength(2)
    expect(within(matrix).getAllByText('No retained observation')).toHaveLength(1)
    expect(container.textContent).toContain('qwen3-5-cloud ×4')
    expect(container.textContent).toContain('관측 기록 없음')
  })

  it('does not let an older refresh overwrite the latest lane matrix', async () => {
    api.fetchExactLaneRuns.mockResolvedValue({ runs: [], count: 0, total: 0, hasMore: false, generatedAt: 'now' })
    api.fetchFusionRuns.mockResolvedValue({ runs: [], count: 0, generatedAt: 'now' })
    api.fetchVerificationRuns.mockResolvedValue({ runs: [], count: 0, generatedAt: 'now' })
    let resolveOlder!: (value: unknown) => void
    const older = new Promise(resolve => { resolveOlder = resolve })
    const lane = (label: string) => ({
      laneId: 'board_attention_exact', label, required: true, observationOnly: true,
      configured: true, configurationState: 'ready', admittedSlots: ['primary'], cliSlots: [], droppedSlots: [],
      admissionError: null, status: 'idle', retainedRunCount: 1, runningCount: 0,
      succeededCount: 1, failedCount: 0, cancelledCount: 0, lastStartedAt: 10,
      lastTerminalAt: 11, lastOutcome: 'succeeded', p50ElapsedSeconds: 1,
      selectedSlots: [{ slotId: 'primary', count: 1 }],
    })
    const snapshot = (label: string) => ({
      schema: 'masc.standalone_llm_lanes.v1', generatedAt: 'now', observedAtUnix: 20,
      observationOnly: true, exactRunProjectionCount: 1, exactRunSourceTotal: 1,
      exactRunProjectionTruncated: false, lanes: [lane(label)],
    })
    api.fetchStandaloneLanes
      .mockImplementationOnce(() => older)
      .mockResolvedValueOnce(snapshot('Newest matrix'))

    render(html`<${InternalAgentsMonitor} />`)
    await vi.waitFor(() => expect(sse.refresh).not.toBeNull())
    sse.refresh?.()
    expect(await screen.findByText('Newest matrix')).toBeTruthy()
    resolveOlder(snapshot('Stale matrix'))
    await vi.waitFor(() => expect(screen.queryByText('Stale matrix')).toBeNull())
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
        payload: {
          current_fact_count: 1,
          message_count: 5,
          actual_input: {
            prompt: {
              key: 'librarian',
              source: 'file',
              file_path: '/config/prompts/librarian.md',
              effective_template: 'Current={{current_memory}}',
              rendered_bytes: 21,
              rendered_sha256: 'b'.repeat(64),
            },
            rendered_prompt_variables: {
              current_memory: '[m1] old fact',
            },
          },
        },
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
      dashboardSurface: '/api/v1/keepers/:name/memory-journal',
      returned: 1,
      undecodableLines: 0,
      entries: [{
        ok: true,
        outcome: 'committed',
        recordedAt: 1786000002,
        revision: 42,
        traceId: 'trace-1',
        sourceKind: 'librarian',
        added: [journalFact('새 기억', 'fact', 1786000001)],
        removed: [journalFact('낡은 기억', 'blocker', 1785000000)],
        retained: 0,
        invalidated: [{
          fact: {
            ...journalFact('지지가 사라진 기억', 'fact', 1785000001),
            basis: {
              kind: 'derived' as const,
              derivations: [{
                rule_id: 'support_rule',
                premise_ids: [`sha256:${'b'.repeat(64)}`],
              }],
            },
          },
          missingPremiseIds: [`sha256:${'b'.repeat(64)}`],
        }],
        drops: [{ memoryId: `sha256:${'a'.repeat(64)}`, reason: '새 근거로 대체됨' }],
      }],
    })

    const { container } = render(html`<${InternalAgentsMonitor} />`)
    const run = await screen.findByRole('button', { name: /Librarian trace-1/i })
    const runIdentity = container.querySelector('code[translate="no"]')
    expect(runIdentity?.textContent).toContain('run_id · exact-lib-1')
    expect(runIdentity?.getAttribute('title')).toBe('exact-lib-1')
    fireEvent.click(run)

    expect(await screen.findByText('추가된 기억 1건')).toBeTruthy()
    expect(await screen.findByText('지지 무효화 1건')).toBeTruthy()
    expect(container.textContent).toContain('revision 42')
    expect(container.textContent).toContain('새 기억')
    expect(container.textContent).toContain('낡은 기억')
    expect(container.textContent).toContain('새 근거로 대체됨')
    expect(container.textContent).toContain('TOOL-FREE')
    expect(container.textContent).toContain('선택 slot librarian-primary')
    expect(container.textContent).toContain('외부 research/RAW 입력을 받지 않습니다')
    expect(container.querySelector('[data-librarian-input-evidence]')?.textContent)
      .toContain('Librarian prompt + input provenance')
    expect(container.textContent).toContain('/config/prompts/librarian.md')
    const renderedPromptButton = screen.getByRole('button', { name: '최종 rendered prompt 보기' })
    fireEvent.click(renderedPromptButton)
    expect(container.textContent).toContain('Current=[m1] old fact')
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
      dashboardSurface: '/api/v1/keepers/:name/memory-journal',
      returned: 1,
      undecodableLines: 0,
      entries: [{
        ok: true,
        outcome: 'committed',
        recordedAt: 1786202863,
        revision: 617,
        traceId: 'trace-shared',
        sourceKind: 'explicit_write',
        added: [journalFact('실제 도구 체인 성공', 'fact', 1786202863)],
        removed: [],
        retained: 2,
        invalidated: [],
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
