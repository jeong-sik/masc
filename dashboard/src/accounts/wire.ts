// What the account server answers to the console of a signed-in person, read
// into closed shapes. A reader takes the JSON of an answer and gives a value,
// or null when the JSON is not what the route promises; nothing after a
// reader looks at a field the reader did not check.
//
// The browser sends the session cookie by itself. A request that changes
// something carries the CSRF token of the session in a header. The console
// holds no bearer token and keeps nothing in web storage, so nothing of a
// session outlives the page.

import { isRecord } from '../lib/type-guards'

export interface Session {
  readonly userId: string
  /** Sent back in a header with every request that changes something. */
  readonly csrfToken: string
}

/**
 * The role of the person on this installation. The server says `admin` for
 * an Admin and `worker` for a Member (lib/auth_gate.ml, `role_of`). A name
 * this console does not know is kept apart: it gets what a Member gets and
 * no label, because the console cannot say what it may do.
 */
export type Role = 'admin' | 'member' | 'unrecognised'

export interface Who {
  readonly id: string
  readonly role: Role
}

/** Why a request did not give a value. */
export type Problem =
  /** No session came with the request: the person signs in again. */
  | { readonly kind: 'signed_out' }
  /** The server answered and refused. `reason` is its own sentence. */
  | { readonly kind: 'refused'; readonly status: number; readonly reason: string | null }
  /** The server answered as if all was well, in a shape this console cannot read. */
  | { readonly kind: 'unreadable' }
  /** No answer came at all. */
  | { readonly kind: 'unreachable' }

export type Answer<T> =
  | { readonly ok: true; readonly value: T }
  | { readonly ok: false; readonly problem: Problem }

/** How a request leaves the page. The page passes `fetch`; a test passes its own. */
export type Send = (path: string, init: RequestInit) => Promise<Response>

export const paths = {
  session: '/auth/session',
  signOut: '/auth/logout',
  who: '/api/v1/auth/whoami',
} as const

export const csrfHeader = 'x-masc-csrf-token'

const text = (value: unknown): string | null => (typeof value === 'string' && value !== '' ? value : null)

export function readSession(json: unknown): Session | null {
  if (!isRecord(json)) return null
  const userId = text(json.user_id)
  const csrfToken = text(json.csrf_token)
  return userId === null || csrfToken === null ? null : { userId, csrfToken }
}

function readRole(name: string): Role {
  switch (name) {
    case 'admin': return 'admin'
    case 'worker': return 'member'
    default: return 'unrecognised'
  }
}

export function readWho(json: unknown): Who | null {
  if (!isRecord(json) || !isRecord(json.principal)) return null
  const id = text(json.principal.id)
  const role = text(json.role)
  // A browser session belongs to a person. A service has no page to open.
  if (id === null || role === null || json.principal.kind !== 'human') return null
  return { id, role: readRole(role) }
}

const refusal = (status: number, json: unknown): Problem =>
  status === 401
    ? { kind: 'signed_out' }
    : { kind: 'refused', status, reason: isRecord(json) ? text(json.error) : null }

/** The JSON of a body, or undefined when the body is not JSON. */
async function bodyOf(response: Response): Promise<unknown> {
  try {
    return await response.json() as unknown
  } catch {
    return undefined
  }
}

async function send(to: Send, path: string, init: RequestInit): Promise<Response | null> {
  try {
    return await to(path, { ...init, credentials: 'same-origin' })
  } catch {
    // `fetch` rejects when no answer came: the network, or a server that is down.
    return null
  }
}

async function get<T>(to: Send, path: string, read: (json: unknown) => T | null): Promise<Answer<T>> {
  const response = await send(to, path, { method: 'GET', headers: { accept: 'application/json' } })
  if (response === null) return { ok: false, problem: { kind: 'unreachable' } }
  const json = await bodyOf(response)
  if (!response.ok) return { ok: false, problem: refusal(response.status, json) }
  const value = read(json)
  return value === null ? { ok: false, problem: { kind: 'unreadable' } } : { ok: true, value }
}

export const session = (to: Send): Promise<Answer<Session>> => get(to, paths.session, readSession)
export const who = (to: Send): Promise<Answer<Who>> => get(to, paths.who, readWho)

/** Ends the session. The server answers 204 and clears the cookie. */
export async function signOut(to: Send, csrfToken: string): Promise<Answer<null>> {
  const response = await send(to, paths.signOut, { method: 'POST', headers: { accept: 'application/json', [csrfHeader]: csrfToken } })
  if (response === null) return { ok: false, problem: { kind: 'unreachable' } }
  if (response.status === 204) return { ok: true, value: null }
  if (!response.ok) return { ok: false, problem: refusal(response.status, await bodyOf(response)) }
  return { ok: false, problem: { kind: 'unreadable' } }
}
