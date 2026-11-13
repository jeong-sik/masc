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

/**
 * Why the models of a subscription are not called on this server
 * (lib/server/server_person_integrations.ml, `refusal_code`). A code this
 * console does not know is kept apart: the console says the calls are
 * refused, and not why.
 */
export type CallRefusal =
  | 'native_unpublished'
  | 'native_tools_reach_other_homes'
  | 'native_tools_reach_person_homes'
  | 'person_homes_unread'
  | 'unrecognised'

/** Whether a Keeper may run on an account of the subscription here. */
export type Calls = { readonly kind: 'allowed' } | { readonly kind: 'refused'; readonly refusal: CallRefusal }

/** A subscription a person may connect: a provider of the workspace. */
export interface Integration {
  readonly id: string
  /** As the operator wrote it, which may be empty. */
  readonly displayName: string
  /** The models a verification of an account of it may name. */
  readonly models: readonly string[]
  readonly calls: Calls
}

/** A fact the server read, or the code of why it could not. A code this
    console does not know is kept apart as `unrecognised`. */
export type Fact<T, Unread extends string> =
  | { readonly read: true; readonly value: T }
  | { readonly read: false; readonly unread: Unread | 'unrecognised' }

/** Why the subscription of an account is not known (lib/auth_preview.ml). */
export type IntegrationUnread = 'login_receipt_missing' | 'login_receipt_unreadable'

/** Why the model of a Runtime is not known (lib/auth_preview.ml,
    `provider_accounts`). A Runtime id names its binding, so of the codes of
    lib/runtime/runtime_account_runtime.ml (`error_code`) only the last two
    come. */
export type ModelUnread =
  | 'account_integration_unread'
  | 'configuration_unavailable'
  | 'template_not_declared'
  | 'runtime_not_bound'

/** A subscription account the person connected. */
export interface ProviderAccount {
  readonly id: string
  /** The id of the subscription its login was of. */
  readonly integration: Fact<string, IntegrationUnread>
}

/** A Runtime the person made: a model called through one of their accounts. */
export interface Runtime {
  readonly id: string
  readonly accountId: string
  readonly model: Fact<string, ModelUnread>
}

/** The accounts and the Runtimes a person owns. */
export interface Owned {
  readonly accounts: readonly ProviderAccount[]
  readonly runtimes: readonly Runtime[]
}

export const paths = {
  session: '/auth/session',
  signOut: '/auth/logout',
  who: '/api/v1/auth/whoami',
  integrations: '/api/v1/auth/integrations',
  owned: '/api/v1/auth/provider-accounts',
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

/** Each item read, or null when any item is not what the route promises. */
function readList<T>(value: unknown, read: (item: unknown) => T | null): readonly T[] | null {
  if (!Array.isArray(value)) return null
  const items: T[] = []
  for (const item of value as readonly unknown[]) {
    const one = read(item)
    if (one === null) return null
    items.push(one)
  }
  return items
}

function readCallRefusal(code: string): CallRefusal {
  switch (code) {
    case 'native_unpublished':
    case 'native_tools_reach_other_homes':
    case 'native_tools_reach_person_homes':
    case 'person_homes_unread':
      return code
    default: return 'unrecognised'
  }
}

function readCalls(json: Readonly<Record<string, unknown>>): Calls | null {
  switch (json.calls) {
    case 'allowed': return { kind: 'allowed' }
    case 'refused': {
      const code = text(json.refusal)
      return code === null ? null : { kind: 'refused', refusal: readCallRefusal(code) }
    }
    default: return null
  }
}

function readIntegration(json: unknown): Integration | null {
  if (!isRecord(json)) return null
  const id = text(json.integration_id)
  const models = readList(json.models, text)
  const calls = readCalls(json)
  if (id === null || typeof json.display_name !== 'string' || models === null || calls === null) return null
  return { id, displayName: json.display_name, models, calls }
}

export function readIntegrations(json: unknown): readonly Integration[] | null {
  return isRecord(json) ? readList(json.integrations, readIntegration) : null
}

/** The fact at `name`: its value, or null with the code of why it is not
    read. Anything else is not what the route promises. */
function readFact<Unread extends string>(
  json: Readonly<Record<string, unknown>>,
  name: string,
  readUnread: (code: string) => Unread | 'unrecognised',
): Fact<string, Unread> | null {
  const value = text(json[name])
  if (value !== null) return json.unread === undefined ? { read: true, value } : null
  const code = text(json.unread)
  return json[name] === null && code !== null ? { read: false, unread: readUnread(code) } : null
}

function readIntegrationUnread(code: string): IntegrationUnread | 'unrecognised' {
  switch (code) {
    case 'login_receipt_missing':
    case 'login_receipt_unreadable':
      return code
    default: return 'unrecognised'
  }
}

function readModelUnread(code: string): ModelUnread | 'unrecognised' {
  switch (code) {
    case 'account_integration_unread':
    case 'configuration_unavailable':
    case 'template_not_declared':
    case 'runtime_not_bound':
      return code
    default: return 'unrecognised'
  }
}

function readAccount(json: unknown): ProviderAccount | null {
  if (!isRecord(json)) return null
  const id = text(json.provider_account_id)
  const integration = readFact(json, 'integration_id', readIntegrationUnread)
  return id === null || integration === null ? null : { id, integration }
}

function readRuntime(json: unknown): Runtime | null {
  if (!isRecord(json)) return null
  const id = text(json.runtime_id)
  const accountId = text(json.provider_account_id)
  const model = readFact(json, 'model', readModelUnread)
  return id === null || accountId === null || model === null ? null : { id, accountId, model }
}

/** What a person owns. Every Runtime is on one of the accounts listed: the
    authorization log makes a Runtime only on an account its maker owns
    (lib/auth/authz_runtime_state.ml, `Account_not_theirs`), and never unlinks
    an account. An answer that breaks this is not what the route promises. */
export function readOwned(json: unknown): Owned | null {
  if (!isRecord(json)) return null
  const accounts = readList(json.provider_accounts, readAccount)
  const runtimes = readList(json.runtimes, readRuntime)
  if (accounts === null || runtimes === null) return null
  const listed = new Set(accounts.map((account) => account.id))
  return runtimes.every((runtime) => listed.has(runtime.accountId)) ? { accounts, runtimes } : null
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
export const integrations = (to: Send): Promise<Answer<readonly Integration[]>> => get(to, paths.integrations, readIntegrations)
export const owned = (to: Send): Promise<Answer<Owned>> => get(to, paths.owned, readOwned)

/** Ends the session. The server answers 204 and clears the cookie. */
export async function signOut(to: Send, csrfToken: string): Promise<Answer<null>> {
  const response = await send(to, paths.signOut, { method: 'POST', headers: { accept: 'application/json', [csrfHeader]: csrfToken } })
  if (response === null) return { ok: false, problem: { kind: 'unreachable' } }
  if (response.status === 204) return { ok: true, value: null }
  if (!response.ok) return { ok: false, problem: refusal(response.status, await bodyOf(response)) }
  return { ok: false, problem: { kind: 'unreadable' } }
}
