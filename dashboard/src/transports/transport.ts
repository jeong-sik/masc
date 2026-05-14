/** Multi-transport abstraction for keeper tool results and real-time events.
 *
 * Supports SSE, HTTP streamable, WebSocket, and gRPC transports.
 * Consumers subscribe to a typed event stream without caring about the
 * underlying transport.
 */

export type TransportEvent =
  | { readonly type: 'message'; readonly data: unknown }
  | { readonly type: 'error'; readonly error: Error }
  | { readonly type: 'close' }
  | { readonly type: 'open' }

export interface Transport {
  readonly url: string
  readonly connect: () => void
  readonly disconnect: () => void
  readonly subscribe: (listener: (event: TransportEvent) => void) => () => void
  readonly isConnected: () => boolean
}

export interface TransportFactory {
  readonly create: (url: string, opts?: TransportOptions) => Transport
}

export interface TransportOptions {
  readonly retryBaseMs?: number
  readonly retryMaxMs?: number
  readonly heartbeatIntervalMs?: number
  readonly headers?: Record<string, string>
}
