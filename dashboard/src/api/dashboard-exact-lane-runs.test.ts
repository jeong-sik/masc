import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  fetchExactLaneRuns,
  laneRunsQuery,
  parseExactLaneRunResponse,
  parseExactLaneRunsResponse,
  parseLaneRunResponse,
  parseLaneRunsResponse,
} from './dashboard-exact-lane-runs'
import { clearStoredToken, setStoredToken } from './core'

afterEach(() => {
  clearStoredToken()
  vi.unstubAllGlobals()
})

function detailFixture(overrides: Record<string, unknown> = {}) {
  return {
    generated_at: '2026-09-08T00:00:00Z',
    run: {
      run_id: 'payload-run', run_kind: 'exact_output', lane: 'librarian_exact',
      subject_id: null, actor: 'keeper-a', started_at: 1, status: 'succeeded',
      completion_origin: 'producer', usage: null,
      elapsed_s: 0.4, selected_slot: null,
      input: { kind: 'exact', payload: null }, output: null,
      skill_evidence: { state: 'no_keeper_skills' },
      payload_availability: { input: { state: 'available' }, output: { state: 'available' } },
      ...overrides,
    },
  }
}

function boardJudgment(source: Record<string, unknown>, slotId: string) {
  return {
    verdict: { decision: 'relevant', rationale: 'the Board post needs attention' },
    slot_id: slotId,
    source,
    judged_at: 42,
  }
}

it('keeps original run payloads readable when passive slot metadata is present', () => {
  const run = parseExactLaneRunResponse(detailFixture({
    slot_observations: { state: 'unavailable', detail: 'passive metadata unreadable' },
  }))
  expect(run.runId).toBe('payload-run')
  expect(run.status).toBe('succeeded')
  expect(run.output).toBeNull()
  expect(run.slotObservations?.state).toBe('unavailable')
})

it('isolates malformed slot metadata from original succeeded output', () => {
  const run = parseExactLaneRunResponse(detailFixture({ output: { original: 'retained' },
    slot_observations: { state: 'available', observations: [{}] },
  }))
  expect(run.status).toBe('succeeded')
  expect(run.output).toEqual({ original: 'retained' })
  expect(run.slotObservations?.state).toBe('unavailable')
})

describe('fetchExactLaneRuns', () => {
  it('requests native filtering on both the initial and cursor page', async () => {
    const requests: URL[] = []
    vi.stubGlobal('fetch', vi.fn(async (input: string) => {
      requests.push(new URL(input, 'http://fixture.invalid'))
      const before = requests.at(-1)!.searchParams.get('before_run_id')
      return new Response(JSON.stringify({
        generated_at: '2026-09-08T00:00:00Z', count: 1, total: 2, has_more: before === null,
        runs: [{
          run_kind: 'exact_output', run_id: before === null ? 'native-b' : 'native-a',
          lane: 'librarian_exact', subject_id: null, actor: 'keeper-fixture',
          started_at: 100, status: 'running',
        }],
      }), { status: 200, headers: { 'Content-Type': 'application/json' } })
    }))
    setStoredToken('native-kind-fixture', { source: 'manual' })
    const first = await fetchExactLaneRuns({ limit: 1 })
    const last = first.runs[0]!
    const second = await fetchExactLaneRuns({ limit: 1, before: { startedAt: last.startedAt, runId: last.runId } })
    expect(requests).toHaveLength(2)
    for (const request of requests) {
      expect(request.pathname).toBe('/api/v1/dashboard/exact-lane-runs')
      expect(request.searchParams.get('run_kind')).toBe('exact_output')
      expect(request.searchParams.get('limit')).toBe('1')
    }
    expect(requests[0]!.searchParams.has('before_run_id')).toBe(false)
    expect(requests[1]!.searchParams.get('before_run_id')).toBe('native-b')
    expect(requests[1]!.searchParams.get('before_started_at')).toBe('100')
    expect(first.total).toBe(2)
    expect(second).toMatchObject({ total: 2, hasMore: false, runs: [{ runId: 'native-a' }] })
  })

  it('asks the server to filter one lane before it pages', async () => {
    const requests: URL[] = []
    vi.stubGlobal('fetch', vi.fn(async (input: string) => {
      requests.push(new URL(input, 'http://fixture.invalid'))
      return new Response(JSON.stringify({ generated_at: '2026-09-08T00:00:00Z', count: 0, total: 0, has_more: false, runs: [] }),
        { status: 200, headers: { 'Content-Type': 'application/json' } })
    }))
    setStoredToken('lane-filter-fixture', { source: 'manual' })
    await fetchExactLaneRuns({ lane: 'candle_appraiser' })
    await fetchExactLaneRuns()
    expect(requests[0]!.searchParams.get('lane')).toBe('candle_appraiser')
    expect(requests[0]!.searchParams.get('run_kind')).toBe('exact_output')
    expect(requests[1]!.searchParams.has('lane')).toBe(false)
  })
})

describe('parseExactLaneRunsResponse', () => {
  it('decodes one completed Auto Judge exact lane record', () => {
    const parsed = parseExactLaneRunsResponse({
      generated_at: '2026-08-06T00:00:00Z',
      count: 1,
      total: 1,
      has_more: false,
      runs: [{
        run_kind: 'exact_output', run_id: 'exact-auto-judge-1',
        lane: 'hitl_auto_judge',
        subject_id: null,
        actor: 'keeper-a',
        started_at: 1,
        status: 'succeeded',
        completion_origin: 'producer', usage: null,
        elapsed_s: 0.4,
        selected_slot: 'auto-judge-primary',
      }],
    })
    expect(parsed.runs[0]).toMatchObject({
      lane: 'hitl_auto_judge',
      subjectId: null,
      status: 'succeeded',
      selectedSlot: 'auto-judge-primary',
    })
  })

  it('rejects an unknown lane instead of guessing', () => {
    expect(() => parseExactLaneRunsResponse({
      generated_at: '2026-08-06T00:00:00Z',
      count: 1,
      total: 1,
      has_more: false,
      runs: [{
        run_kind: 'exact_output', run_id: 'x', lane: 'mystery', subject_id: 's', actor: 'a',
        started_at: 1, status: 'running',
      }],
    })).toThrow('unknown value')
  })

  // A listing row carries no payload at all, so a payload field appearing in
  // one is a contract break rather than a value to inspect.
  it('rejects a listing row that carries a payload', () => {
    expect(() => parseExactLaneRunsResponse({
      generated_at: '2026-08-09T00:00:00Z',
      count: 1,
      total: 1,
      has_more: false,
      runs: [{
        run_kind: 'exact_output', run_id: 'librarian-1',
        lane: 'librarian_exact',
        subject_id: 'trace-1',
        actor: 'keeper-a',
        started_at: 1,
        status: 'running',
        input: { kind: 'exact', payload: { message_count: 4 } },
      }],
    })).toThrow()
  })

  it('reports the page it returned against the total retained', () => {
    const parsed = parseExactLaneRunsResponse({
      generated_at: '2026-08-12T00:00:00Z',
      count: 1,
      total: 5908,
      has_more: true,
      runs: [{
        run_kind: 'exact_output', run_id: 'r', lane: 'librarian_exact', subject_id: 's', actor: 'a',
        started_at: 1, status: 'running',
      }],
    })
    expect(parsed.total).toBe(5908)
    expect(parsed.hasMore).toBe(true)
    expect(parsed.count).toBe(1)
  })
  it('decodes both explicit completion persistence failure states', () => {
    const parsed = parseExactLaneRunsResponse({
      generated_at: '2026-08-11T00:00:00Z',
      count: 2,
      total: 2,
      has_more: false,
      runs: [
        {
          run_kind: 'exact_output', run_id: 'failed-append',
          lane: 'board_attention_exact',
          subject_id: 'trace-1',
          actor: 'keeper-a',
          started_at: 1,
          status: 'completion_persistence_failed',
          intended_status: 'failed',
          intended_code: 'model_error',
          intended_detail: 'typed failure detail',
          completion_origin: 'producer', usage: null,
          elapsed_s: 0.4,
          selected_slot: null,
          persistence_error: 'append rejected before commit',
          persistence_state: 'not_persisted',
        },
        {
          run_kind: 'exact_output', run_id: 'unknown-append',
          lane: 'librarian_exact',
          subject_id: 'trace-2',
          actor: 'keeper-b',
          started_at: 2,
          status: 'completion_durability_unknown',
          intended_status: 'succeeded',
          completion_origin: 'producer', usage: null,
          elapsed_s: 0.5,
          selected_slot: 'librarian-secondary',
          persistence_error: 'rollback settlement failed',
          persistence_state: 'durability_unknown',
        },
      ],
    })
    expect(parsed.runs[0]).toMatchObject({
      status: 'completion_persistence_failed',
      intendedStatus: 'failed',
      intendedCode: 'model_error',
      intendedDetail: 'typed failure detail',
      persistenceState: 'not_persisted',
      selectedSlot: null,
    })
    expect(parsed.runs[1]).toMatchObject({
      status: 'completion_durability_unknown',
      intendedStatus: 'succeeded',
      persistenceState: 'durability_unknown',
      selectedSlot: 'librarian-secondary',
    })
  })

  it('rejects a persistence status paired with the wrong durability state', () => {
    expect(() => parseExactLaneRunsResponse({
      generated_at: '2026-08-11T00:00:00Z',
      count: 1,
      total: 1,
      has_more: false,
      runs: [{
        run_kind: 'exact_output', run_id: 'mismatch',
        lane: 'board_attention_exact',
        subject_id: 'trace',
        actor: 'keeper-a',
        started_at: 1,
        status: 'completion_persistence_failed',
        intended_status: 'succeeded',
        completion_origin: 'producer', usage: null,
        elapsed_s: 0.4,
        selected_slot: null,
        persistence_error: 'append failed',
        persistence_state: 'durability_unknown',
      }],
    })).toThrow('persistence_state must be')
  })

  it('rejects a terminal row that omits the current selected-slot contract', () => {
    expect(() => parseExactLaneRunsResponse({
      generated_at: '2026-08-11T00:00:00Z',
      count: 1,
      total: 1,
      has_more: false,
      runs: [{
        run_kind: 'exact_output', run_id: 'legacy-terminal',
        lane: 'librarian_exact',
        subject_id: 'trace',
        actor: 'keeper-a',
        started_at: 1,
        status: 'succeeded',
        completion_origin: 'producer', usage: null,
        elapsed_s: 0.4,
      }],
    })).toThrow('missing=[selected_slot]')
  })
})

describe('parseExactLaneRunResponse', () => {
  it('retains Candle appraisal input, output and selected slot', () => {
    const run = parseExactLaneRunResponse(detailFixture({
      lane: 'candle_appraiser', actor: '/workspace/candle', selected_slot: 'appraisal.slot',
      input: { kind: 'exact', payload: { goal_id: 'goal-1' } }, output: { grade: 'medium' },
    }))
    expect(run).toMatchObject({
      lane: 'candle_appraiser', actor: '/workspace/candle', selectedSlot: 'appraisal.slot',
      input: { kind: 'exact', payload: { goal_id: 'goal-1' } }, output: { grade: 'medium' },
    })
  })

  it('keeps a Vendor System One answer separate from the selected-slot contract', () => {
    const run = parseExactLaneRunResponse(detailFixture({
      lane: 'board_attention_exact',
      selected_slot: null,
      output: boardJudgment({
        kind: 'vendor_system_one',
        endpoint: 'https://jev.invalid/v1/judge',
        model: 'jev-latest',
        request_body_sha256: 'a'.repeat(64),
      }, 'jev-latest'),
    }))
    expect(run.selectedSlot).toBeNull()
    expect(run.answerSource).toEqual({
      kind: 'vendor_system_one',
      endpoint: 'https://jev.invalid/v1/judge',
      model: 'jev-latest',
    })
  })

  it.each([
    ['completion_persistence_failed', 'not_persisted'],
    ['completion_durability_unknown', 'durability_unknown'],
  ] as const)('keeps the intended Vendor answer across %s', (status, persistenceState) => {
    const run = parseExactLaneRunResponse(detailFixture({
      lane: 'board_attention_exact',
      status,
      intended_status: 'succeeded',
      persistence_error: 'completion append did not settle',
      persistence_state: persistenceState,
      selected_slot: null,
      output: boardJudgment({
        kind: 'vendor_system_one',
        endpoint: 'https://jev.invalid/v1/judge',
        model: 'jev-latest',
        request_body_sha256: 'a'.repeat(64),
      }, 'jev-latest'),
    }))
    expect(run.answerSource).toMatchObject({ kind: 'vendor_system_one', model: 'jev-latest' })
    expect(run.persistenceState).toBe(persistenceState)
  })

  it('rejects answer-source attribution that disagrees with selected_slot', () => {
    expect(() => parseExactLaneRunResponse(detailFixture({
      lane: 'board_attention_exact',
      selected_slot: 'different-slot',
      output: boardJudgment({ kind: 'cli_lane_slot' }, 'codex_subscription.gpt-5.6-luna'),
    }))).toThrow('slot_id must match selected_slot')
  })

  it('preserves the current native metadata and available JSON null', () => {
    const run = parseExactLaneRunResponse(detailFixture())
    expect(run).toMatchObject({
      runId: 'payload-run', runKind: 'exact_output', status: 'succeeded',
      input: { kind: 'exact', payload: null }, output: null,
      skillEvidence: { state: 'no_keeper_skills' },
      payloadAvailability: { input: { state: 'available' }, output: { state: 'available' } },
    })
  })

  it('keeps per-side source failures without substituting an execution failure', () => {
    const error = { code: 'invalid_payload', message: 'output.json is not JSON: malformed' }
    const run = parseExactLaneRunResponse(detailFixture({
      output: { superseded: 'not usable' },
      payload_availability: { input: { state: 'available' }, output: { state: 'unavailable', error } },
    }))
    expect(run.status).toBe('succeeded')
    expect(run.input.payload).toBeNull()
    expect(run.payloadAvailability.output).toEqual({ state: 'unavailable', error })
    expect(run.output).toBeUndefined()
  })

  it('requires the current native run kind and Skill evidence contract', () => {
    expect(() => parseExactLaneRunResponse(detailFixture({ run_kind: undefined }))).toThrow('run_kind')
    expect(() => parseExactLaneRunResponse(detailFixture({ skill_evidence: undefined }))).toThrow('skill_evidence')
    expect(() => parseExactLaneRunResponse(detailFixture({ skill_evidence: { state: 'unknown' } }))).toThrow('skill_evidence.state')
  })

  it.each([
    undefined,
    { input: { state: 'available' }, output: null },
    { input: { state: 'mystery' }, output: { state: 'available' } },
    { input: { state: 'available' }, output: { state: 'unavailable' } },
    { input: { state: 'available' }, output: { state: 'unavailable', error: { code: 'unknown', message: 'not known' } } },
    { input: { state: 'available' }, output: { state: 'unavailable', error: { code: 'invalid_payload', message: 'bad', line: 1 } } },
  ])('rejects missing or malformed payload availability %#', availability => {
    expect(() => parseExactLaneRunResponse(detailFixture({ payload_availability: availability }))).toThrow()
  })

  it('rejects an available output with no value and a running row with terminal availability', () => {
    const absent: Record<string, unknown> = detailFixture().run
    delete absent.output
    expect(() => parseExactLaneRunResponse({ ...detailFixture(), run: absent })).toThrow('missing=[output]')
    const running: Record<string, unknown> = detailFixture({ status: 'running' }).run
    delete running.output
    delete running.completion_origin
    delete running.usage
    delete running.elapsed_s
    delete running.selected_slot
    expect(() => parseExactLaneRunResponse({ ...detailFixture(), run: running })).toThrow('null exactly while running')
    running.payload_availability = { input: { state: 'available' }, output: null }
    expect(parseExactLaneRunResponse({ ...detailFixture(), run: running }).output).toBeUndefined()
  })

  it('decodes one opened run with both payloads', () => {
    const run = parseExactLaneRunResponse({
      generated_at: '2026-08-12T00:00:00Z',
      run: {
        run_kind: 'exact_output', run_id: 'exact-librarian-1',
        lane: 'librarian_exact',
        subject_id: 'trace-1',
        actor: 'keeper-a',
        started_at: 1,
        status: 'succeeded',
        completion_origin: 'producer', usage: null,
        elapsed_s: 0.4,
        selected_slot: null,
        skill_evidence: { state: 'no_keeper_skills' },
        payload_availability: { input: { state: 'available' }, output: { state: 'available' } },
        input: { kind: 'exact', payload: { message_count: 4 } },
        output: { fact_count: 3 },
      },
    })
    expect(run.input).toEqual({ kind: 'exact', payload: { message_count: 4 } })
    expect(run.output).toEqual({ fact_count: 3 })
    expect(run.selectedSlot).toBeNull()
  })

  it('rejects removed research input instead of replaying it', () => {
    expect(() => parseExactLaneRunResponse({
      generated_at: '2026-08-09T00:00:00Z',
      run: {
        run_kind: 'exact_output', run_id: 'librarian-research-1',
        lane: 'librarian_exact',
        subject_id: 'trace-1',
        actor: 'keeper-a',
        started_at: 1,
        status: 'running',
        skill_evidence: { state: 'no_keeper_skills' },
        payload_availability: { input: { state: 'available' }, output: null },
        input: {
          kind: 'research',
          raw_trace_path: '/tmp/raw-traces/librarian-research-1.jsonl',
          payload: { message_count: 4 },
        },
      },
    })).toThrow('unknown value')
  })
})


describe('exact observation origin, timing and provider usage', () => {
  it('preserves an unmeasured terminal and explicit absent extended usage', () => {
    const parsed = parseExactLaneRunResponse(detailFixture({ elapsed_s: null, usage: null }))
    expect(parsed.elapsedSeconds).toBeUndefined()
    expect(parsed.completionOrigin).toBe('producer')
    expect(parsed.usage).toBeNull()
    expect(parsed.output).toBeNull()
  })

  it('decodes the full provider usage contract independently of timing', () => {
    const parsed = parseExactLaneRunResponse(detailFixture({ elapsed_s: null, usage: {
      input_tokens: 40, output_tokens: 7, cache_creation_input_tokens: 3, cache_read_input_tokens: 20, cost_usd: 0.015,
    } }))
    expect(parsed.usage).toEqual({ inputTokens: 40, outputTokens: 7, cacheCreationInputTokens: 3, cacheReadInputTokens: 20, costUsd: 0.015 })
    expect(parsed.elapsedSeconds).toBeUndefined()
  })

  it('keeps a restart observation separate from a producer completion', () => {
    const raw = detailFixture({ status: 'failed', completion_origin: 'restart_replay', elapsed_s: null,
      code: 'server_restarted', detail: 'the original observation fiber was lost', selected_slot: null, usage: null })
    expect(parseExactLaneRunResponse(raw).completionOrigin).toBe('restart_replay')
    expect(() => parseExactLaneRunResponse({ ...raw, run: { ...raw.run, elapsed_s: 10 } })).toThrow('restart observation')
  })

  it('refuses unknown origin, missing nullable fields and partial or malformed full usage', () => {
    expect(() => parseExactLaneRunResponse(detailFixture({ completion_origin: 'guessed' }))).toThrow('completion_origin')
    for (const key of ['completion_origin', 'usage', 'elapsed_s']) {
      const raw: Record<string, unknown> = detailFixture().run
      delete raw[key]
      expect(() => parseExactLaneRunResponse({ ...detailFixture(), run: raw })).toThrow('missing=')
    }
    for (const usage of [{ input_tokens: 1, output_tokens: 2 },
      { input_tokens: 1, output_tokens: 2, cache_creation_input_tokens: 0, cache_read_input_tokens: -1 },
      { input_tokens: 1, output_tokens: 2, cache_creation_input_tokens: 0, cache_read_input_tokens: 0, extra: true }]) {
      expect(() => parseExactLaneRunResponse(detailFixture({ usage }))).toThrow()
    }
  })
})

// Rows as server_standalone_lane_projection.ml writes them for the listing
// without a run_kind filter.
const exactRow = {
  run_kind: 'exact_output', run_id: 'exact-1', lane: 'librarian_exact', subject_id: null, actor: 'keeper-a',
  started_at: 30, status: 'succeeded', completion_origin: 'producer', usage: null, elapsed_s: 0.5, selected_slot: 'slot-a',
}
const taskRow = {
  run_id: 'verify-1', run_kind: 'task_verification', lane: 'verifier_exact', subject_id: 'task-7',
  actor: 'keeper-b', started_at: 20, status: 'rejected', elapsed_s: 3.25, selected_slot: null,
}
const goalRow = {
  run_id: 'goal-run-1', run_kind: 'goal_verification', lane: 'verifier_exact', subject_id: 'goal-3',
  actor: 'keeper-c', started_at: 10, status: 'running',
}

function page(runs: readonly unknown[]) {
  return { generated_at: '2026-11-26T00:00:00Z', count: runs.length, total: runs.length, has_more: false, runs }
}

describe('parseLaneRunsResponse', () => {
  it('decodes exact, Task verification and Goal verification rows on one page', () => {
    const parsed = parseLaneRunsResponse(page([exactRow, taskRow, goalRow]))
    expect(parsed.runs.map(run => run.runKind)).toEqual(['exact_output', 'task_verification', 'goal_verification'])
    const [, task, goal] = parsed.runs
    expect(task).toEqual({
      runId: 'verify-1', runKind: 'task_verification', lane: 'verifier_exact', subjectId: 'task-7',
      actor: 'keeper-b', startedAt: 20, status: 'rejected', elapsedSeconds: 3.25, selectedSlot: null,
    })
    expect(goal).toEqual({
      runId: 'goal-run-1', runKind: 'goal_verification', lane: 'verifier_exact', subjectId: 'goal-3',
      actor: 'keeper-c', startedAt: 10, status: 'running', elapsedSeconds: undefined, selectedSlot: undefined,
    })
  })

  it('refuses an unknown run kind, a status of the other registry, and a verifier row on another lane', () => {
    expect(() => parseLaneRunsResponse(page([{ ...taskRow, run_kind: 'fusion' }]))).toThrow('run_kind has unknown value')
    expect(() => parseLaneRunsResponse(page([{ ...taskRow, status: 'committed' }]))).toThrow('status has unknown value')
    expect(() => parseLaneRunsResponse(page([{ ...goalRow, status: 'approved' }]))).toThrow('status has unknown value')
    expect(() => parseLaneRunsResponse(page([{ ...taskRow, lane: 'librarian_exact' }]))).toThrow('verifier_exact')
  })

  it('requires completion fields exactly when a verifier review has finished', () => {
    const { elapsed_s: _elapsed, ...withoutElapsed } = taskRow
    expect(() => parseLaneRunsResponse(page([withoutElapsed]))).toThrow('missing=[elapsed_s]')
    expect(() => parseLaneRunsResponse(page([{ ...goalRow, elapsed_s: 1, selected_slot: null }]))).toThrow('unknown=[elapsed_s,selected_slot]')
    expect(() => parseLaneRunsResponse(page([{ ...taskRow, usage: null }]))).toThrow('unknown=[usage]')
  })

  it('keeps the exact_output page narrow: a verifier row there is refused', () => {
    expect(parseExactLaneRunsResponse(page([exactRow])).runs[0]!.runKind).toBe('exact_output')
    expect(() => parseExactLaneRunsResponse(page([exactRow, taskRow]))).toThrow('must be exact_output on an exact_output page')
  })
})

describe('parseLaneRunResponse', () => {
  it('opens a completed Task review with its registry record as output', () => {
    const output = { verification_id: 'verify-1', status: 'rejected', reason: 'missing proof' }
    const run = parseLaneRunResponse({
      generated_at: '2026-11-26T00:00:00Z',
      run: {
        ...taskRow,
        input: { kind: 'exact', payload: { kind: 'task_verification', task_id: 'task-7', producer: 'p', authority_kind: 'k', authority_actor: 'keeper-b' } },
        output,
        skill_evidence: { state: 'no_keeper_skills' },
        payload_availability: { input: { state: 'available' }, output: { state: 'available' } },
      },
    })
    expect(run.runKind).toBe('task_verification')
    expect(run.output).toEqual(output)
    expect(run.payloadAvailability.output).toEqual({ state: 'available' })
    expect(() => parseExactLaneRunResponse({ generated_at: 'x', run: { ...taskRow, input: { kind: 'exact', payload: null }, output,
      skill_evidence: { state: 'no_keeper_skills' }, payload_availability: { input: { state: 'available' }, output: { state: 'available' } } } }))
      .toThrow('root.run.run_kind must be exact_output')
  })

  it('opens a running Goal review with no output and null output availability', () => {
    const run = parseLaneRunResponse({
      generated_at: '2026-11-26T00:00:00Z',
      run: {
        ...goalRow,
        input: { kind: 'exact', payload: { kind: 'goal_verification', goal_id: 'goal-3' } },
        skill_evidence: { state: 'no_keeper_skills' },
        payload_availability: { input: { state: 'available' }, output: null },
      },
    })
    expect(run.runKind).toBe('goal_verification')
    expect(run.output).toBeUndefined()
    expect(run.payloadAvailability.output).toBeNull()
  })
})

describe('laneRunsQuery', () => {
  it('omits run_kind for the unfiltered listing and keeps the cursor pair together', () => {
    expect(laneRunsQuery({ limit: 50 })).toBe('limit=50')
    expect(laneRunsQuery({ runKind: 'goal_verification', limit: 50, before: { startedAt: 12.5, runId: 'r-1' } }))
      .toBe('run_kind=goal_verification&limit=50&before_started_at=12.5&before_run_id=r-1')
  })
})
