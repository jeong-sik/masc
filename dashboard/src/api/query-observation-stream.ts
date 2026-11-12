import { apiRequestErrorFromResponse, authHeaders, fetchControlPlane } from './core'
import { ensureDevToken } from './dev-token'
import { DEFAULT_GET_TIMEOUT_MS } from '../config/constants'
import { OBSERVER_IDLE_TIMEOUT_HEADER } from '../lib/observer-protocol'
import { parseUniqueJson } from '../lib/json-unique'
import { readSse } from '../lib/sse-reader'

export class QueryStreamProtocolError extends Error {
  readonly name: string = 'QueryStreamProtocolError'
}

/** The server advertises its deadline; accepting a clamped browser timeout
 * would silently give a stalled stream a different lifetime. */
function idleDeadline(response: Response): number {
  const raw = response.headers.get(OBSERVER_IDLE_TIMEOUT_HEADER)
  const value = raw !== null && /^[1-9][0-9]*$/.test(raw) ? Number(raw) : NaN
  if (!Number.isSafeInteger(value) || value > 2_147_483_647) {
    throw new QueryStreamProtocolError('Observation stream idle deadline is unavailable')
  }
  return value
}

/** One authenticated GET, with admission and byte-activity deadlines. */
export async function readQueryObservationStream<Frame>(
  path: string, signal: AbortSignal, decode: (wire: unknown) => Frame,
  onFrame: (frame: Frame) => void, onActivity?: () => void,
): Promise<void> {
  await ensureDevToken()
  if (signal.aborted) throw new DOMException('Observer stopped', 'AbortError')
  const controller = new AbortController()
  const abort = () => controller.abort()
  signal.addEventListener('abort', abort, { once: true })
  let body: ReadableStream<Uint8Array> | null = null
  try {
    let timedOut = false
    const timer = setTimeout(() => { timedOut = true; controller.abort() }, DEFAULT_GET_TIMEOUT_MS)
    let response: Response
    try {
      response = await fetchControlPlane(path, {
        method: 'GET', headers: { ...authHeaders(), Accept: 'text/event-stream' },
        credentials: 'omit', signal: controller.signal,
      })
    } catch (cause) {
      if (timedOut && !signal.aborted) throw new Error('Observation stream admission timed out')
      throw cause
    } finally { clearTimeout(timer) }
    body = response.body
    if (signal.aborted) throw new DOMException('Observer stopped', 'AbortError')
    if (!response.ok) throw await apiRequestErrorFromResponse('GET', path, response)
    if (!body || !response.headers.get('content-type')?.toLowerCase().startsWith('text/event-stream')) {
      throw new QueryStreamProtocolError('Observation stream response is unavailable')
    }
    const idleTimeoutMs = idleDeadline(response)
    let idleExpired = false
    let idleTimer: ReturnType<typeof setTimeout> | undefined
    const activity = () => {
      if (idleTimer !== undefined) clearTimeout(idleTimer)
      idleTimer = setTimeout(() => { idleExpired = true; controller.abort() }, idleTimeoutMs)
      onActivity?.()
    }
    // Arm once at admission. Only actual bytes extend this deadline;
    // zero-length chunks and application-level waits cannot keep it alive.
    idleTimer = setTimeout(() => { idleExpired = true; controller.abort() }, idleTimeoutMs)
    try {
      await readSse(body, (_event, data) => {
        if (controller.signal.aborted) return
        let wire: unknown
        try { wire = parseUniqueJson(data) }
        catch { throw new QueryStreamProtocolError('Observation stream returned invalid JSON') }
        onFrame(decode(wire))
      }, { signal: controller.signal, onActivity: activity })
    } catch (cause) {
      if (idleExpired && !signal.aborted) throw new Error('Observation stream idle timeout')
      throw cause
    } finally { if (idleTimer !== undefined) clearTimeout(idleTimer) }
    if (!signal.aborted) throw new Error('Observation stream ended before cancellation')
  } finally {
    signal.removeEventListener('abort', abort)
    controller.abort()
    if (body && !body.locked) void body.cancel().catch(() => {})
  }
}
