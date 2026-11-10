import { QueryStreamProtocolError, readQueryObservationStream } from './query-observation-stream'
import {
  parseToolMetricsSeriesResponse, seriesAnswerMismatch, toolMetricsSeriesQuery,
  type ToolMetricsSeriesRequest, type ToolMetricsSeriesResponse,
} from './schemas/tool-metrics-series'
import { createQueryObservationStream } from '../lib/query-observation-stream'
import { isRecord } from '../lib/type-guards'

export class ToolSeriesStreamError extends QueryStreamProtocolError {
  readonly name = 'ToolSeriesStreamError'
}

/** A valid server failure envelope is an owed source read, not bad protocol. */
export class ToolSeriesReadError extends Error {
  readonly name = 'ToolSeriesReadError'
}

export function toolSeriesStreamPath(request: ToolMetricsSeriesRequest): string {
  return `/api/v1/tool-metrics/series/stream?${toolMetricsSeriesQuery(request)}`
}

export async function readToolSeriesStream(
  request: ToolMetricsSeriesRequest, observerInstance: string, signal: AbortSignal,
  onFrame: (frame: ToolMetricsSeriesResponse) => void, onActivity?: () => void,
): Promise<void> {
  await readQueryObservationStream(toolSeriesStreamPath(request), observerInstance, signal, wire => {
    if (isRecord(wire) && typeof wire.error === 'string') throw new ToolSeriesReadError(wire.error)
    let frame: ToolMetricsSeriesResponse
    try { frame = parseToolMetricsSeriesResponse(wire) }
    catch (cause) { throw new ToolSeriesStreamError(cause instanceof Error ? cause.message : String(cause)) }
    const mismatch = seriesAnswerMismatch(request, frame)
    if (mismatch !== null) throw new ToolSeriesStreamError(mismatch)
    return frame
  }, onFrame, onActivity)
}

export const subscribeToolSeriesStream = createQueryObservationStream<
  ToolMetricsSeriesRequest, ToolMetricsSeriesResponse, ToolSeriesStreamError
>({
  key: toolSeriesStreamPath,
  recoveryTopics: ['tool_metrics', 'tools'],
  read: (request, _previous, signal, onFrame, onActivity, observerInstance) =>
    readToolSeriesStream(request, observerInstance, signal, onFrame, onActivity),
  merge: (_previous, frame) => frame,
  readOutcome: () => 'complete',
  failure: cause => cause instanceof ToolSeriesStreamError ? cause
    : new ToolSeriesStreamError(cause instanceof Error ? cause.message : String(cause)),
  terminal: cause => cause instanceof QueryStreamProtocolError,
})
