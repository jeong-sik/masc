import { describe, expect, it } from 'vitest'
import {
  collabGuestResource,
  encodeB64url,
  hashLooksLikeCollabLink,
  isParsedCollabLink,
  parseCollabLink,
  parseCollabWebLink,
} from './collab-link'

function bytes(length: number, seed: number): Uint8Array {
  const out = new Uint8Array(length)
  for (let i = 0; i < length; i++) out[i] = (seed + i * 37) % 256
  return out
}

const ROOM = bytes(16, 1)
const KEY = bytes(32, 7)
const TOKEN = bytes(16, 99)
const VIEW_LINK = `${encodeB64url(ROOM)}.${encodeB64url(KEY)}`
const CONTROL_LINK = `${encodeB64url(ROOM)}.${encodeB64url(new Uint8Array([...KEY, ...TOKEN]))}`

describe('parseCollabLink', () => {
  it('decodes a view link to a 16B room and 32B key', () => {
    const parsed = parseCollabLink(VIEW_LINK)
    expect(isParsedCollabLink(parsed)).toBe(true)
    if (!isParsedCollabLink(parsed)) return
    expect(parsed.roomId).toEqual(ROOM)
    expect(parsed.key).toEqual(KEY)
    expect(parsed.capability).toBe('view')
    expect(parsed.writeToken).toBeNull()
  })

  it('decodes a control link and splits the 48B secret', () => {
    const parsed = parseCollabLink(CONTROL_LINK)
    expect(isParsedCollabLink(parsed)).toBe(true)
    if (!isParsedCollabLink(parsed)) return
    expect(parsed.roomId).toEqual(ROOM)
    expect(parsed.key).toEqual(KEY)
    expect(parsed.capability).toBe('control')
    expect(parsed.writeToken).toEqual(TOKEN)
  })

  it('rejects links without a separator', () => {
    expect(parseCollabLink(encodeB64url(ROOM))).toEqual({ kind: 'missing-separator' })
  })

  it('rejects links with two separators', () => {
    expect(parseCollabLink(`${VIEW_LINK}.extra`)).toEqual({ kind: 'missing-separator' })
  })

  it('rejects a room id of the wrong length', () => {
    const bad = `${encodeB64url(bytes(15, 1))}.${encodeB64url(KEY)}`
    expect(parseCollabLink(bad)).toEqual({ kind: 'invalid-room-id' })
  })

  it('rejects padded base64 spellings', () => {
    // Padding is not part of the minted alphabet; strict decode refuses it.
    const paddedRoom = `${encodeB64url(ROOM)}==`
    expect(parseCollabLink(`${paddedRoom}.${encodeB64url(KEY)}`)).toEqual({
      kind: 'invalid-room-id',
    })
  })

  it('rejects a non-canonical secret spelling', () => {
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_'
    const secret = encodeB64url(KEY).split('')
    // Flip the low 2 (trailing, must-be-zero) bits of the final char: same
    // bytes, non-canonical spelling.
    const last = secret[secret.length - 1]
    if (last === undefined) throw new Error('unreachable: non-empty secret')
    const lastValue = alphabet.indexOf(last)
    const flipped = alphabet[(lastValue & 0x3c) | 0x01]
    if (flipped === undefined) throw new Error('unreachable: alphabet index')
    secret[secret.length - 1] = flipped
    const parsed = parseCollabLink(`${encodeB64url(ROOM)}.${secret.join('')}`)
    expect(isParsedCollabLink(parsed)).toBe(false)
  })

  it('rejects a secret of the wrong length', () => {
    const bad = `${encodeB64url(ROOM)}.${encodeB64url(bytes(33, 2))}`
    expect(parseCollabLink(bad)).toEqual({ kind: 'invalid-secret-length', bytes: 33 })
  })

  it('rejects an undecodable secret', () => {
    const bad = `${encodeB64url(ROOM)}.!!!`
    expect(parseCollabLink(bad)).toEqual({ kind: 'invalid-secret' })
  })
})

describe('parseCollabWebLink', () => {
  it('decodes the fragment after the last hash', () => {
    const parsed = parseCollabWebLink(`https://relay.example:8443/#${VIEW_LINK}`)
    expect(isParsedCollabLink(parsed)).toBe(true)
  })

  it('reports a missing fragment', () => {
    expect(parseCollabWebLink('https://relay.example:8443/')).toEqual({ kind: 'missing-fragment' })
  })
})

describe('hashLooksLikeCollabLink', () => {
  it('accepts a share-link hash', () => {
    expect(hashLooksLikeCollabLink(`#${CONTROL_LINK}`)).toBe(true)
  })

  it('rejects dashboard routes and empty hashes', () => {
    expect(hashLooksLikeCollabLink('#overview')).toBe(false)
    expect(hashLooksLikeCollabLink('#command?section=operations')).toBe(false)
    expect(hashLooksLikeCollabLink('')).toBe(false)
    expect(hashLooksLikeCollabLink('#')).toBe(false)
  })
})

describe('collabGuestResource', () => {
  it('renders /r/<room>?role=guest', () => {
    expect(collabGuestResource(ROOM)).toBe(`/r/${encodeB64url(ROOM)}?role=guest`)
  })
})
