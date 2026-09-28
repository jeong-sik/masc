// MASC collab web viewer — AES-256-GCM sealing (RFC-0471 §2.3).
//
// Ports Collab_seal over WebCrypto: sealed layout is
// `[12B IV][ciphertext+tag]` with a fresh random IV per seal, identical to
// the host's `Mirage_crypto.AES.GCM` bytes. The 128-bit GCM tag rides
// appended to the ciphertext on both sides.

export const COLLAB_IV_BYTES = 12
export const COLLAB_KEY_BYTES = 32

export type CollabOpenError =
  | { kind: 'sealed-too-short' }
  | { kind: 'authentication-failed' }

function subtle(): SubtleCrypto {
  const cryptoRef = globalThis.crypto
  if (!cryptoRef?.subtle) throw new Error('WebCrypto is unavailable in this browser')
  return cryptoRef.subtle
}

/** Import a 32-byte room key for seal/open. Any other length throws. */
export async function importCollabKey(keyBytes: Uint8Array): Promise<CryptoKey> {
  if (keyBytes.length !== COLLAB_KEY_BYTES) {
    throw new Error(`collab room key must be ${COLLAB_KEY_BYTES} bytes`)
  }
  const copy: Uint8Array<ArrayBuffer> = new Uint8Array(keyBytes)
  return subtle().importKey('raw', copy, { name: 'AES-GCM', length: 256 }, false, [
    'encrypt',
    'decrypt',
  ])
}

/** Seal plaintext: `[12B random IV][ciphertext+tag]`. */
export async function sealCollabFrame(
  key: CryptoKey,
  plaintext: Uint8Array,
): Promise<Uint8Array> {
  const iv = globalThis.crypto.getRandomValues(new Uint8Array(COLLAB_IV_BYTES))
  const body: Uint8Array<ArrayBuffer> = new Uint8Array(plaintext)
  const ciphertext = new Uint8Array(
    await subtle().encrypt({ name: 'AES-GCM', iv, tagLength: 128 }, key, body),
  )
  const out = new Uint8Array(iv.length + ciphertext.length)
  out.set(iv, 0)
  out.set(ciphertext, iv.length)
  return out
}

/** Open sealed bytes. Too-short input and tag mismatch are typed errors. */
export async function openCollabFrame(
  key: CryptoKey,
  sealed: Uint8Array,
): Promise<Uint8Array | CollabOpenError> {
  if (sealed.length <= COLLAB_IV_BYTES) return { kind: 'sealed-too-short' }
  const iv: Uint8Array<ArrayBuffer> = new Uint8Array(sealed.slice(0, COLLAB_IV_BYTES))
  const body: Uint8Array<ArrayBuffer> = new Uint8Array(sealed.slice(COLLAB_IV_BYTES))
  try {
    const plaintext = await subtle().decrypt({ name: 'AES-GCM', iv, tagLength: 128 }, key, body)
    return new Uint8Array(plaintext)
  } catch {
    return { kind: 'authentication-failed' }
  }
}

export function isCollabOpenError(
  value: Uint8Array | CollabOpenError,
): value is CollabOpenError {
  return (value as CollabOpenError).kind !== undefined
}

export const collabTextEncoder = new TextEncoder()
export const collabTextDecoder = new TextDecoder()
