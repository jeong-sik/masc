// MASC collab web viewer — relay session (RFC-0471 §2.3–2.5).
//
// Dials `GET /r/<room>?role=guest` over the viewer origin's WebSocket,
// seals the hello, and folds host frames through Collab_guest_join's
// assembly twin. View guests are refused locally on steer actions — the
// refusal never reaches the wire. The socket factory is injectable so tests
// drive the session without a network.

import {
  COLLAB_BROADCAST_PEER,
  COLLAB_PROTO_VERSION,
  collabCloseText,
  decodeCollabControl,
  decodeCollabFrameText,
  encodeCollabFrame,
  packCollabEnvelope,
  unpackCollabEnvelope,
  type CollabFrame,
} from './collab-wire'
import { createCollabJoin, feedCollabJoin, type CollabJoinEvent } from './collab-join'
import {
  collabTextDecoder,
  collabTextEncoder,
  isCollabOpenError,
  openCollabFrame,
  sealCollabFrame,
} from './collab-crypto'
import { encodeB64url } from './collab-link'

/** Minimal WebSocket surface the session drives (browser or test fake). */
export interface CollabSocket {
  binaryType: string
  onopen: ((event: unknown) => void) | null
  onmessage: ((event: { data: unknown }) => void) | null
  onclose: ((event: { code: number; reason: string }) => void) | null
  onerror: ((event: unknown) => void) | null
  send(data: string | ArrayBuffer): void
  close(code?: number, reason?: string): void
}

export type CollabSocketFactory = (url: string) => CollabSocket

export type CollabSessionStatus =
  | { kind: 'connecting' }
  | { kind: 'open' }
  | { kind: 'closed'; code: number; text: string }
  | { kind: 'error'; text: string }
  | { kind: 'warning'; text: string }

export interface CollabSessionOptions {
  url: string
  key: CryptoKey
  /** Base64url write token on a control link, null on a view link. */
  writeToken: string | null
  label: string | null
  canSteer: boolean
  onEvent: (event: CollabJoinEvent) => void
  onStatus: (status: CollabSessionStatus) => void
  createSocket?: CollabSocketFactory
  /**
   * Ms to wait for the host welcome before failing. The host silently drops
   * undecryptable hellos, so without this a wrong-key guest idles forever.
   * Defaults to 30s; tests pass a small value.
   */
  welcomeTimeoutMs?: number
}

const DEFAULT_WELCOME_TIMEOUT_MS = 30_000

export interface CollabSession {
  sendPrompt: (text: string) => boolean
  sendAbort: () => boolean
  fetchTranscript: (maxBytes: number) => boolean
  close: () => void
}

function defaultSocketFactory(url: string): CollabSocket {
  const socket = new WebSocket(url)
  socket.binaryType = 'arraybuffer'
  return socket as unknown as CollabSocket
}

export function openCollabSession(options: CollabSessionOptions): CollabSession {
  const { url, key, writeToken, label, canSteer, onEvent, onStatus } = options
  const createSocket = options.createSocket ?? defaultSocketFactory
  const welcomeTimeoutMs = options.welcomeTimeoutMs ?? DEFAULT_WELCOME_TIMEOUT_MS
  const join = createCollabJoin()
  let reqId = 0
  let socket: CollabSocket | null = null
  let open = false
  let welcomed = false
  let terminated = false
  let welcomeTimer: ReturnType<typeof setTimeout> | null = null

  onStatus({ kind: 'connecting' })

  function clearWelcomeTimer(): void {
    if (welcomeTimer !== null) {
      clearTimeout(welcomeTimer)
      welcomeTimer = null
    }
  }

  function failTerminal(text: string): void {
    if (terminated) return
    terminated = true
    open = false
    clearWelcomeTimer()
    onStatus({ kind: 'error', text })
    try {
      socket?.close(1000, 'viewer failed')
    } catch {
      // Closing a dead socket is not news.
    }
  }

  async function sendFrame(frame: CollabFrame): Promise<void> {
    if (!socket || !open) return
    try {
      const sealed = await sealCollabFrame(key, collabTextEncoder.encode(encodeCollabFrame(frame)))
      const wire = packCollabEnvelope(COLLAB_BROADCAST_PEER, sealed)
      const copy = new Uint8Array(wire).buffer as ArrayBuffer
      socket.send(copy)
    } catch (err) {
      onStatus({ kind: 'error', text: `Failed to send frame: ${String(err)}` })
    }
  }

  function sendSteer(frame: CollabFrame): boolean {
    if (!canSteer) return false
    void sendFrame(frame)
    return true
  }

  async function handleBinary(data: ArrayBuffer): Promise<void> {
    const bytes = new Uint8Array(data)
    const envelope = unpackCollabEnvelope(bytes)
    if (!envelope) {
      onStatus({ kind: 'warning', text: 'Dropped a short relay envelope.' })
      return
    }
    const opened = await openCollabFrame(key, envelope.payload)
    if (isCollabOpenError(opened)) {
      onStatus({
        kind: 'warning',
        text: opened.kind === 'sealed-too-short'
          ? 'Dropped a truncated sealed frame.'
          : 'Dropped a frame that failed authentication (wrong key?).',
      })
      return
    }
    const frame = decodeCollabFrameText(collabTextDecoder.decode(opened))
    if (!frame) {
      onStatus({ kind: 'warning', text: 'Dropped an undecodable host frame.' })
      return
    }
    if (frame.kind === 'welcome') {
      welcomed = true
      clearWelcomeTimer()
      if (frame.proto !== COLLAB_PROTO_VERSION) {
        onStatus({
          kind: 'warning',
          text: `Host speaks protocol ${frame.proto}; this viewer speaks ${COLLAB_PROTO_VERSION}.`,
        })
      }
    }
    for (const event of feedCollabJoin(join, frame)) onEvent(event)
    if (frame.kind === 'error' && !welcomed) {
      // The host answers a rejected hello with an error and nothing else;
      // without a welcome there is no session to keep open.
      failTerminal(`The host refused the join: ${frame.message}`)
    }
  }

  function handleText(data: string): void {
    const control = decodeCollabControl(data)
    if (!control) {
      onStatus({ kind: 'warning', text: 'Dropped an undecodable relay control message.' })
      return
    }
    if (control.kind === 'room-closed') {
      onStatus({ kind: 'closed', code: 4001, text: collabCloseText(4001) })
    }
    // peer-joined/peer-left go to the host; guests have no peer roster.
  }

  try {
    socket = createSocket(url)
  } catch (err) {
    onStatus({ kind: 'error', text: `Could not open the relay socket: ${String(err)}` })
    socket = null
  }

  if (socket) {
    socket.binaryType = 'arraybuffer'
    socket.onopen = () => {
      open = true
      onStatus({ kind: 'open' })
      void sendFrame({ kind: 'hello', proto: COLLAB_PROTO_VERSION, writeToken, label })
      clearWelcomeTimer()
      welcomeTimer = setTimeout(() => {
        welcomeTimer = null
        if (!welcomed) {
          failTerminal(
            'No welcome from the host — is the link correct and the host still sharing?',
          )
        }
      }, welcomeTimeoutMs)
    }
    socket.onmessage = event => {
      const data = event.data
      if (typeof data === 'string') {
        handleText(data)
      } else if (data instanceof ArrayBuffer) {
        void handleBinary(data)
      } else {
        onStatus({ kind: 'warning', text: 'Dropped a relay message of unknown kind.' })
      }
    }
    socket.onclose = event => {
      open = false
      clearWelcomeTimer()
      // A terminal failure already explained itself; the trailing close adds nothing.
      if (!terminated) {
        onStatus({ kind: 'closed', code: event.code, text: collabCloseText(event.code) })
      }
    }
    socket.onerror = () => {
      onStatus({ kind: 'error', text: 'The relay connection failed.' })
    }
  }

  return {
    sendPrompt: text => sendSteer({ kind: 'prompt', text }),
    sendAbort: () => sendSteer({ kind: 'abort' }),
    fetchTranscript: maxBytes => {
      if (!canSteer) return false
      reqId += 1
      void sendFrame({ kind: 'fetch-transcript', reqId, maxBytes })
      return true
    },
    close: () => {
      open = false
      clearWelcomeTimer()
      try {
        socket?.close(1000, 'viewer closed')
      } catch {
        // Closing a dead socket is not news.
      }
    },
  }
}

/** `wss:`/`ws:` + current host + guest resource, for same-origin dial. */
export function collabSocketUrl(resource: string): string | null {
  if (typeof window === 'undefined' || typeof window.location === 'undefined') return null
  const protocol = window.location.protocol
  if (protocol !== 'https:' && protocol !== 'http:') return null
  try {
    const url = new URL(resource, window.location.href)
    url.protocol = protocol === 'https:' ? 'wss:' : 'ws:'
    return url.toString()
  } catch {
    return null
  }
}

export function encodeWriteTokenForHello(writeToken: Uint8Array | null): string | null {
  return writeToken ? encodeB64url(writeToken) : null
}
