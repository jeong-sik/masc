import { logsPath, type LogsData, type LogsRequest } from './api/dashboard-logs'
import { LogsSchemaDriftError, type LogsStreamFrame } from './api/schemas/logs'
import { LogsStreamError, readDashboardLogsStream } from './api/dashboard-logs-stream'
import { QueryStreamProtocolError } from './api/query-observation-stream'
import { createQueryObservationStream } from './lib/query-observation-stream'

function appendSnapshot(previous: LogsData | null, frame: LogsStreamFrame): LogsData {
  if (frame.reset || previous === null) return frame.data
  const entries = new Map(previous.entries.map(entry => [entry.seq, entry]))
  for (const entry of frame.data.entries) entries.set(entry.seq, entry)
  return {
    ...frame.data,
    entries: [...entries.values()].filter(entry => entry.seq >= frame.data.ring.startSeq)
      .sort((a, b) => b.seq - a.seq).slice(0, frame.limit),
  }
}

/** Identical mounted queries share one stream; final release retires all I/O. */
export const subscribeDashboardLogsStream = createQueryObservationStream<LogsRequest, LogsStreamFrame, LogsStreamError>({
  key: request => logsPath(request, true),
  recoveryTopics: ['logs'],
  read: (request, previous, signal, onFrame, onActivity, observerInstance) => readDashboardLogsStream({
    ...request, sinceSeq: previous && previous.data.ring.total > 0 ? previous.data.ring.total - 1 : undefined,
  }, observerInstance, signal, onFrame, onActivity),
  merge: (previous, frame) => ({ ...frame, reset: true, data: appendSnapshot(previous?.data ?? null, frame) }),
  readOutcome: () => 'complete',
  failure: cause => cause instanceof LogsStreamError ? cause
    : new LogsStreamError(cause instanceof Error ? cause.message : String(cause)),
  terminal: cause => cause instanceof LogsSchemaDriftError || cause instanceof LogsStreamError
    || cause instanceof QueryStreamProtocolError,
})
