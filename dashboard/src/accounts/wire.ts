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

/** The first status of an answer that is a failure, not a refusal: the
    server, or what stands in front of it, did not say that it did nothing. */
export const serverFailure = 500

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

/** The codes this console has words for, of those the server gives for a
    model the operator bound to a subscription that is not one a person may
    name (lib/server/server_person_integrations.ml, `withheld_code`): a model
    with no row, and the refusal of a row a verification ends with today
    (`Runtime_verification.model_refusal`). */
const withheldCodes = ['tools_not_declared', 'model_undeclared'] as const

/** Why such a model is left out. A code this console does not know is kept
    apart: the console says the model is left out, and not why. */
export type WithheldReason = typeof withheldCodes[number] | 'unrecognised'

/** Every reason, in the order the page says them. */
export const withheldReasons: readonly WithheldReason[] = [...withheldCodes, 'unrecognised']

/** A model of a subscription that is not in its `models`, and why. */
export interface Withheld {
  readonly model: string
  readonly reason: WithheldReason
}

/** A subscription a person may connect: a provider of the workspace. */
export interface Integration {
  readonly id: string
  /** As the operator wrote it, which may be empty. */
  readonly displayName: string
  /** The models a verification of an account of it may name. */
  readonly models: readonly string[]
  /** The other models the operator bound to it. With none of either, the operator bound no model. */
  readonly withheld: readonly Withheld[]
  readonly calls: Calls
  /** Whether a person registers an API key of their own for it, beside the
      login every subscription of the list takes (`connect` of
      lib/server/server_person_integrations.ml). */
  readonly takesKey: boolean
}

/** Whether a model of the subscription can be checked here now: the server
    calls its models and offers one. A check makes the Runtime a Keeper runs
    on, so an account connected now comes to run a Keeper only on such a
    subscription. A Runtime made by an earlier check is another matter: the
    page reads that from the Runtime (`Runtime.model`). */
export const checkable = (one: Integration): boolean => one.calls.kind === 'allowed' && one.models.length > 0

/** The name the operator gave a subscription, or its id when the name is empty. */
export const integrationName = (integration: Integration): string =>
  integration.displayName === '' ? integration.id : integration.displayName

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

/** What the server found of the key file of a key account
    (lib/auth_preview.ml, `key_code`): a key it can read, no file, a file
    that gives no key, or a place it could not look at. It is what was there
    at the reading: while a registration, a replacement or a removal of the account runs,
    the file can be missing for that moment. */
const keyStates = ['readable', 'key_missing', 'key_unreadable', 'not_looked_at'] as const
export type KeyState = typeof keyStates[number] | 'unrecognised'

/** What an account holds: a login of the subscription, or an API key the
    person registered. */
export type Held =
  | { readonly kind: 'login' }
  | { readonly kind: 'key'; readonly key: KeyState }

/** What is left of a removal of an account that did not go through
    (lib/auth_preview.ml, `removal_code`): the stage that stayed, or a start
    the server gave up. Nothing runs on such an account, and its owner asks
    for the removal again. */
const removals = ['key_not_removed', 'home_not_removed', 'start_given_up'] as const
export type Removal = typeof removals[number] | 'unrecognised'

/** What is left of a replacement of the key of an account that did not go
    through (lib/auth_preview.ml, `provider_accounts`): a start the server
    gave up. Nothing runs on such an account until its owner sends a key for
    it again, or removes it. */
const replacements = ['start_given_up'] as const
export type Replacement = typeof replacements[number] | 'unrecognised'

/** What a step that did not go through left on an account. The server names
    one at most: an account both were left on is listed with its removal,
    which is what is done next with it. */
export type Left =
  | { readonly kind: 'removal'; readonly stage: Removal }
  | { readonly kind: 'replacement'; readonly stage: Replacement }

/** A subscription account the person connected. An account whose removal
    is under way or went through is not listed. */
export interface ProviderAccount {
  readonly id: string
  /** The id of the subscription: the one its login was of, or the one its
      key was registered for. */
  readonly integration: Fact<string, IntegrationUnread>
  readonly held: Held
  /** Null for an account nothing was left on. */
  readonly left: Left | null
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

const readWithheldReason = (code: string): WithheldReason => withheldCodes.find((known) => known === code) ?? 'unrecognised'

function readWithheld(json: unknown): Withheld | null {
  if (!isRecord(json)) return null
  const model = text(json.model)
  const reason = text(json.reason)
  return model === null || reason === null ? null : { model, reason: readWithheldReason(reason) }
}

function readIntegration(json: unknown): Integration | null {
  if (!isRecord(json)) return null
  const id = text(json.integration_id)
  const models = readList(json.models, text)
  const withheld = readList(json.withheld, readWithheld)
  const calls = readCalls(json)
  // How a person connects it: a login, and a key where one is taken. A way
  // named later is one this console has no control for.
  const connect = readList(json.connect, text)
  if (id === null || typeof json.display_name !== 'string' || models === null || withheld === null || calls === null || connect === null) return null
  return { id, displayName: json.display_name, models, withheld, calls, takesKey: connect.includes('key') }
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

/** What the account holds. A key account says of its key file, and a login
    account says nothing of a key. Another kind is not what the route
    promises. */
function readHeld(json: Readonly<Record<string, unknown>>): Held | null {
  switch (json.kind) {
    case 'login': return json.key === undefined ? { kind: 'login' } : null
    case 'key': {
      const state = text(json.key)
      return state === null ? null : { kind: 'key', key: keyStates.find((known) => known === state) ?? 'unrecognised' }
    }
    default: return null
  }
}

/** What was left on the account: null when the answer names nothing. An
    answer that names a removal and a replacement is not what the route
    promises. */
function readLeft(json: Readonly<Record<string, unknown>>): Left | null | undefined {
  const { removal, replacement } = json
  if (removal === undefined && replacement === undefined) return null
  if (removal !== undefined && replacement !== undefined) return undefined
  if (removal !== undefined) {
    const code = text(removal)
    return code === null ? undefined : { kind: 'removal', stage: removals.find((known) => known === code) ?? 'unrecognised' }
  }
  const code = text(replacement)
  return code === null ? undefined : { kind: 'replacement', stage: replacements.find((known) => known === code) ?? 'unrecognised' }
}

function readAccount(json: unknown): ProviderAccount | null {
  if (!isRecord(json)) return null
  const id = text(json.provider_account_id)
  const integration = readFact(json, 'integration_id', readIntegrationUnread)
  const held = readHeld(json)
  const left = readLeft(json)
  return id === null || integration === null || held === null || left === undefined ? null : { id, integration, held, left }
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
    (lib/auth/authz_runtime_state.ml, `Account_not_theirs`), and the server
    lists no Runtime of an account it does not list (lib/auth_preview.ml,
    `provider_accounts`). An answer that breaks this is not what the route
    promises. */
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
export async function bodyOf(response: Response): Promise<unknown> {
  try {
    return await response.json() as unknown
  } catch {
    return undefined
  }
}

/** Why the server refused a request, read from its answer. */
export const problemOf = async (response: Response): Promise<Problem> => refusal(response.status, await bodyOf(response))

/** Sends a request with the session cookie, or gives null when no answer came. */
export async function deliver(to: Send, path: string, init: RequestInit): Promise<Response | null> {
  try {
    return await to(path, { ...init, credentials: 'same-origin' })
  } catch {
    // `fetch` rejects when no answer came: the network, or a server that is down.
    return null
  }
}

export async function get<T>(to: Send, path: string, read: (json: unknown) => T | null): Promise<Answer<T>> {
  const response = await deliver(to, path, { method: 'GET', headers: { accept: 'application/json' } })
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
  const response = await deliver(to, paths.signOut, { method: 'POST', headers: { accept: 'application/json', [csrfHeader]: csrfToken } })
  if (response === null) return { ok: false, problem: { kind: 'unreachable' } }
  if (response.status === 204) return { ok: true, value: null }
  if (!response.ok) return { ok: false, problem: await problemOf(response) }
  return { ok: false, problem: { kind: 'unreadable' } }
}
