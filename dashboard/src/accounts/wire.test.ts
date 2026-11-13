// What the console reads from the account server, and what its requests
// carry. A reader that took a wrong answer for a right one would hand the
// frame a value no route promised.
import { describe, expect, it } from 'vitest'
import { csrfHeader, integrations, owned, paths, readIntegrations, readOwned, readSession, readWho, session, signOut, who } from './wire'
import type { Send } from './wire'

interface Sent { readonly path: string; readonly init: RequestInit }

/** A `send` that answers from a list, in order, and keeps what was sent. */
function scripted(answers: ReadonlyArray<Response | 'no answer'>): { readonly send: Send; readonly sent: Sent[] } {
  const sent: Sent[] = []
  const left = [...answers]
  const send: Send = (path, init) => {
    sent.push({ path, init })
    const next = left.shift()
    if (next === undefined) throw new Error(`no answer was scripted for ${path}`)
    return next === 'no answer' ? Promise.reject(new TypeError('fetch failed')) : Promise.resolve(next)
  }
  return { send, sent }
}

const json = (status: number, body: unknown): Response =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } })

/** The headers of the one request that was sent. */
function headersOfTheOne(sent: readonly Sent[]): Headers {
  const [first] = sent
  if (first === undefined || sent.length !== 1) throw new Error(`${sent.length} requests were sent`)
  return new Headers(first.init.headers)
}

describe('readSession', () => {
  it('reads the user and the CSRF token', () => {
    expect(readSession({ user_id: 'usr_1', expires_at_ms: 1, csrf_token: 'token' })).toEqual({ userId: 'usr_1', csrfToken: 'token' })
  })
  it.each([
    ['no object', 'usr_1'],
    ['an array', []],
    ['no user', { csrf_token: 'token' }],
    ['an empty user', { user_id: '', csrf_token: 'token' }],
    ['no token', { user_id: 'usr_1' }],
    ['a token that is no string', { user_id: 'usr_1', csrf_token: 7 }],
  ])('refuses %s', (_name, value) => {
    expect(readSession(value)).toBeNull()
  })
})

describe('readWho', () => {
  const answer = (role: unknown, kind: unknown = 'human'): unknown => ({ principal: { kind, id: 'usr_1' }, role, binding: { kind: 'session', id: 's' } })
  it.each([
    ['admin', 'admin'],
    ['worker', 'member'],
    ['player', 'unrecognised'],
    ['a role named later', 'unrecognised'],
  ] as const)('reads the role %s as %s', (role, expected) => {
    expect(readWho(answer(role))).toEqual({ id: 'usr_1', role: expected })
  })
  it.each([
    ['a service', answer('worker', 'service')],
    ['no principal', { role: 'admin' }],
    ['no id', { principal: { kind: 'human' }, role: 'admin' }],
    ['no role', { principal: { kind: 'human', id: 'usr_1' } }],
    ['a role that is no string', answer(1)],
  ])('refuses %s', (_name, value) => {
    expect(readWho(value)).toBeNull()
  })
})

describe('a read', () => {
  it('asks for the session with the cookie of this origin and no bearer token', async () => {
    const { send, sent } = scripted([json(200, { user_id: 'usr_1', expires_at_ms: 1, csrf_token: 'token' })])
    expect(await session(send)).toEqual({ ok: true, value: { userId: 'usr_1', csrfToken: 'token' } })
    expect(sent.map((one) => [one.path, one.init.method, one.init.credentials])).toEqual([[paths.session, 'GET', 'same-origin']])
    expect(headersOfTheOne(sent).has('authorization')).toBe(false)
  })
  it('reads who the session belongs to', async () => {
    const { send, sent } = scripted([json(200, { principal: { kind: 'human', id: 'usr_1' }, role: 'admin', binding: { kind: 'session', id: 's' } })])
    expect(await who(send)).toEqual({ ok: true, value: { id: 'usr_1', role: 'admin' } })
    expect(sent.map((one) => one.path)).toEqual([paths.who])
  })
  it.each([
    ['no session', json(401, { error: 'no session cookie came with the request' }), { kind: 'signed_out' }],
    ['a refusal with a sentence', json(503, { error: 'the files are being read again' }), { kind: 'refused', status: 503, reason: 'the files are being read again' }],
    ['a refusal with no JSON', new Response('<html>', { status: 502 }), { kind: 'refused', status: 502, reason: null }],
    ['an answer of another shape', json(200, { user: 'usr_1' }), { kind: 'unreadable' }],
    ['an answer that is no JSON', new Response('ok', { status: 200 }), { kind: 'unreadable' }],
    ['no answer', 'no answer', { kind: 'unreachable' }],
  ] as const)('gives the problem of %s', async (_name, answer, problem) => {
    expect(await session(scripted([answer]).send)).toEqual({ ok: false, problem })
  })
})

describe('signing out', () => {
  it('posts with the CSRF token of the session and no bearer token', async () => {
    const { send, sent } = scripted([new Response(null, { status: 204 })])
    expect(await signOut(send, 'token')).toEqual({ ok: true, value: null })
    expect(sent.map((one) => [one.path, one.init.method, one.init.credentials])).toEqual([[paths.signOut, 'POST', 'same-origin']])
    const headers = headersOfTheOne(sent)
    expect([headers.get(csrfHeader), headers.has('authorization')]).toEqual(['token', false])
  })
  it.each([
    ['no session', json(401, { error: 'no session cookie came with the request' }), { kind: 'signed_out' }],
    ['a refusal', json(403, { error: 'the CSRF token of the request differs' }), { kind: 'refused', status: 403, reason: 'the CSRF token of the request differs' }],
    ['an answer that is not the end of a session', json(200, {}), { kind: 'unreadable' }],
    ['no answer', 'no answer', { kind: 'unreachable' }],
  ] as const)('gives the problem of %s', async (_name, answer, problem) => {
    expect(await signOut(scripted([answer]).send, 'token')).toEqual({ ok: false, problem })
  })
})

describe('readIntegrations', () => {
  const one = (fields: Record<string, unknown>): unknown => ({
    integrations: [{ integration_id: 'claude_code', display_name: 'Claude Code', models: ['claude-sonnet-5'], calls: 'allowed', ...fields }],
  })
  it('reads a subscription whose models a Keeper may call', () => {
    expect(readIntegrations(one({}))).toEqual([
      { id: 'claude_code', displayName: 'Claude Code', models: ['claude-sonnet-5'], calls: { kind: 'allowed' } },
    ])
  })
  it.each([
    ['native_unpublished', 'native_unpublished'],
    ['native_tools_reach_other_homes', 'native_tools_reach_other_homes'],
    ['native_tools_reach_person_homes', 'native_tools_reach_person_homes'],
    ['person_homes_unread', 'person_homes_unread'],
    ['a code named later', 'unrecognised'],
  ] as const)('reads the refusal %s as %s', (code, refusal) => {
    expect(readIntegrations(one({ calls: 'refused', refusal: code }))?.[0]?.calls).toEqual({ kind: 'refused', refusal })
  })
  it('reads an empty name and no models as they came', () => {
    expect(readIntegrations(one({ display_name: '', models: [] }))?.[0]).toMatchObject({ displayName: '', models: [] })
  })
  it.each([
    ['no object', []],
    ['no list', { integrations: {} }],
    ['no id', one({ integration_id: '' })],
    ['a name that is no string', one({ display_name: null })],
    ['a model that is no string', one({ models: ['claude-sonnet-5', 7] })],
    ['an empty model', one({ models: [''] })],
    ['no calls', one({ calls: undefined })],
    ['calls of another word', one({ calls: 'maybe' })],
    ['a refusal with no code', one({ calls: 'refused' })],
  ])('refuses %s', (_name, value) => {
    expect(readIntegrations(value)).toBeNull()
  })
})

describe('readOwned', () => {
  const answer = (account: Record<string, unknown>, runtime: Record<string, unknown>): unknown => ({
    provider_accounts: [{ provider_account_id: 'acct_1', integration_id: 'claude_code', ...account }],
    runtimes: [{ runtime_id: 'acct_1.claude-sonnet-5', provider_account_id: 'acct_1', model: 'claude-sonnet-5', ...runtime }],
  })
  it('reads the facts the server read', () => {
    expect(readOwned(answer({}, {}))).toEqual({
      accounts: [{ id: 'acct_1', integration: { read: true, value: 'claude_code' } }],
      runtimes: [{ id: 'acct_1.claude-sonnet-5', accountId: 'acct_1', model: { read: true, value: 'claude-sonnet-5' } }],
    })
  })
  it('reads nothing owned', () => {
    expect(readOwned({ provider_accounts: [], runtimes: [] })).toEqual({ accounts: [], runtimes: [] })
  })
  it.each([
    ['login_receipt_missing', 'login_receipt_missing'],
    ['login_receipt_unreadable', 'login_receipt_unreadable'],
    ['a code named later', 'unrecognised'],
  ] as const)('reads why the subscription of an account is not known: %s as %s', (code, unread) => {
    expect(readOwned(answer({ integration_id: null, unread: code }, {}))?.accounts[0]?.integration).toEqual({ read: false, unread })
  })
  it.each([
    ['account_integration_unread', 'account_integration_unread'],
    ['configuration_unavailable', 'configuration_unavailable'],
    ['template_not_declared', 'template_not_declared'],
    ['runtime_not_bound', 'runtime_not_bound'],
    ['a code named later', 'unrecognised'],
  ] as const)('reads why the model of a Runtime is not known: %s as %s', (code, unread) => {
    expect(readOwned(answer({}, { model: null, unread: code }))?.runtimes[0]?.model).toEqual({ read: false, unread })
  })
  it.each([
    ['no object', 'acct_1'],
    ['accounts as ids, the shape before', { provider_accounts: ['acct_1'], runtimes: [] }],
    ['no runtimes', { provider_accounts: [] }],
    ['an account with no id', answer({ provider_account_id: '' }, {})],
    ['an empty integration', answer({ integration_id: '' }, {})],
    ['an integration and why it was not read', answer({ unread: 'login_receipt_missing' }, {})],
    ['an unread integration with no reason', answer({ integration_id: null }, {})],
    ['a missing integration', answer({ integration_id: undefined }, {})],
    ['a reason with no integration', answer({ integration_id: undefined, unread: 'login_receipt_missing' }, {})],
    ['a reason with no model', answer({}, { model: undefined, unread: 'runtime_not_bound' })],
    ['a Runtime with no account', answer({}, { provider_account_id: undefined })],
    ['a Runtime on an account not listed', answer({}, { provider_account_id: 'acct_2' })],
    ['a model that is no string', answer({}, { model: 5 })],
    ['an unread model with a reason that is no string', answer({}, { model: null, unread: 1 })],
  ])('refuses %s', (_name, value) => {
    expect(readOwned(value)).toBeNull()
  })
})

describe('reading the subscriptions', () => {
  it.each([
    ['what the server offers', integrations, paths.integrations, { integrations: [] }, []],
    ['what the person owns', owned, paths.owned, { provider_accounts: [], runtimes: [] }, { accounts: [], runtimes: [] }],
  ] as const)('asks for %s with the cookie of this origin and no bearer token', async (_name, read, path, body, value) => {
    const { send, sent } = scripted([json(200, body)])
    expect(await read(send)).toEqual({ ok: true, value })
    expect(sent.map((one) => [one.path, one.init.method, one.init.credentials])).toEqual([[path, 'GET', 'same-origin']])
    expect(headersOfTheOne(sent).has('authorization')).toBe(false)
  })
})
