import { authHeaders, fetchControlPlane } from './core'
import { ensureDevToken } from './dev-token'
import { readSse } from '../lib/sse-reader'
import { isObserverInstance, OBSERVER_IDLE_TIMEOUT_HEADER, OBSERVER_INSTANCE_HEADER, ObserverAccessError } from '../lib/observer-protocol'
import { DEFAULT_GET_TIMEOUT_MS } from '../config/constants'
import { parseSSEMessage } from '../schemas/sse'
import type { KeeperWaitingInventoryChange } from '../sse-store'

/** Opens the server's scoped observer stream for the waiting inventory.
 * Reconnection starts with a new snapshot, so no replay cursor is requested. */
export async function observeKeeperWaitingChanges(
  signal: AbortSignal,
  onReady: (instance: string) => void,
  onChange: (change: KeeperWaitingInventoryChange) => void,
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
      response = await fetchControlPlane('/mcp?sse_kind=observer', {
        signal: controller.signal,
        // The MCP cookie is shared by tabs. Each observer needs its own server
        // session and must not overwrite a session used by another connection.
        credentials: 'omit',
        headers: { ...authHeaders(), Accept: 'text/event-stream' },
      })
    } catch (cause) {
      if (timedOut && !signal.aborted) throw new Error('observer connection timed out')
      throw cause
    } finally {
      clearTimeout(timer)
    }
    body = response.body
    const instance = response.headers.get(OBSERVER_INSTANCE_HEADER)
    if (signal.aborted) throw new DOMException('Observer stopped', 'AbortError')
    if (response.status === 401 || response.status === 403) throw new ObserverAccessError(response.status)
    if (!response.ok) throw new Error(`observer request failed (${response.status})`)
    if (!body || !response.headers.get('content-type')?.toLowerCase().startsWith('text/event-stream')) {
      throw new Error('observer stream response is unavailable')
    }
    if (!isObserverInstance(instance) || response.headers.get('x-masc-sse-replay') !== 'fresh') {
      throw new Error('observer generation is unavailable')
    }
    const deadline = response.headers.get(OBSERVER_IDLE_TIMEOUT_HEADER)
    const idleTimeoutMs = deadline !== null && /^[1-9][0-9]*$/.test(deadline) ? Number(deadline) : NaN
    // Browsers clamp larger delays; accepting one would make a dead stream
    // appear current for a different duration than the server advertised.
    if (!Number.isSafeInteger(idleTimeoutMs) || idleTimeoutMs > 2_147_483_647) {
      throw new Error('observer idle deadline is unavailable')
    }
    onReady(instance)
    await readSse(body, (_event, data) => {
      const value: unknown = JSON.parse(data)
      if (typeof value !== 'object' || value === null || Array.isArray(value) || !('type' in value)) return
      const type = value.type
      if (type !== 'schedule_store_invalidated' && type !== 'operator_pending_confirm_invalidated'
          && type !== 'keeper_waiting_inventory_changed') return
      const event = parseSSEMessage(value)
      if (!event) throw new Error('invalid waiting-inventory observer event')
      if (event.type === 'keeper_waiting_inventory_changed') {
        const keeperName = event.keeper_name?.trim()
        if (!keeperName) throw new Error('invalid waiting-inventory observer event')
        onChange({ scope: 'keeper', keeperName })
      } else {
        onChange({ scope: 'workspace' })
      }
    }, { idleTimeoutMs, signal: controller.signal })
    if (!signal.aborted) throw new Error('observer stream closed')
  } finally {
    signal.removeEventListener('abort', abort)
    controller.abort()
    // readSse owns its reader while active. On admission failure no reader was
    // acquired, so cancel the response body here as well.
    if (body && !body.locked) void body.cancel().catch(() => {})
  }
}
