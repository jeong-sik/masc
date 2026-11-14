// What the console sends about the tokens (scoped PATs) of a signed-in person
// and how it reads the answers (lib/auth/login_pat_routes.mli, `issue`,
// `list` and `revoke`). An answer that is not what the route promises is
// not read.

import { isRecord } from '../lib/type-guards'
import { bodyOf, csrfHeader, deliver, get, problemOf } from './wire'
import type { Answer, Send } from './wire'

export const patsPath = '/api/v1/auth/pats'

/** What a dimension of a scope reaches: everything, or the labels listed. */
export type Reach = 'all' | readonly string[]

/** What a token may reach (lib/auth/authz_scope_body.mli). */
export interface Scope {
  readonly runtimes: Reach
  readonly channels: Reach
  readonly effects: Reach
}

/** The labels of a channel and of an effect (lib/auth/authz_types.ml, `to_string`). */
const channels = ['direct', 'delegate', 'schedule', 'board_trigger', 'retry', 'resume', 'fusion', 'vision', 'verifier', 'autonomous'] as const
const effects = [
  'read_state', 'invoke_model', 'use_tool', 'manage_own_provider', 'manage_own_runtime', 'manage_own_grant',
  'manage_own_keeper', 'manage_machine_shared', 'admin_disable_block', 'read_audit_metadata',
] as const

/** What a person makes a token for. The scope of each is the one
    docs/guides/account-server-mcp.md gives: `read_only` reaches whoami, and
    `mcp` reaches every tool of the endpoint, a Keeper's turn among them. */
export type Use = 'read_only' | 'mcp'

export const uses: readonly Use[] = ['read_only', 'mcp']

export function scopeOf(use: Use): Scope {
  switch (use) {
    case 'read_only': return { runtimes: 'all', channels: ['direct'], effects: ['read_state'] }
    case 'mcp': return { runtimes: 'all', channels: ['direct'], effects: ['invoke_model', 'manage_own_keeper', 'manage_own_provider', 'read_state', 'use_tool'] }
  }
}

const sameReach = (a: Reach, b: Reach): boolean =>
  a === 'all' || b === 'all' ? a === b : a.length === b.length && a.every((label, at) => label === b[at])

const sameScope = (a: Scope, b: Scope): boolean =>
  sameReach(a.runtimes, b.runtimes) && sameReach(a.channels, b.channels) && sameReach(a.effects, b.effects)

/** The use whose scope `scope` is, or null for a scope made some other way
    (the page at `/` takes any scope). */
export const useOf = (scope: Scope): Use | null => uses.find((use) => sameScope(scopeOf(use), scope)) ?? null

/** What the server says of a token now. `unknown` is the server's own word
    for a token its state lost; `unrecognised` a word this console does not know. */
export type PatStatus = 'open' | 'expired' | 'revoked' | 'unknown' | 'unrecognised'

const statuses = ['open', 'expired', 'revoked', 'unknown'] as const

export interface Pat {
  readonly id: string
  readonly scope: Scope
  /** Null for a token that does not expire. */
  readonly expiresAtMs: number | null
  readonly issuedAtMs: number
  readonly status: PatStatus
}

/** A token just made. `token` is shown once: the server never gives it again. */
export interface Issued {
  readonly id: string
  readonly token: string
}

/** The last millisecond a `Date` holds (ECMAScript, Time Values and Time Range). */
const lastDateMs = 8_640_000_000_000_000

const text = (value: unknown): string | null => (typeof value === 'string' && value !== '' ? value : null)
const time = (value: unknown): number | null =>
  typeof value === 'number' && Number.isSafeInteger(value) && value >= 0 && value <= lastDateMs ? value : null

/** A dimension of a scope: "all", or labels in strictly ascending order,
    each one `known` allows. One scope has one body, so any other order is
    not read. */
function readReach(json: unknown, known: (label: string) => boolean): Reach | null {
  if (json === 'all') return 'all'
  if (!Array.isArray(json)) return null
  const labels: string[] = []
  for (const one of json as readonly unknown[]) {
    const label = text(one)
    if (label === null || !known(label)) return null
    const last = labels.at(-1)
    if (last !== undefined && !(last < label)) return null
    labels.push(label)
  }
  return labels
}

/** The members of a scope body, in the order the server writes and reads them. */
const scopeMembers = 'runtimes,channels,allowed_effects'

export function readScope(json: unknown): Scope | null {
  if (!isRecord(json) || Object.keys(json).join(',') !== scopeMembers) return null
  const runtimes = readReach(json.runtimes, () => true)
  const reached = readReach(json.channels, (label) => channels.some((known) => known === label))
  const allowed = readReach(json.allowed_effects, (label) => effects.some((known) => known === label))
  return runtimes === null || reached === null || allowed === null ? null : { runtimes, channels: reached, effects: allowed }
}

function readPat(json: unknown): Pat | null {
  if (!isRecord(json)) return null
  const id = text(json.pat_id)
  const scope = readScope(json.scope)
  const issuedAtMs = time(json.issued_at_ms)
  const expiresAtMs = json.expires_at_ms === null ? null : time(json.expires_at_ms)
  if (id === null || scope === null || issuedAtMs === null || (json.expires_at_ms !== null && expiresAtMs === null)) return null
  if (typeof json.status !== 'string') return null
  const status = statuses.find((known) => known === json.status) ?? 'unrecognised'
  return { id, scope, expiresAtMs, issuedAtMs, status }
}

/** The tokens of the person, or null when any is not what the route promises. */
export function readPats(json: unknown): readonly Pat[] | null {
  if (!isRecord(json) || !Array.isArray(json.pats)) return null
  const pats = (json.pats as readonly unknown[]).map(readPat)
  if (!pats.every((one): one is Pat => one !== null)) return null
  return new Set(pats.map((one) => one.id)).size === pats.length ? pats : null
}

export function readIssued(json: unknown): Issued | null {
  if (!isRecord(json)) return null
  const id = text(json.pat_id)
  const token = text(json.token)
  return id === null || token === null ? null : { id, token }
}

/** The body of a scope, its members in the order the server reads them. */
const bodyOfScope = (scope: Scope): Readonly<Record<string, unknown>> =>
  ({ runtimes: scope.runtimes, channels: scope.channels, allowed_effects: scope.effects })

export const list = (to: Send): Promise<Answer<readonly Pat[]>> => get(to, patsPath, readPats)

/** Makes a token of `scope` that expires at `expiresAtMs`, or never when it is null. */
export async function issue(to: Send, csrfToken: string, scope: Scope, expiresAtMs: number | null): Promise<Answer<Issued>> {
  const response = await deliver(to, patsPath, {
    method: 'POST',
    headers: { accept: 'application/json', 'content-type': 'application/json', [csrfHeader]: csrfToken },
    body: JSON.stringify({ scope: bodyOfScope(scope), expires_at_ms: expiresAtMs }),
  })
  if (response === null) return { ok: false, problem: { kind: 'unreachable' } }
  if (!response.ok) return { ok: false, problem: await problemOf(response) }
  const value = readIssued(await bodyOf(response))
  return value === null ? { ok: false, problem: { kind: 'unreadable' } } : { ok: true, value }
}

/** Revokes the token `id`. The server answers 204. */
export async function revoke(to: Send, csrfToken: string, id: string): Promise<Answer<null>> {
  const response = await deliver(to, `${patsPath}/${encodeURIComponent(id)}`, {
    method: 'DELETE',
    headers: { accept: 'application/json', [csrfHeader]: csrfToken },
  })
  if (response === null) return { ok: false, problem: { kind: 'unreachable' } }
  if (response.status === 204) return { ok: true, value: null }
  if (!response.ok) return { ok: false, problem: await problemOf(response) }
  return { ok: false, problem: { kind: 'unreadable' } }
}
