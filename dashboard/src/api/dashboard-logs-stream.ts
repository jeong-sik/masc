import { Effect } from 'effect'
import { logsPath, type LogsRequest } from './dashboard-logs'
import { decodeLogsStreamFrame, type LogsStreamFrame } from './schemas/logs'
import { QueryStreamProtocolError, readQueryObservationStream } from './query-observation-stream'

export class LogsStreamError extends QueryStreamProtocolError {
  readonly name = 'LogsStreamError'
}

export async function readDashboardLogsStream(
  request: LogsRequest, signal: AbortSignal,
  onFrame: (frame: LogsStreamFrame) => void, onActivity?: () => void,
): Promise<void> {
  await readQueryObservationStream(logsPath(request, true), signal, wire => {
    const decoded = Effect.runSync(Effect.either(decodeLogsStreamFrame(wire)))
    if (decoded._tag === 'Left') throw decoded.left
    return decoded.right
  }, onFrame, onActivity)
}
