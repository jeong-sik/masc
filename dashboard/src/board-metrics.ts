import { signal } from '@preact/signals'

export type BoardLatencyOperation =
  | 'list'
  | 'list_more'
  | 'detail'
  | 'reaction_summary'
  | 'reaction_toggle'

export interface BoardLatencyMetric {
  last_latency_ms: number | null
  last_ok: boolean | null
  sample_count: number
  failure_count: number
  last_error: string | null
}

export type BoardLatencyMetrics = Record<BoardLatencyOperation, BoardLatencyMetric>

const OPERATIONS: BoardLatencyOperation[] = [
  'list',
  'list_more',
  'detail',
  'reaction_summary',
  'reaction_toggle',
]

function emptyMetric(): BoardLatencyMetric {
  return {
    last_latency_ms: null,
    last_ok: null,
    sample_count: 0,
    failure_count: 0,
    last_error: null,
  }
}

function emptyMetrics(): BoardLatencyMetrics {
  return Object.fromEntries(OPERATIONS.map((op) => [op, emptyMetric()])) as BoardLatencyMetrics
}

export const boardLatencyMetrics = signal<BoardLatencyMetrics>(emptyMetrics())

export function resetBoardLatencyMetrics(): void {
  boardLatencyMetrics.value = emptyMetrics()
}

export function boardMetricNow(): number {
  const now = globalThis.performance?.now?.()
  return typeof now === 'number' && Number.isFinite(now) ? now : Date.now()
}

function errorMessage(error: unknown): string | null {
  if (error instanceof Error) return error.message || error.name
  if (typeof error === 'string') return error
  return error == null ? null : String(error)
}

export function recordBoardLatency(
  operation: BoardLatencyOperation,
  startedAt: number,
  ok: boolean,
  error?: unknown,
): void {
  const elapsedMs = Math.max(0, Math.round(boardMetricNow() - startedAt))
  const current = boardLatencyMetrics.value[operation] ?? emptyMetric()
  boardLatencyMetrics.value = {
    ...boardLatencyMetrics.value,
    [operation]: {
      last_latency_ms: elapsedMs,
      last_ok: ok,
      sample_count: current.sample_count + 1,
      failure_count: current.failure_count + (ok ? 0 : 1),
      last_error: ok ? null : errorMessage(error),
    },
  }
}

export async function timeBoardRequest<T>(
  operation: BoardLatencyOperation,
  request: () => Promise<T>,
): Promise<T> {
  const startedAt = boardMetricNow()
  try {
    const result = await request()
    recordBoardLatency(operation, startedAt, true)
    return result
  } catch (err) {
    recordBoardLatency(operation, startedAt, false, err)
    throw err
  }
}
