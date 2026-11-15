// What the console sends about the invitations of the account server and how
// it reads the answers (lib/auth/login_invite_routes.mli, `issue`, `list` and
// `revoke`). Only the session of an Admin is answered. An answer that is not
// what the route promises is not read.

import { isRecord } from '../lib/type-guards'
import { bodyOf, csrfHeader, deliver, get, problemOf } from './wire'
import type { Answer, Send } from './wire'

export const invitesPath = '/api/v1/auth/invites'

/** The page a link of an invitation opens; the token is the part after `#`. */
const invitePagePrefix = '/accounts/invite#'

/** The role a person who joins through an invitation takes. */
export type InviteRole = 'member' | 'admin'

export const inviteRoles: readonly InviteRole[] = ['member', 'admin']

/** Who made an invitation: the operator of the host, with `masc auth`, or an Admin. */
export type Issuer = { readonly kind: 'local_operator' } | { readonly kind: 'admin'; readonly userId: string }

/** What the server says of an invitation now. `revocation_pending` is a
    revocation the log did not record: no one joins through the invitation,
    and revoking it again closes it. `unrecognised` is a word this console
    does not know. */
export type InviteStatus = 'open' | 'expired' | 'revocation_pending' | 'revoked' | 'consumed' | 'unrecognised'

const statuses = ['open', 'expired', 'revocation_pending', 'revoked', 'consumed'] as const

export interface Invite {
  readonly id: string
  readonly role: InviteRole
  readonly issuer: Issuer
  readonly expiresAtMs: number
  readonly status: InviteStatus
  /** The person who joined through it. Only a consumed invitation has one. */
  readonly joined: string | null
}

/** An invitation just made. `link` is a path on the account server, and the
    token in it is shown once: the server keeps only a digest of it. */
export interface Issued {
  readonly id: string
  readonly role: InviteRole
  readonly expiresAtMs: number
  readonly link: string
}

/** The last millisecond a `Date` holds (ECMAScript, Time Values and Time Range). */
const lastDateMs = 8_640_000_000_000_000

const text = (value: unknown): string | null => (typeof value === 'string' && value !== '' ? value : null)
const time = (value: unknown): number | null =>
  typeof value === 'number' && Number.isSafeInteger(value) && value >= 0 && value <= lastDateMs ? value : null
const readRole = (value: unknown): InviteRole | null => inviteRoles.find((role) => role === value) ?? null

function readIssuer(json: unknown): Issuer | null {
  if (!isRecord(json)) return null
  const members = Object.keys(json).join(',')
  if (json.kind === 'local_operator' && members === 'kind') return { kind: 'local_operator' }
  const userId = text(json.user_id)
  return json.kind === 'admin' && members === 'kind,user_id' && userId !== null ? { kind: 'admin', userId } : null
}

function readInvite(json: unknown): Invite | null {
  if (!isRecord(json)) return null
  const id = text(json.invite_id)
  const role = readRole(json.role)
  const issuer = readIssuer(json.issuer)
  const expiresAtMs = time(json.expires_at_ms)
  if (id === null || role === null || issuer === null || expiresAtMs === null || typeof json.status !== 'string') return null
  const status = statuses.find((known) => known === json.status) ?? 'unrecognised'
  const joined = 'user_id' in json ? text(json.user_id) : null
  // The server names the person who joined for a consumed invitation, and
  // only for one. A word this console does not know may come with one or not.
  if ('user_id' in json && joined === null) return null
  if (status !== 'unrecognised' && (status === 'consumed') !== (joined !== null)) return null
  return { id, role, issuer, expiresAtMs, status, joined }
}

/** Every invitation, or null when any is not what the route promises. */
export function readInvites(json: unknown): readonly Invite[] | null {
  if (!isRecord(json) || !Array.isArray(json.invites)) return null
  const invites = (json.invites as readonly unknown[]).map(readInvite)
  if (!invites.every((one): one is Invite => one !== null)) return null
  return new Set(invites.map((one) => one.id)).size === invites.length ? invites : null
}

export function readIssued(json: unknown): Issued | null {
  if (!isRecord(json)) return null
  const id = text(json.invite_id)
  const role = readRole(json.role)
  const expiresAtMs = time(json.expires_at_ms)
  const link = text(json.link)
  const token = link?.startsWith(invitePagePrefix) === true ? link.slice(invitePagePrefix.length) : ''
  return id === null || role === null || expiresAtMs === null || link === null || token === '' ? null : { id, role, expiresAtMs, link }
}

/** The address a person opens: the link on the server the page came from. */
export const addressOf = (issued: Issued, origin: string): string => new URL(issued.link, origin).href

export const list = (to: Send): Promise<Answer<readonly Invite[]>> => get(to, invitesPath, readInvites)

/** Makes an invitation for `role`. */
export async function issue(to: Send, csrfToken: string, role: InviteRole): Promise<Answer<Issued>> {
  const response = await deliver(to, invitesPath, {
    method: 'POST',
    headers: { accept: 'application/json', 'content-type': 'application/json', [csrfHeader]: csrfToken },
    body: JSON.stringify({ role }),
  })
  if (response === null) return { ok: false, problem: { kind: 'unreachable' } }
  if (!response.ok) return { ok: false, problem: await problemOf(response) }
  const value = readIssued(await bodyOf(response))
  return value === null ? { ok: false, problem: { kind: 'unreadable' } } : { ok: true, value }
}

/** Revokes the invitation `id`. The server answers 204. */
export async function revoke(to: Send, csrfToken: string, id: string): Promise<Answer<null>> {
  const response = await deliver(to, `${invitesPath}/${encodeURIComponent(id)}`, {
    method: 'DELETE',
    headers: { accept: 'application/json', [csrfHeader]: csrfToken },
  })
  if (response === null) return { ok: false, problem: { kind: 'unreachable' } }
  if (response.status === 204) return { ok: true, value: null }
  if (!response.ok) return { ok: false, problem: await problemOf(response) }
  return { ok: false, problem: { kind: 'unreadable' } }
}
