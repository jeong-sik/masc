import { describe, expect, it } from 'vitest'
import {
  COLLAB_BROADCAST_PEER,
  COLLAB_CLOSE_HOST_CONFLICT,
  COLLAB_CLOSE_NO_SUCH_ROOM,
  COLLAB_CLOSE_ROOM_CLOSED,
  COLLAB_CLOSE_ROOM_FULL,
  collabCloseText,
  decodeCollabControl,
  decodeCollabFrame,
  decodeCollabFrameText,
  encodeCollabFrame,
  packCollabEnvelope,
  unpackCollabEnvelope,
  type CollabFrame,
} from './collab-wire'

describe('envelope', () => {
  it('round-trips a peer id and payload', () => {
    const payload = new Uint8Array([9, 8, 7])
    const packed = packCollabEnvelope(242, payload)
    expect(packed.length).toBe(7)
    expect([...packed.slice(0, 4)]).toEqual([0, 0, 0, 242])
    expect(unpackCollabEnvelope(packed)).toEqual({ peer: 242, payload })
  })

  it('packs the broadcast peer', () => {
    expect(unpackCollabEnvelope(packCollabEnvelope(COLLAB_BROADCAST_PEER, new Uint8Array(0)))?.peer).toBe(0)
  })

  it('rejects a short envelope', () => {
    expect(unpackCollabEnvelope(new Uint8Array([0, 0, 0]))).toBeNull()
  })

  it('throws on an out-of-range peer instead of masking it', () => {
    expect(() => packCollabEnvelope(-1, new Uint8Array(0))).toThrow()
    expect(() => packCollabEnvelope(0x1_0000_0000, new Uint8Array(0))).toThrow()
  })
})

describe('control', () => {
  it('decodes relay control JSON', () => {
    expect(decodeCollabControl('{"t":"peer-joined","peer":3}')).toEqual({ kind: 'peer-joined', peer: 3 })
    expect(decodeCollabControl('{"t":"peer-left","peer":3}')).toEqual({ kind: 'peer-left', peer: 3 })
    expect(decodeCollabControl('{"t":"room-closed"}')).toEqual({ kind: 'room-closed' })
  })

  it('rejects malformed control', () => {
    expect(decodeCollabControl('not json')).toBeNull()
    expect(decodeCollabControl('{"t":"peer-joined","peer":0}')).toBeNull()
    expect(decodeCollabControl('{"t":"peer-joined"}')).toBeNull()
    expect(decodeCollabControl('{"t":"nope"}')).toBeNull()
  })
})

describe('close codes', () => {
  it('mirrors the omp codes with human text', () => {
    expect(COLLAB_CLOSE_ROOM_CLOSED).toBe(4001)
    expect(COLLAB_CLOSE_NO_SUCH_ROOM).toBe(4004)
    expect(COLLAB_CLOSE_HOST_CONFLICT).toBe(4009)
    expect(COLLAB_CLOSE_ROOM_FULL).toBe(4029)
    expect(collabCloseText(4001)).toMatch(/ended/)
    expect(collabCloseText(4004)).toMatch(/No such room/)
    expect(collabCloseText(4123)).toMatch(/4123/)
  })
})

describe('frames', () => {
  const frames: CollabFrame[] = [
    { kind: 'hello', proto: 1, writeToken: 'dG9rZW4', label: 'web' },
    { kind: 'hello', proto: 1, writeToken: null, label: null },
    {
      kind: 'welcome', proto: 1, keeper: 'narae', operation: 'op-1',
      active: true, guests: 2, entryCount: 9, readOnly: true,
    },
    { kind: 'snapshot-chunk', entries: [{ seq: 1 }], final: true },
    { kind: 'entry', seq: 4, op: 'op-1', opSeq: 7, ts: 12.5, event: { type: 'text_delta' } },
    { kind: 'state', active: false, guests: 0 },
    { kind: 'prompt', text: 'go' },
    { kind: 'abort' },
    { kind: 'fetch-transcript', reqId: 2, maxBytes: 65536 },
    { kind: 'transcript', reqId: 2, text: 't', newSize: 10, error: null },
    { kind: 'transcript', reqId: 2, text: '', newSize: 10, error: 'boom' },
    { kind: 'bye', reason: 'host left' },
    { kind: 'error', message: 'bad hello' },
  ]

  it('round-trips every frame shape through the tagged-object encoding', () => {
    for (const frame of frames) {
      expect(decodeCollabFrameText(encodeCollabFrame(frame))).toEqual(frame)
    }
  })

  it('uses the kebab-case tags the host emits', () => {
    expect(JSON.parse(encodeCollabFrame({ kind: 'snapshot-chunk', entries: [], final: false })).t)
      .toBe('snapshot-chunk')
    expect(JSON.parse(encodeCollabFrame({ kind: 'fetch-transcript', reqId: 1, maxBytes: 1 })).t)
      .toBe('fetch-transcript')
    expect(JSON.parse(encodeCollabFrame({ kind: 'state', active: true, guests: 1 })).t).toBe('state')
  })

  it('omits absent optionals instead of writing nulls', () => {
    const hello = JSON.parse(
      encodeCollabFrame({ kind: 'hello', proto: 1, writeToken: null, label: null }),
    )
    expect('write_token' in hello).toBe(false)
    expect('label' in hello).toBe(false)
  })

  it('is strict: unknown tag, mistype, and negative int all refuse', () => {
    expect(decodeCollabFrame({ t: 'frobnicator' })).toBeNull()
    expect(decodeCollabFrame({ t: 'entry', seq: 1, op: 'op', op_seq: 1, ts: 1.0 })).toBeNull()
    expect(decodeCollabFrame({ t: 'state', active: true, guests: -1 })).toBeNull()
    expect(decodeCollabFrame({ t: 'prompt' })).toBeNull()
    expect(decodeCollabFrame({ t: 'welcome', proto: '1' })).toBeNull()
    expect(decodeCollabFrame('nope')).toBeNull()
    expect(decodeCollabFrameText('{oops')).toBeNull()
  })

  it('ignores unknown extra fields', () => {
    expect(
      decodeCollabFrame({ t: 'state', active: true, guests: 1, future: { deep: [1] } }),
    ).toEqual({ kind: 'state', active: true, guests: 1 })
  })

  it('takes any proto int (mismatch is reported, not a decode failure)', () => {
    const decoded = decodeCollabFrame({
      t: 'welcome', proto: 99,
      header: { keeper: 'k', operation: 'op' },
      state: { active: false, guests: 0 },
      entry_count: 0, read_only: false,
    })
    expect(decoded).toMatchObject({ kind: 'welcome', proto: 99 })
  })
})
