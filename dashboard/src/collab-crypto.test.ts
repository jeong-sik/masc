import { describe, expect, it } from 'vitest'
import {
  COLLAB_IV_BYTES,
  importCollabKey,
  isCollabOpenError,
  openCollabFrame,
  sealCollabFrame,
  collabTextDecoder,
  collabTextEncoder,
} from './collab-crypto'

function keyBytes(seed: number): Uint8Array {
  const out = new Uint8Array(32)
  for (let i = 0; i < 32; i++) out[i] = (seed + i * 11) % 256
  return out
}

describe('collab-crypto', () => {
  it('round-trips a frame through seal/open', async () => {
    const key = await importCollabKey(keyBytes(3))
    const plaintext = collabTextEncoder.encode('{"t":"hello","proto":1}')
    const sealed = await sealCollabFrame(key, plaintext)
    // [12B IV][ciphertext+16B tag].
    expect(sealed.length).toBe(COLLAB_IV_BYTES + plaintext.length + 16)
    const opened = await openCollabFrame(key, sealed)
    expect(isCollabOpenError(opened)).toBe(false)
    if (isCollabOpenError(opened)) return
    expect(collabTextDecoder.decode(opened)).toBe('{"t":"hello","proto":1}')
  })

  it('mints a fresh IV per seal', async () => {
    const key = await importCollabKey(keyBytes(3))
    const plaintext = collabTextEncoder.encode('same bytes')
    const first = await sealCollabFrame(key, plaintext)
    const second = await sealCollabFrame(key, plaintext)
    expect(first).not.toEqual(second)
    expect(first.slice(0, COLLAB_IV_BYTES)).not.toEqual(second.slice(0, COLLAB_IV_BYTES))
  })

  it('rejects tampered ciphertext', async () => {
    const key = await importCollabKey(keyBytes(3))
    const sealed = await sealCollabFrame(key, collabTextEncoder.encode('payload'))
    const lastByte = sealed[sealed.length - 1]
    if (lastByte === undefined) throw new Error('unreachable: non-empty sealed frame')
    sealed[sealed.length - 1] = lastByte ^ 0x01
    expect(await openCollabFrame(key, sealed)).toEqual({ kind: 'authentication-failed' })
  })

  it('rejects the wrong key', async () => {
    const key = await importCollabKey(keyBytes(3))
    const other = await importCollabKey(keyBytes(9))
    const sealed = await sealCollabFrame(key, collabTextEncoder.encode('payload'))
    expect(await openCollabFrame(other, sealed)).toEqual({ kind: 'authentication-failed' })
  })

  it('rejects truncated input', async () => {
    const key = await importCollabKey(keyBytes(3))
    expect(await openCollabFrame(key, new Uint8Array(COLLAB_IV_BYTES))).toEqual({
      kind: 'sealed-too-short',
    })
  })

  it('refuses a short key at import', async () => {
    await expect(importCollabKey(new Uint8Array(16))).rejects.toThrow()
  })
})
