// MASC collab web viewer — share-link codec (RFC-0471 §2.2).
//
// Ports Collab_link's strict decode: a terminal link is
// `<b64url-16B>.<b64url-32|48B>`; a web link carries it in the URL fragment
// only (`<base>/#<link>`), so the secret never reaches server or relay logs.
// Anything that is not exactly that shape is an error — no repair, no default.

export const COLLAB_ROOM_BYTES = 16
export const COLLAB_KEY_BYTES = 32
export const COLLAB_WRITE_TOKEN_BYTES = 16
export const COLLAB_CONTROL_SECRET_BYTES = COLLAB_KEY_BYTES + COLLAB_WRITE_TOKEN_BYTES

export type CollabCapability = 'view' | 'control'

export type CollabLinkError =
  | { kind: 'missing-fragment' }
  | { kind: 'missing-separator' }
  | { kind: 'invalid-room-id' }
  | { kind: 'invalid-secret' }
  | { kind: 'invalid-secret-length'; bytes: number }

export interface ParsedCollabLink {
  /** Raw 16-byte room id. Public routing material. */
  roomId: Uint8Array
  /** Raw 32-byte AES-256 room key. Fragment-only, never logged. */
  key: Uint8Array
  capability: CollabCapability
  /** Raw 16-byte write token iff capability is control. */
  writeToken: Uint8Array | null
}

const B64URL_ALPHABET = /^[A-Za-z0-9_-]*$/

function decodeB64urlStrict(raw: string): Uint8Array | null {
  if (raw.length === 0 || !B64URL_ALPHABET.test(raw)) return null
  // Unpadded base64url: a length of 1 mod 4 can never decode.
  if (raw.length % 4 === 1) return null
  const padded = raw + '='.repeat((4 - (raw.length % 4)) % 4)
  const b64 = padded.replace(/-/g, '+').replace(/_/g, '/')
  try {
    const bin = atob(b64)
    const out = new Uint8Array(bin.length)
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i)
    // Round-trip check: reject non-canonical spellings (trailing-bit
    // variants decode the same bytes but are not the minted spelling).
    if (encodeB64url(out) !== raw) return null
    return out
  } catch {
    return null
  }
}

export function encodeB64url(bytes: Uint8Array): string {
  let bin = ''
  for (const byte of bytes) bin += String.fromCharCode(byte)
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

/** Strict decode of a terminal link (`<room>.<secret>`). */
export function parseCollabLink(link: string): ParsedCollabLink | CollabLinkError {
  const trimmed = link.trim()
  const dot = trimmed.indexOf('.')
  if (dot < 0) return { kind: 'missing-separator' }
  if (trimmed.indexOf('.', dot + 1) >= 0) return { kind: 'missing-separator' }
  const roomId = decodeB64urlStrict(trimmed.slice(0, dot))
  if (!roomId || roomId.length !== COLLAB_ROOM_BYTES) return { kind: 'invalid-room-id' }
  const secret = decodeB64urlStrict(trimmed.slice(dot + 1))
  if (!secret) return { kind: 'invalid-secret' }
  if (secret.length === COLLAB_KEY_BYTES) {
    return { roomId, key: secret, capability: 'view', writeToken: null }
  }
  if (secret.length === COLLAB_CONTROL_SECRET_BYTES) {
    return {
      roomId,
      key: secret.slice(0, COLLAB_KEY_BYTES),
      capability: 'control',
      writeToken: secret.slice(COLLAB_KEY_BYTES),
    }
  }
  return { kind: 'invalid-secret-length', bytes: secret.length }
}

export function isParsedCollabLink(
  value: ParsedCollabLink | CollabLinkError,
): value is ParsedCollabLink {
  return (value as ParsedCollabLink).roomId instanceof Uint8Array
}

/**
 * Decode the fragment after the last `#` as a terminal link. A URL without
 * `#` is `missing-fragment`. The base is caller's business (same-origin
 * dial); only the fragment is read here.
 */
export function parseCollabWebLink(url: string): ParsedCollabLink | CollabLinkError {
  const hash = url.lastIndexOf('#')
  if (hash < 0) return { kind: 'missing-fragment' }
  return parseCollabLink(url.slice(hash + 1))
}

/** True when `location.hash` carries a well-formed collab share link. */
export function hashLooksLikeCollabLink(hash: string): boolean {
  const body = hash.startsWith('#') ? hash.slice(1) : hash
  if (body.length === 0) return false
  return isParsedCollabLink(parseCollabLink(body))
}

export function collabLinkErrorText(error: CollabLinkError): string {
  switch (error.kind) {
    case 'missing-fragment':
      return 'This URL has no share link (missing #fragment).'
    case 'missing-separator':
      return 'This share link is malformed (expected <room>.<secret>).'
    case 'invalid-room-id':
      return 'This share link names an invalid room.'
    case 'invalid-secret':
      return 'This share link carries an undecodable secret.'
    case 'invalid-secret-length':
      return `This share link carries a ${error.bytes}-byte secret (expected 32 or 48).`
  }
}

/** `/r/<b64url-room>?role=guest`, mirroring Collab_guest_join.resource. */
export function collabGuestResource(roomId: Uint8Array): string {
  return `/r/${encodeB64url(roomId)}?role=guest`
}
