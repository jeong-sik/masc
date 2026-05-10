/** gRPC-web transport placeholder.
 *
 * Uses @grpc/grpc-js for Node or grpc-web for browser.
 * Currently exports a stub that throws on connect until a concrete
 * proto + service are wired.
 */

import type { Transport, TransportEvent, TransportOptions } from './transport'

export function createGrpcTransport(_url: string, _opts: TransportOptions = {}): Transport {
  let listeners: Array<(event: TransportEvent) => void> = []

  const notify = (event: TransportEvent) => {
    listeners.forEach((l) => l(event))
  }

  return {
    url: _url,
    connect: () => {
      notify({
        type: 'error',
        error: new Error(
          'gRPC transport not yet implemented. ' +
            'Wire a concrete proto service and remove this stub.'
        ),
      })
    },
    disconnect: () => {
      notify({ type: 'close' })
    },
    subscribe: (listener) => {
      listeners = [...listeners, listener]
      return () => {
        listeners = listeners.filter((l) => l !== listener)
      }
    },
    isConnected: () => false,
  }
}
