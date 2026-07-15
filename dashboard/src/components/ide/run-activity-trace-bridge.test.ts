import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  clearTraces,
  keeperTraceState,
} from './keeper-trace-store'
import { bridgeRunActivityEventsToTrace } from './run-activity-trace-bridge'
import type { RunActivityEvent } from './run-activity-store'

beforeEach(() => {
  clearTraces()
})

afterEach(() => {
  clearTraces()
})

describe('bridgeRunActivityEventsToTrace', () => {
  it('pushes file-line activity context into the keeper trace store', () => {
    const emitted = bridgeRunActivityEventsToTrace([
      activity({
        id: 'evt-1',
        keeper_id: 'sangsu',
        context: {
          file_path: ' lib\\runtime.ml ',
          line: 7,

          task_id: 'task-runtime',
          board_post_id: 'post-runtime',
          comment_id: 'comment-runtime',
          pr_id: '15035',
          git_ref: 'main',
          log_id: 'turn-7',
          session_id: 'sess-runtime',
          operation_id: 'op-runtime',
          worker_run_id: 'wr-runtime',
        },
      }),
    ], new Set())

    expect([...emitted]).toEqual(['activity:run-default:evt-1'])
    expect(keeperTraceState.value.events).toEqual([{
      id: 'activity:run-default:evt-1',
      tsMs: 1000,
      keeperName: 'sangsu',
      source: 'activity-event',
      count: 1,
      eventId: 'evt-1',
      filePath: 'lib/runtime.ml',
      line: 7,
      surface: 'PR',
      taskId: 'task-runtime',
      boardPostId: 'post-runtime',
      commentId: 'comment-runtime',
      prId: '15035',
      gitRef: 'main',
      logId: 'turn-7',
      sessionId: 'sess-runtime',
      operationId: 'op-runtime',
      workerRunId: 'wr-runtime',
    }])
  })

  it('deduplicates already emitted activity events across refreshes', () => {
    const event = activity({
      id: 'evt-1',
      context: {
        file_path: 'lib/runtime.ml',
        line: 4,
        log_id: 'turn-4',
      },
    })

    const emitted = bridgeRunActivityEventsToTrace([event], new Set())
    const emittedAgain = bridgeRunActivityEventsToTrace([event], emitted)

    expect(emittedAgain).toBeInstanceOf(Set)
    expect(keeperTraceState.value.events).toHaveLength(1)
    expect(keeperTraceState.value.events[0]?.count).toBe(1)
  })

  it('labels typed comment and runtime activity surfaces without kind fallback', () => {
    const emitted = bridgeRunActivityEventsToTrace([
      activity({
        id: 'evt-comment',
        kind: 'note',
        context: {
          file_path: 'lib/comment.ml',
          line: 11,
          comment_id: 'comment-11',
        },
      }),
      activity({
        id: 'evt-runtime',
        kind: 'note',
        context: {
          file_path: 'lib/runtime.ml',
          line: 12,
          session_id: 'session-12',
          operation_id: 'operation-12',
          worker_run_id: 'worker-12',
        },
      }),
    ], new Set())

    expect([...emitted]).toEqual([
      'activity:run-default:evt-comment',
      'activity:run-default:evt-runtime',
    ])
    expect(keeperTraceState.value.events).toMatchObject([
      {
        id: 'activity:run-default:evt-comment',
        filePath: 'lib/comment.ml',
        line: 11,
        surface: 'Comment',
        commentId: 'comment-11',
      },
      {
        id: 'activity:run-default:evt-runtime',
        filePath: 'lib/runtime.ml',
        line: 12,
        surface: 'Runtime',
        sessionId: 'session-12',
        operationId: 'operation-12',
        workerRunId: 'worker-12',
      },
    ])
  })

  it('skips unscoped lines and unsafe file paths without poisoning later enrichment', () => {
    const unscoped = activity({
      id: 'evt-1',
      context: { line: 4, log_id: 'turn-1' },
    })
    const unsafe = activity({
      id: 'evt-2',
      context: { file_path: '/tmp/runtime.ml', line: 5, log_id: 'turn-2' },
    })

    const first = bridgeRunActivityEventsToTrace([unscoped, unsafe], new Set())
    expect([...first]).toEqual([])
    expect(keeperTraceState.value.events).toEqual([])

    const enriched = bridgeRunActivityEventsToTrace([
      activity({
        id: 'evt-1',
        context: { file_path: 'lib/runtime.ml', line: 4, log_id: 'turn-1' },
      }),
    ], first)

    expect([...enriched]).toEqual(['activity:run-default:evt-1'])
    expect(keeperTraceState.value.events[0]).toMatchObject({
      source: 'activity-event',
      filePath: 'lib/runtime.ml',
      line: 4,
      surface: 'Log',
    })
  })
})

function activity(overrides: Partial<RunActivityEvent>): RunActivityEvent {
  return {
    id: 'evt-default',
    run_id: 'run-default',
    keeper_id: 'keeper-a',
    verb: 'noted',
    target: 'telemetry',
    timestamp_ms: 1000,
    ...overrides,
  }
}
