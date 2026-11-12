import { Effect } from 'effect'
import { apiRequestErrorFromResponse, authHeaders, fetchControlPlane } from './core'
import { ensureDevToken } from './dev-token'
import { logsPath, type LogsRequest } from './dashboard-logs'
import { decodeLogsStreamFrame, type LogsStreamFrame } from './schemas/logs'
import { parseUniqueJson } from '../lib/json-unique'
import { readSse } from '../lib/sse-reader'

export class LogsStreamError extends Error {
  readonly name = 'LogsStreamError'
}

/** One authenticated, read-only stream. The owner handles reconnect and scope. */
export async function readDashboardLogsStream(
  request: LogsRequest,
  signal: AbortSignal,
  onFrame: (frame: LogsStreamFrame) => void,
): Promise<void> {
  await ensureDevToken()
  if (signal.aborted) return
  const path = logsPath(request, true)
  const response = await fetchControlPlane(path, {
    method: 'GET', headers: { ...authHeaders(), Accept: 'text/event-stream' },
    credentials: 'omit', signal,
  })
  if (!response.ok) throw await apiRequestErrorFromResponse('GET', path, response)
  if (!response.headers.get('content-type')?.toLowerCase().startsWith('text/event-stream')) {
    void response.body?.cancel().catch(() => {})
    throw new LogsStreamError('Log stream returned a non-stream response')
  }
  if (!response.body) throw new LogsStreamError('Log stream returned no body')
  const options = { signal }
  await readSse(response.body, (_event, data) => {
    if (signal.aborted) return
    let wire: unknown
    try { wire = parseUniqueJson(data) }
    catch { throw new LogsStreamError('Log stream returned invalid JSON') }
    const decoded = Effect.runSync(Effect.either(decodeLogsStreamFrame(wire)))
    if (decoded._tag === 'Left') throw decoded.left
    onFrame(decoded.right)
  }, options)
  if (!signal.aborted) throw new Error('Log stream ended before cancellation')
}
