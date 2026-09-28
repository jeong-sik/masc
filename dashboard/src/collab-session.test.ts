import { describe, expect, it, vi } from 'vitest'
import {
  openCollabSession,
  type CollabSessionStatus,
  type CollabSocket,
} from './collab-session'
import type { CollabJoinEvent } from './collab-join'
import {
  collabTextDecoder,
  collabTextEncoder,
  importCollabKey,
  isCollabOpenError,
  openCollabFrame,
  sealCollabFrame,
} from './collab-crypto'
import { decodeCollabFrameText, encodeCollabFrame, packCollabEnvelope, unpackCollabEnvelope, type CollabFrame } from './collab-wire'

function keyBytes(): Uint8Array {
  const out = new Uint8Array(32)
  for (let i = 0; i < 32; i++) out[i] = (i * 13 + 5) % 256
  return out
}

class FakeSocket implements CollabSocket {
  binaryType = ''
  onopen: ((event: unknown) => void) | null = null
  onmessage: ((event: { data: unknown }) => void) | null = null
  onclose: ((event: { code: number; reason: string }) => void) | null = null
  onerror: ((event: unknown) => void) | null = null
  readonly sent: ArrayBuffer[] = []
  readonly closed: Array<{ code?: number; reason?: string }> = []

  constructor(readonly url: string) {}

  send(data: string | ArrayBuffer): void {
    if (typeof data === 'string') throw new Error('session must only send binary')
    this.sent.push(data)
  }

  close(code?: number, reason?: string): void {
    this.closed.push({ code, reason })
  }

  peerOpen(): void {
    this.onopen?.({})
  }

  peerBinary(data: ArrayBuffer): void {
    this.onmessage?.({ data })
  }

  peerText(data: string): void {
    this.onmessage?.({ data })
  }

  peerClose(code: number): void {
    this.onclose?.({ code, reason: '' })
  }
}

async function flush(times = 10): Promise<void> {
  // WebCrypto completions need macrotask turns, not just microtasks.
  for (let i = 0; i < times; i++) await new Promise(resolve => setTimeout(resolve, 0))
}

async function openSession(canSteer: boolean, writeToken: string | null, welcomeTimeoutMs = 30_000) {
  const key = await importCollabKey(keyBytes())
  const sockets: FakeSocket[] = []
  const events: CollabJoinEvent[] = []
  const statuses: CollabSessionStatus[] = []
  const session = openCollabSession({
    url: 'wss://relay.test/r/room?role=guest',
    key,
    writeToken,
    label: 'web',
    canSteer,
    onEvent: event => events.push(event),
    onStatus: status => statuses.push(status),
    welcomeTimeoutMs,
    createSocket: url => {
      const socket = new FakeSocket(url)
      sockets.push(socket)
      return socket
    },
  })
  const socket = sockets[0]!
  socket.peerOpen()
  await flush()
  return { key, session, socket, events, statuses }
}

/** Decode one outbound sealed frame back to JSON for assertions. */
async function decodeSent(key: CryptoKey, sent: ArrayBuffer): Promise<CollabFrame | null> {
  const envelope = unpackCollabEnvelope(new Uint8Array(sent))
  if (!envelope || envelope.peer !== 0) return null
  const opened = await openCollabFrame(key, envelope.payload)
  if (isCollabOpenError(opened)) return null
  return decodeCollabFrameText(collabTextDecoder.decode(opened))
}

async function sealInbound(key: CryptoKey, frame: CollabFrame, peer = 0): Promise<ArrayBuffer> {
  const sealed = await sealCollabFrame(key, collabTextEncoder.encode(encodeCollabFrame(frame)))
  const wire = packCollabEnvelope(peer, sealed)
  return new Uint8Array(wire).buffer as ArrayBuffer
}

describe('openCollabSession', () => {
  it('seals a hello to peer 0 on open', async () => {
    const { key, socket, statuses } = await openSession(true, 'dG9rZW4')
    expect(statuses.map(status => status.kind)).toEqual(['connecting', 'open'])
    expect(socket.sent).toHaveLength(1)
    expect(await decodeSent(key, socket.sent[0]!)).toEqual({
      kind: 'hello', proto: 1, writeToken: 'dG9rZW4', label: 'web',
    })
  })

  it('sends a view hello without a write token', async () => {
    const { key, socket } = await openSession(false, null)
    expect(await decodeSent(key, socket.sent[0]!)).toMatchObject({
      kind: 'hello', writeToken: null,
    })
  })

  it('refuses steer actions locally for view guests', async () => {
    const { session, socket, events } = await openSession(false, null)
    expect(session.sendPrompt('go')).toBe(false)
    expect(session.sendAbort()).toBe(false)
    expect(session.fetchTranscript(64)).toBe(false)
    await flush()
    expect(socket.sent).toHaveLength(1)
    expect(events).toEqual([])
  })

  it('seals prompt, abort, and fetch frames for control guests', async () => {
    const { key, session, socket } = await openSession(true, 'dG9rZW4')
    expect(session.sendPrompt('go')).toBe(true)
    expect(session.sendAbort()).toBe(true)
    expect(session.fetchTranscript(100)).toBe(true)
    expect(session.fetchTranscript(100)).toBe(true)
    await flush()
    expect(socket.sent).toHaveLength(5)
    expect(await decodeSent(key, socket.sent[1]!)).toEqual({ kind: 'prompt', text: 'go' })
    expect(await decodeSent(key, socket.sent[2]!)).toEqual({ kind: 'abort' })
    expect(await decodeSent(key, socket.sent[3]!)).toEqual({
      kind: 'fetch-transcript', reqId: 1, maxBytes: 100,
    })
    expect(await decodeSent(key, socket.sent[4]!)).toEqual({
      kind: 'fetch-transcript', reqId: 2, maxBytes: 100,
    })
  })

  it('folds inbound host frames through the join assembly', async () => {
    const { key, socket, events } = await openSession(true, 'dG9rZW4')
    const welcome: CollabFrame = {
      kind: 'welcome', proto: 1, keeper: 'narae', operation: 'op-1',
      active: true, guests: 1, entryCount: 1, readOnly: false,
    }
    socket.peerBinary(await sealInbound(key, welcome))
    await flush()
    expect(events).toHaveLength(1)
    expect(events[0]).toMatchObject({
      kind: 'state', welcome: { keeper: 'narae', operation: 'op-1', readOnly: false },
    })
    socket.peerBinary(await sealInbound(key, {
      kind: 'snapshot-chunk',
      entries: [{ seq: 1, ts: 1.0, event: { type: 'text_delta', delta: 's' } }],
      final: true,
    }))
    await flush()
    expect(events.map(event => event.kind)).toEqual(['state', 'snapshot-row'])
  })

  it('warns visibly on short, tampered, and undecodable inbound frames', async () => {
    const { key, socket, statuses, events } = await openSession(true, 'dG9rZW4')
    socket.peerBinary(new ArrayBuffer(2))
    const sealed = await sealCollabFrame(key, collabTextEncoder.encode('{"t":"state","active":true,"guests":0}'))
    const lastByte = sealed[sealed.length - 1]
    if (lastByte === undefined) throw new Error('unreachable: non-empty sealed frame')
    sealed[sealed.length - 1] = lastByte ^ 0xff
    socket.peerBinary(new Uint8Array(packCollabEnvelope(0, sealed)).buffer as ArrayBuffer)
    const notJson = await sealCollabFrame(key, collabTextEncoder.encode('{oops'))
    socket.peerBinary(new Uint8Array(packCollabEnvelope(0, notJson)).buffer as ArrayBuffer)
    await flush()
    expect(statuses.filter(status => status.kind === 'warning')).toHaveLength(3)
    expect(events).toEqual([])
  })

  it('reports a proto mismatch without dropping the welcome', async () => {
    const { key, socket, statuses, events } = await openSession(true, 'dG9rZW4')
    socket.peerBinary(await sealInbound(key, {
      kind: 'welcome', proto: 99, keeper: 'k', operation: 'op',
      active: false, guests: 0, entryCount: 0, readOnly: true,
    }))
    await flush()
    expect(statuses.filter(status => status.kind === 'warning')).toHaveLength(1)
    expect(events.map(event => event.kind)).toEqual(['state'])
  })

  it('maps relay control and close codes to status', async () => {
    const { socket, statuses } = await openSession(false, null)
    socket.peerText('{"t":"room-closed"}')
    expect(statuses[statuses.length - 1]).toMatchObject({ kind: 'closed', code: 4001 })
    socket.peerText('garbage')
    expect(statuses[statuses.length - 1]?.kind).toBe('warning')
    socket.peerClose(4004)
    expect(statuses[statuses.length - 1]).toMatchObject({ kind: 'closed', code: 4004 })
  })

  it('fails a welcome that never arrives instead of idling', async () => {
    const { socket, statuses } = await openSession(false, null, 20)
    await new Promise(resolve => setTimeout(resolve, 60))
    const last = statuses[statuses.length - 1]
    expect(last?.kind).toBe('error')
    expect(last?.kind === 'error' && last.text).toMatch(/No welcome/)
    expect(socket.closed).toHaveLength(1)
    // The trailing close after a terminal failure adds no second status.
    socket.peerClose(1006)
    expect(statuses[statuses.length - 1]?.kind).toBe('error')
  })

  it('treats a pre-welcome host error as fatal', async () => {
    const { key, socket, events, statuses } = await openSession(false, null, 10_000)
    socket.peerBinary(await sealInbound(key, { kind: 'error', message: 'bad proto' }))
    await flush()
    expect(events.map(event => event.kind)).toEqual(['error-frame'])
    const last = statuses[statuses.length - 1]
    expect(last).toMatchObject({ kind: 'error' })
    expect(last?.kind === 'error' && last.text).toMatch(/refused/)
    expect(socket.closed).toHaveLength(1)
  })

  it('keeps the session open for a post-welcome host error', async () => {
    const { key, socket, events, statuses } = await openSession(false, null, 10_000)
    socket.peerBinary(await sealInbound(key, {
      kind: 'welcome', proto: 1, keeper: 'k', operation: 'op',
      active: false, guests: 0, entryCount: 0, readOnly: true,
    }))
    socket.peerBinary(await sealInbound(key, { kind: 'error', message: 'oops' }))
    await flush()
    expect(events.map(event => event.kind)).toEqual(['state', 'error-frame'])
    expect(statuses.some(status => status.kind === 'error')).toBe(false)
    expect(socket.closed).toHaveLength(0)
  })

  it('closes the socket on request', async () => {
    const onStatus = vi.fn()
    const key = await importCollabKey(keyBytes())
    const socket = new FakeSocket('wss://x')
    const session = openCollabSession({
      url: 'wss://x', key, writeToken: null, label: null, canSteer: false,
      onEvent: () => {}, onStatus, createSocket: () => socket,
    })
    session.close()
    expect(socket.closed).toEqual([{ code: 1000, reason: 'viewer closed' }])
  })
})
