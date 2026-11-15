// What the console sends about the allowlist of the account server and how it
// reads the answers (lib/auth/login_allowlist_routes.mli, `register`, `list`
// and `remove`). Only the session of an Admin is answered. An answer that is
// not what the route promises is not read.

import { isRecord } from '../lib/type-guards'
import { readIdentity } from './members-wire'
import type { Identity } from './members-wire'
import { bodyOf, csrfHeader, deliver, get, problemOf } from './wire'
import type { Answer, Send } from './wire'

export const allowlistPath = '/api/v1/auth/allowlist'

/** An account an Admin can register: the two the server reads
    (lib/auth/authz_external_identity.mli). */
export type Registrable = Exclude<Identity, { readonly provider: 'unrecognised' }>

/** What the server says of an entry now. `removal_pending` is a removal the
    log did not record: no one joins through the entry, and removing it again
    closes it. A consumed entry names the person who joined through it, and
    no other does. `unrecognised` is a word this console does not know. */
export type EntryStatus =
  | { readonly kind: 'open' }
  | { readonly kind: 'removal_pending' }
  | { readonly kind: 'removed' }
  | { readonly kind: 'consumed'; readonly joined: string }
  | { readonly kind: 'unrecognised' }

export interface Entry {
  readonly id: string
  readonly identity: Identity
  /** The user id of the Admin who registered it. */
  readonly registrar: string
  readonly status: EntryStatus
}

/** An entry just registered. `previouslyDeleted` when a person who signed
    in with the account was deleted before: they join again as a new person. */
export interface Registered {
  readonly id: string
  readonly previouslyDeleted: boolean
}

const text = (value: unknown): string | null => (typeof value === 'string' && value !== '' ? value : null)

/** The status of an entry, with the person who joined: the server names one
    for a consumed entry, and for no other. A word this console does not
    know may come with one or not. */
function readStatus(json: Readonly<Record<string, unknown>>): EntryStatus | null {
  const joined = 'user_id' in json ? text(json.user_id) : null
  if ('user_id' in json && joined === null) return null
  const status = json.status
  switch (status) {
    case 'consumed':
      return joined === null ? null : { kind: 'consumed', joined }
    case 'open':
    case 'removal_pending':
    case 'removed':
      return joined === null ? { kind: status } : null
    default:
      return typeof status === 'string' ? { kind: 'unrecognised' } : null
  }
}

function readEntry(json: unknown): Entry | null {
  if (!isRecord(json)) return null
  const id = text(json.registration_id)
  const identity = readIdentity(json.identity)
  const registrar = text(json.registrar)
  const status = readStatus(json)
  return id === null || identity === null || registrar === null || status === null ? null : { id, identity, registrar, status }
}

/** Every entry, or null when any is not what the route promises. */
export function readEntries(json: unknown): readonly Entry[] | null {
  if (!isRecord(json) || !Array.isArray(json.registrations)) return null
  const entries = (json.registrations as readonly unknown[]).map(readEntry)
  if (!entries.every((one): one is Entry => one !== null)) return null
  return new Set(entries.map((one) => one.id)).size === entries.length ? entries : null
}

export function readRegistered(json: unknown): Registered | null {
  if (!isRecord(json)) return null
  const id = text(json.registration_id)
  return id === null || typeof json.previously_deleted !== 'boolean' ? null : { id, previouslyDeleted: json.previously_deleted }
}

/** The body of a registration, its members in the order the server reads them. */
const registrationBody = (identity: Registrable): Readonly<Record<string, unknown>> =>
  identity.provider === 'github' ? { provider: 'github', user_id: identity.userId } : { provider: 'google', sub: identity.sub }

export const list = (to: Send): Promise<Answer<readonly Entry[]>> => get(to, allowlistPath, readEntries)

/** Registers `identity`, so the person signs in at `/` and joins as a Member. */
export async function register(to: Send, csrfToken: string, identity: Registrable): Promise<Answer<Registered>> {
  const response = await deliver(to, allowlistPath, {
    method: 'POST',
    headers: { accept: 'application/json', 'content-type': 'application/json', [csrfHeader]: csrfToken },
    body: JSON.stringify(registrationBody(identity)),
  })
  if (response === null) return { ok: false, problem: { kind: 'unreachable' } }
  if (!response.ok) return { ok: false, problem: await problemOf(response) }
  const value = readRegistered(await bodyOf(response))
  return value === null ? { ok: false, problem: { kind: 'unreadable' } } : { ok: true, value }
}

/** Removes the entry `id`. The server answers 204. */
export async function remove(to: Send, csrfToken: string, id: string): Promise<Answer<null>> {
  const response = await deliver(to, `${allowlistPath}/${encodeURIComponent(id)}`, {
    method: 'DELETE',
    headers: { accept: 'application/json', [csrfHeader]: csrfToken },
  })
  if (response === null) return { ok: false, problem: { kind: 'unreachable' } }
  if (response.status === 204) return { ok: true, value: null }
  if (!response.ok) return { ok: false, problem: await problemOf(response) }
  return { ok: false, problem: { kind: 'unreadable' } }
}
