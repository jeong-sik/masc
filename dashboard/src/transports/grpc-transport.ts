/** gRPC-web transport using JSON over HTTP/1.1.
 *
 * Implements the gRPC-web protocol directly (no grpc-web library needed
 * for the JSON flavour).  Uses fetch + ReadableStream for binary frame
 * parsing.
 *
 * Proto: proto/masc_coordination.proto
 * Service: masc.coordination.v1.MascCoordination
 */

import type { Transport, TransportEvent, TransportOptions } from './transport'
import type {
  JoinRequest,
  JoinResponse,
  LeaveRequest,
  LeaveResponse,
  SubscribeRequest,
  Event,
  ToolCallRequest,
  ToolCallResponse,
  BroadcastRequest,
  BroadcastResponse,
  StatusRequest,
  StatusResponse,
} from '../grpc/masc_coordination_pb'

const DEFAULT_RETRY_BASE_MS = 1000
const DEFAULT_RETRY_MAX_MS = 30000

/** Encode a JSON payload into a gRPC-web binary frame.
 *  Frame: [flag:1][length:4][payload:N]
 *  flag = 0x00 (uncompressed) for JSON. */
function encodeJsonFrame(obj: unknown): Uint8Array {
  const json = JSON.stringify(obj)
  const encoder = new TextEncoder()
  const payload = encoder.encode(json)
  const frame = new Uint8Array(1 + 4 + payload.length)
  frame[0] = 0x00 // uncompressed
  const view = new DataView(frame.buffer)
  view.setUint32(1, payload.length, false) // big-endian
  frame.set(payload, 5)
  return frame
}

/** Parse gRPC-web frames from a Uint8Array stream.
 *  Yields { data?: unknown, trailers?: Record<string,string> }
 */
function* parseFrames(bytes: Uint8Array): Generator<
  { data?: unknown; trailers?: Record<string, string> }
> {
  let offset = 0
  const decoder = new TextDecoder()
  while (offset + 5 <= bytes.length) {
    const flag = bytes[offset]
    const length =
      (bytes[offset + 1] << 24) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 8) |
      bytes[offset + 4]
    if (offset + 5 + length > bytes.length) break
    const payload = bytes.slice(offset + 5, offset + 5 + length)
    offset += 5 + length

    if (flag === 0x80) {
      // trailers
      const text = decoder.decode(payload)
      const trailers: Record<string, string> = {}
      for (const line of text.split('\r\n')) {
        const idx = line.indexOf(':')
        if (idx > 0) trailers[line.slice(0, idx).trim()] = line.slice(idx + 1).trim()
      }
      yield { trailers }
    } else {
      const text = decoder.decode(payload)
      try {
        yield { data: JSON.parse(text) }
      } catch {
        yield { data: text }
      }
    }
  }
}

export interface GrpcTransport extends Transport {
  readonly join: (req: JoinRequest) => Promise<JoinResponse>
  readonly leave: (req: LeaveRequest) => Promise<LeaveResponse>
  readonly subscribe: (req: SubscribeRequest) => AsyncIterable<Event>
  readonly toolCall: (req: ToolCallRequest) => Promise<ToolCallResponse>
  readonly broadcast: (req: BroadcastRequest) => Promise<BroadcastResponse>
  readonly getStatus: (req: StatusRequest) => Promise<StatusResponse>
}

interface GrpcTransportState {
  listeners: Array<(event: TransportEvent) => void>
  retryMs: number
  reconnectTimer: ReturnType<typeof setTimeout> | null
  connected: boolean
  abortController: AbortController | null
}

function createState(): GrpcTransportState {
  return {
    listeners: [],
    retryMs: DEFAULT_RETRY_BASE_MS,
    reconnectTimer: null,
    connected: false,
    abortController: null,
  }
}

function notify(state: GrpcTransportState, event: TransportEvent) {
  state.listeners.forEach((l) => l(event))
}

async function unaryRpc<TReq, TRes>(
  baseUrl: string,
  service: string,
  method: string,
  request: TReq,
  opts: TransportOptions,
  state: GrpcTransportState,
): Promise<TRes> {
  const url = `${baseUrl}/${service}/${method}`
  const body = encodeJsonFrame(request)

  const controller = new AbortController()
  const res = await fetch(url, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/grpc-web+json',
      'X-Grpc-Web': '1',
      ...(opts.headers ?? {}),
    },
    body,
    signal: controller.signal,
  })

  if (!res.ok) {
    throw new Error(`gRPC-web unary error: ${res.status}`)
  }

  const buffer = await res.arrayBuffer()
  const bytes = new Uint8Array(buffer)
  for (const frame of parseFrames(bytes)) {
    if (frame.trailers) {
      const grpcStatus = frame.trailers['grpc-status']
      if (grpcStatus && grpcStatus !== '0') {
        throw new Error(
          frame.trailers['grpc-message'] ?? `gRPC error ${grpcStatus}`
        )
      }
    }
    if (frame.data !== undefined) {
      return frame.data as TRes
    }
  }
  throw new Error('gRPC-web: no response frame')
}

async function* serverStreamingRpc<TReq, TRes>(
  baseUrl: string,
  service: string,
  method: string,
  request: TReq,
  opts: TransportOptions,
  state: GrpcTransportState,
): AsyncGenerator<TRes, void, unknown> {
  const url = `${baseUrl}/${service}/${method}`
  const body = encodeJsonFrame(request)

  const controller = new AbortController()
  state.abortController = controller

  const res = await fetch(url, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/grpc-web+json',
      'X-Grpc-Web': '1',
      ...(opts.headers ?? {}),
    },
    body,
    signal: controller.signal,
  })

  if (!res.ok || !res.body) {
    throw new Error(`gRPC-web stream error: ${res.status}`)
  }

  const reader = res.body.getReader()
  const decoder = new TextDecoder()
  let buffer = ''

  try {
    while (!controller.signal.aborted) {
      const { done, value } = await reader.read()
      if (done) break
      buffer += decoder.decode(value, { stream: true })
      // For binary mode we need frame parsing; for text mode (base64) decode first.
      // This implementation assumes the server returns binary frames.
      // In practice grpc-web-text base64-encodes each frame.
      // To keep it robust we treat the whole buffer as one frame batch for now.
      const bytes = new Uint8Array(value)
      for (const frame of parseFrames(bytes)) {
        if (frame.trailers) {
          const grpcStatus = frame.trailers['grpc-status']
          if (grpcStatus && grpcStatus !== '0') {
            throw new Error(
              frame.trailers['grpc-message'] ?? `gRPC error ${grpcStatus}`
            )
          }
          return
        }
        if (frame.data !== undefined) {
          yield frame.data as TRes
        }
      }
    }
  } finally {
    reader.releaseLock()
  }
}

export function createGrpcTransport(
  baseUrl: string,
  opts: TransportOptions = {},
): GrpcTransport {
  const state = createState()
  const service = 'masc.coordination.v1.MascCoordination'

  const connect = () => {
    state.connected = true
    notify(state, { type: 'open' })
  }

  const disconnect = () => {
    if (state.reconnectTimer) {
      clearTimeout(state.reconnectTimer)
      state.reconnectTimer = null
    }
    state.connected = false
    state.abortController?.abort()
    state.abortController = null
    notify(state, { type: 'close' })
  }

  const subscribe = (listener: (event: TransportEvent) => void) => {
    state.listeners = [...state.listeners, listener]
    return () => {
      state.listeners = state.listeners.filter((l) => l !== listener)
    }
  }

  return {
    url: baseUrl,
    connect,
    disconnect,
    subscribe,
    isConnected: () => state.connected,
    join: (req) => unaryRpc(baseUrl, service, 'Join', req, opts, state),
    leave: (req) => unaryRpc(baseUrl, service, 'Leave', req, opts, state),
    subscribe: (req) => serverStreamingRpc(baseUrl, service, 'Subscribe', req, opts, state),
    toolCall: (req) => unaryRpc(baseUrl, service, 'ToolCall', req, opts, state),
    broadcast: (req) => unaryRpc(baseUrl, service, 'Broadcast', req, opts, state),
    getStatus: (req) => unaryRpc(baseUrl, service, 'GetStatus', req, opts, state),
  }
}
