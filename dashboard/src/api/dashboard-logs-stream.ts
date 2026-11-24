import { logsPath, type LogsRequest } from './dashboard-logs'
import { decodeLogsStreamFrame, type LogsStreamFrame } from './schemas/logs'
import { QueryStreamProtocolError, readQueryObservationStream } from './query-observation-stream'

export class LogsStreamError extends QueryStreamProtocolError {
  readonly name = 'LogsStreamError'
}

export async function readDashboardLogsStream(
  request: LogsRequest, observerInstance: string, signal: AbortSignal,
  onFrame: (frame: LogsStreamFrame) => void, onActivity?: () => void,
): Promise<void> {
  await readQueryObservationStream(logsPath(request, true), observerInstance, signal, wire => {
    const decoded = decodeLogsStreamFrame(wire)
    if (!decoded.ok) throw decoded.error
    return decoded.value
  }, onFrame, onActivity)
}
