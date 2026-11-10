import {
  fetchKeeperChatOperation,
  type KeeperChatOperation,
  type KeeperChatOperationState,
} from './api/keeper'
import { setupObservationRefresh } from './lib/observation-refresh'
import { captureDashboardObservationOwner, dashboardObservationOwnerIsCurrent,
  subscribeDashboardObservationOwnerChanges } from './lib/observation-read-owner'

export type TerminalKeeperChatOperation = KeeperChatOperation & {
  state: Exclude<KeeperChatOperationState, { kind: 'queued' } | { kind: 'running' }>
}

function terminal(operation: KeeperChatOperation): operation is TerminalKeeperChatOperation {
  return operation.state.kind !== 'queued' && operation.state.kind !== 'running'
}

interface OperationOwner {
  readonly signal?: AbortSignal
  readonly current?: () => boolean
}

/** Observe the original durable operation. This reader cannot submit a turn. */
export function observeKeeperChatOperation(
  keeperName: string,
  operationId: string,
  options: OperationOwner & {
    readonly onOperation: (operation: KeeperChatOperation) => void | Promise<void>
    readonly onError?: (error: unknown) => void
  },
): () => void {
  let active = true
  let stop = () => {}
  let stopOwner = () => {}
  const owner = captureDashboardObservationOwner()
  const dispose = () => {
    active = false
    stop()
    stopOwner()
    options.signal?.removeEventListener('abort', aborted)
  }
  const aborted = () => {
    if (!active) return
    dispose()
    options.onError?.(new DOMException('Operation observation retired', 'AbortError'))
  }
  stopOwner = subscribeDashboardObservationOwnerChanges(aborted)
  stop = setupObservationRefresh(async signal => {
    if (!active) return
    if (!dashboardObservationOwnerIsCurrent(owner) || options.current?.() === false) { aborted(); return }
    const readSignal = options.signal ? AbortSignal.any([signal, options.signal]) : signal
    const operation = await fetchKeeperChatOperation(keeperName, operationId, { signal: readSignal })
    if (!active || readSignal.aborted) return
    if (!dashboardObservationOwnerIsCurrent(owner) || options.current?.() === false) { aborted(); return }
    await options.onOperation(operation)
  }, {
    topics: ['chat_operation'], keeperName, operationId,
    onError: options.onError ?? (() => {}),
  })
  options.signal?.addEventListener('abort', aborted, { once: true })
  if (options.signal?.aborted) aborted()
  return dispose
}

/** Keep pending state attached to the original receipt until a terminal
 * observation arrives. Lookup errors keep their existing caller boundary;
 * the caller may retain an error-recovery owner without replaying the send. */
export function waitForKeeperChatOperationTerminal(
  keeperName: string,
  operationId: string,
  options: OperationOwner & { readonly onPending?: (operation: KeeperChatOperation) => void } = {},
): { readonly result: Promise<TerminalKeeperChatOperation>; readonly dispose: () => void } {
  let dispose = () => {}
  let rejectResult: (error: unknown) => void = () => {}
  const result = new Promise<TerminalKeeperChatOperation>((resolve, reject) => {
    rejectResult = reject
    dispose = observeKeeperChatOperation(keeperName, operationId, {
      ...options,
      onOperation: operation => {
        if (terminal(operation)) { dispose(); resolve(operation) }
        else options.onPending?.(operation)
      },
      onError: error => { dispose(); reject(error) },
    })
  })
  return { result, dispose: () => { dispose(); rejectResult(new DOMException('Operation observation retired', 'AbortError')) } }
}
