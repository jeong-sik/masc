// @vitest-environment happy-dom
//
// The invitations an Admin makes: what the server's answers read as, what an
// invitation made and revoked sends, and how the list and the requests move.
// What a step says and where it puts things is not checked here: that is
// read in a browser.
import { afterEach, describe, expect, it, vi } from 'vitest'
import { signal } from '@preact/signals'
import type { View } from './console'
import { createInvites, followInvites } from './invites'
import type { InvitesModel } from './invites'
import { addressOf, invitesPath, issue, list, readInvites, readIssued, revoke } from './invites-wire'
import type { Invite } from './invites-wire'
import { csrfHeader } from './wire'
import type { Send, Session } from './wire'

interface Sent { readonly path: string; readonly init: RequestInit }
type Scripted = Response | 'no answer' | Promise<Response>

/** A `send` that gives the scripted answers in order, and keeps what was sent. */
function answering(answers: readonly Scripted[]): { readonly send: Send; readonly sent: Sent[] } {
  const sent: Sent[] = []
  const left = [...answers]
  const send: Send = (path, init) => {
    sent.push({ path, init })
    const next = left.shift()
    if (next === undefined) return Promise.reject(new Error(`no answer was scripted for ${path}`))
    return next === 'no answer' ? Promise.reject(new TypeError('fetch failed')) : Promise.resolve(next)
  }
  return { send, sent }
}

/** An answer that comes when the test says so. */
function later(): { readonly answer: Promise<Response>; readonly give: (response: Response) => void } {
  let give: (response: Response) => void = () => { throw new Error('the answer was given before it was asked for') }
  const answer = new Promise<Response>((resolve) => { give = resolve })
  return { answer, give: (response) => { give(response) } }
}

const json = (status: number, body: unknown): Response =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } })
const noSession = (): Response => json(401, { error: 'no session cookie came with the request' })

const expiresAt = 1_763_086_400_000
const operator = { kind: 'local_operator' }
const inviteJson = (id: string, extra: Record<string, unknown> = {}) =>
  ({ invite_id: id, role: 'member', issuer: { kind: 'admin', user_id: 'usr_first' }, expires_at_ms: expiresAt, status: 'open', ...extra })
const listed = (...invites: readonly unknown[]): Response => json(200, { invites })
const issuedJson = (id: string, role = 'member') => ({ invite_id: id, role, expires_at_ms: expiresAt, link: `/accounts/invite#secret-of-${id}` })
const issuedAnswer = (id: string, role = 'member'): Response => json(200, issuedJson(id, role))
const revoked = (): Response => new Response(null, { status: 204 })

const first: Session = { userId: 'usr_first', csrfToken: 'token-1' }
const second: Session = { userId: 'usr_second', csrfToken: 'token-2' }

const methods = (sent: readonly Sent[]): string[] => sent.map((one) => `${String(one.init.method)} ${one.path}`)
const invitesOf = (model: InvitesModel): readonly Invite[] | null => {
  const now = model.view.value
  return now.kind === 'read' ? now.invites : null
}

afterEach(() => {
  vi.useRealTimers()
  vi.restoreAllMocks()
})

describe('reading the answers about invitations', () => {
  it('reads every invitation, who made it and who joined through it, with a status it does not know kept apart', () => {
    expect(readInvites({
      invites: [
        inviteJson('inv_1', { issuer: operator, role: 'admin' }),
        inviteJson('inv_2', { status: 'consumed', user_id: 'usr_7' }),
        inviteJson('inv_3', { status: 'revocation_pending' }),
        inviteJson('inv_4', { status: 'paused' }),
        inviteJson('inv_5', { status: 'paused', user_id: 'usr_8' }),
      ],
    })).toEqual([
      { id: 'inv_1', role: 'admin', issuer: { kind: 'local_operator' }, expiresAtMs: expiresAt, status: 'open', joined: null },
      { id: 'inv_2', role: 'member', issuer: { kind: 'admin', userId: 'usr_first' }, expiresAtMs: expiresAt, status: 'consumed', joined: 'usr_7' },
      { id: 'inv_3', role: 'member', issuer: { kind: 'admin', userId: 'usr_first' }, expiresAtMs: expiresAt, status: 'revocation_pending', joined: null },
      { id: 'inv_4', role: 'member', issuer: { kind: 'admin', userId: 'usr_first' }, expiresAtMs: expiresAt, status: 'unrecognised', joined: null },
      { id: 'inv_5', role: 'member', issuer: { kind: 'admin', userId: 'usr_first' }, expiresAtMs: expiresAt, status: 'unrecognised', joined: 'usr_8' },
    ])
  })

  it('does not read a list with an invitation that is not what the route promises', () => {
    const one = (extra: Record<string, unknown>) => readInvites({ invites: [inviteJson('inv_1', extra)] })
    expect([
      one({ invite_id: '' }),
      one({ role: 'owner' }),
      one({ issuer: { kind: 'admin' } }),
      one({ issuer: { kind: 'local_operator', user_id: 'usr_1' } }),
      one({ issuer: { user_id: 'usr_1', kind: 'admin' } }),
      one({ expires_at_ms: -1 }),
      one({ expires_at_ms: 1.5 }),
      one({ status: 7 }),
      one({ status: 'consumed' }),
      one({ status: 'open', user_id: 'usr_7' }),
      one({ status: 'consumed', user_id: '' }),
      readInvites({ invites: [inviteJson('inv_1'), inviteJson('inv_1')] }),
      readInvites({ invites: {} }),
      readInvites([]),
    ]).toEqual(Array.from({ length: 14 }, () => null))
  })

  it('reads an invitation made only with a link to the invitation page that carries a token', () => {
    const issued = readIssued(issuedJson('inv_9', 'admin'))
    expect([
      issued,
      issued === null ? null : addressOf(issued, 'https://masc.example'),
      readIssued({ ...issuedJson('inv_9'), link: '/accounts/invite#' }),
      readIssued({ ...issuedJson('inv_9'), link: 'https://elsewhere.example/accounts/invite#token' }),
      readIssued({ ...issuedJson('inv_9'), link: '/accounts/console#token' }),
      readIssued({ ...issuedJson('inv_9'), role: 'owner' }),
      readIssued({ ...issuedJson('inv_9'), invite_id: undefined }),
    ]).toEqual([
      { id: 'inv_9', role: 'admin', expiresAtMs: expiresAt, link: '/accounts/invite#secret-of-inv_9' },
      'https://masc.example/accounts/invite#secret-of-inv_9',
      null, null, null, null, null,
    ])
  })
})

describe('sending about invitations', () => {
  it('lists, makes and revokes with the cookie of the session, and the CSRF token on each write', async () => {
    const { send, sent } = answering([listed(), issuedAnswer('inv_1'), revoked()])
    await list(send)
    await issue(send, 'token-1', 'admin')
    await revoke(send, 'token-1', 'inv_1/x')
    expect(sent.map(({ path, init }) => {
      const headers = new Headers(init.headers)
      return [path, init.method, init.credentials, headers.get(csrfHeader), headers.has('authorization'), init.body ?? null]
    })).toEqual([
      [invitesPath, 'GET', 'same-origin', null, false, null],
      [invitesPath, 'POST', 'same-origin', 'token-1', false, JSON.stringify({ role: 'admin' })],
      [`${invitesPath}/inv_1%2Fx`, 'DELETE', 'same-origin', 'token-1', false, null],
    ])
  })

  it('takes a revoke only from a 204', async () => {
    const { send } = answering([json(200, {}), json(409, { error: 'revoked before' })])
    expect([await revoke(send, 't', 'inv_1'), await revoke(send, 't', 'inv_1')]).toEqual([
      { ok: false, problem: { kind: 'unreadable' } },
      { ok: false, problem: { kind: 'refused', status: 409, reason: 'revoked before' } },
    ])
  })
})

describe('the invitations an Admin sees', () => {
  const loaded = async (answers: readonly Scripted[]) => {
    const { send, sent } = answering([listed(inviteJson('inv_1')), ...answers])
    const leave = vi.fn()
    const model = createInvites({ send, leave })
    await model.load(first)
    return { model, sent, leave }
  }
  const settled = async (sent: readonly Sent[], gets: number) => {
    await vi.waitFor(() => { expect(sent.filter((one) => one.init.method === 'GET').length).toBe(gets) })
  }

  it('reads the invitations, says when it waits, and reads again after a failure', async () => {
    vi.useFakeTimers()
    const wait = later()
    const { send } = answering([wait.answer, json(503, { error: 'not now' }), listed(inviteJson('inv_1'))])
    const model = createInvites({ send, leave: vi.fn() })
    const run = model.load(first)
    await vi.advanceTimersByTimeAsync(1000)
    const slow = model.view.value
    wait.give(json(503, { error: 'not now' }))
    await run
    await model.retry()
    const failed = model.view.value
    await model.retry()
    expect([slow, failed.kind === 'failed' ? failed.failure.attempts : null, invitesOf(model)?.length]).toEqual([{ kind: 'reading', forUser: 'usr_first', slow: true }, 2, 1])
  })

  it('makes an invitation for the role asked, shows its link until the Admin took it, and reads the list again', async () => {
    const { model, sent } = await loaded([issuedAnswer('inv_2', 'admin'), listed(inviteJson('inv_1'), inviteJson('inv_2', { role: 'admin' }))])
    await model.make('admin')
    await vi.waitFor(() => { expect(invitesOf(model)?.length).toBe(2) })
    const shown = model.making.value
    await model.make('member')
    model.forget()
    expect([shown, methods(sent).filter((one) => one.startsWith('POST')).length, model.making.value]).toEqual([
      { kind: 'issued', issued: { id: 'inv_2', role: 'admin', expiresAtMs: expiresAt, link: '/accounts/invite#secret-of-inv_2' } }, 1, { kind: 'idle' },
    ])
    expect(JSON.parse(String(sent[1]?.init.body))).toEqual({ role: 'admin' })
  })

  it('keeps the link made out of the storage of the browser', async () => {
    const { model, sent } = await loaded([issuedAnswer('inv_2'), listed()])
    await model.make('member')
    await settled(sent, 2)
    expect([localStorage.length, sessionStorage.length]).toEqual([0, 0])
  })

  it('counts the refusals of a make, and does not know what came of one the server failed', async () => {
    const { model, sent } = await loaded([json(403, { error: 'only an Admin' }), listed(), json(403, { error: 'only an Admin' }), listed(), json(503, { error: 'uncertain' }), listed(), 'no answer', listed(), json(200, { invite_id: 'inv_3' }), listed()])
    const kinds = []
    for (let n = 0; n < 5; n += 1) {
      await model.make('member')
      await settled(sent, n + 2)
      const now = model.making.value
      kinds.push(now.kind === 'refused' || now.kind === 'unknown' ? [now.kind, now.role, now.attempts] : null)
    }
    expect(kinds).toEqual([['refused', 'member', 1], ['refused', 'member', 2], ['unknown', 'member', 3], ['unknown', 'member', 4], ['unknown', 'member', 5]])
  })

  it('makes one invitation at a time, and none before the list is read', async () => {
    const wait = later()
    const { model, sent } = await loaded([wait.answer, listed()])
    const run = model.make('member')
    await model.make('member')
    wait.give(issuedAnswer('inv_2'))
    await run
    await model.make('member')
    const reading = createInvites({ send: answering([]).send, leave: vi.fn() })
    await reading.make('member')
    const unread = answering([json(503, { error: 'not now' })])
    const failing = createInvites({ send: unread.send, leave: vi.fn() })
    await failing.load(first)
    await failing.make('member')
    expect([methods(sent).filter((one) => one.startsWith('POST')).length, reading.making.value, methods(unread.sent)]).toEqual([1, { kind: 'idle' }, [`GET ${invitesPath}`]])
  })

  it('drops a make that answers after another person is shown', async () => {
    const wait = later()
    const { model, sent } = await loaded([wait.answer, listed()])
    const making = model.make('member')
    await model.load(second)
    wait.give(issuedAnswer('inv_2'))
    await making
    expect([model.making.value, methods(sent).filter((one) => one.startsWith('GET')).length]).toEqual([{ kind: 'idle' }, 2])
  })

  it('keeps the newest session of the person shown, and does not read the list again for it', async () => {
    const { model, sent } = await loaded([revoked(), listed()])
    await model.load({ userId: 'usr_first', csrfToken: 'token-1b' })
    await model.revoke('inv_1')
    await settled(sent, 2)
    expect([methods(sent), new Headers(sent[1]?.init.headers).get(csrfHeader)]).toEqual([
      [`GET ${invitesPath}`, `DELETE ${invitesPath}/inv_1`, `GET ${invitesPath}`], 'token-1b',
    ])
  })

  it('takes the latest reading of the list, not one that answers after it', async () => {
    const wait = later()
    const { model } = await loaded([issuedAnswer('inv_2'), wait.answer, revoked(), listed(inviteJson('inv_1', { status: 'revoked' }), inviteJson('inv_2'))])
    await model.make('member')
    await model.revoke('inv_1')
    await vi.waitFor(() => { expect(invitesOf(model)?.length).toBe(2) })
    wait.give(listed(inviteJson('inv_1')))
    await new Promise((resolve) => { setTimeout(resolve, 20) })
    expect(invitesOf(model)?.map((one) => one.status)).toEqual(['revoked', 'open'])
  })

  it('reads the list again when a revoke answers while the list is read', async () => {
    const slowRevoke = later()
    const slowRead = later()
    const { model, sent } = await loaded([slowRevoke.answer, json(404, { error: 'no invitation' }), json(503, { error: 'not now' }), slowRead.answer, listed(inviteJson('inv_1', { status: 'revoked' }))])
    const revoking = model.revoke('inv_1')
    await model.revoke('inv_2')
    await vi.waitFor(() => { expect(model.view.value.kind).toBe('failed') })
    const retried = model.retry()
    slowRevoke.give(revoked())
    await revoking
    slowRead.give(listed(inviteJson('inv_1')))
    await retried
    expect([invitesOf(model)?.map((one) => one.status), sent.filter((one) => one.init.method === 'GET').length]).toEqual([['revoked'], 4])
  })

  it('revokes an invitation and reads the list again, and takes one the server closed before as done', async () => {
    const { model, sent } = await loaded([revoked(), listed(), json(409, { error: 'consumed' }), listed()])
    await model.revoke('inv_1')
    await settled(sent, 2)
    const done = model.revoking.value.get('inv_1')
    await model.revoke('inv_2')
    await settled(sent, 3)
    expect([done, model.revoking.value.get('inv_2')]).toEqual([{ kind: 'done', before: false }, { kind: 'done', before: true }])
  })

  it('counts the refusals of a revoke, and does not know what came of one the server failed', async () => {
    const { model, sent } = await loaded([json(404, { error: 'no invitation' }), listed(), json(404, { error: 'no invitation' }), listed(), json(500, { error: 'failed' }), listed(), 'no answer', listed()])
    const kinds = []
    for (let n = 0; n < 4; n += 1) {
      await model.revoke('inv_1')
      await settled(sent, n + 2)
      const now = model.revoking.value.get('inv_1')
      kinds.push(now?.kind === 'refused' || now?.kind === 'unknown' ? [now.kind, now.attempts] : null)
    }
    expect(kinds).toEqual([['refused', 1], ['refused', 2], ['unknown', 3], ['unknown', 4]])
  })

  it('revokes an invitation once at a time', async () => {
    const wait = later()
    const { model, sent } = await loaded([wait.answer, listed()])
    const run = model.revoke('inv_1')
    await model.revoke('inv_1')
    wait.give(revoked())
    await run
    expect(methods(sent).filter((one) => one.startsWith('DELETE')).length).toBe(1)
  })

  it('leaves once when two requests find that the session ended, and marks the revoke under way', async () => {
    const wait = later()
    const { model, leave } = await loaded([wait.answer, noSession()])
    const revoking = model.revoke('inv_1')
    await model.make('member')
    const marked = model.revoking.value.get('inv_1')
    wait.give(noSession())
    await revoking
    expect([model.making.value, marked, model.revoking.value.get('inv_1'), leave.mock.calls.length]).toEqual([{ kind: 'leaving' }, { kind: 'leaving' }, { kind: 'leaving' }, 1])
  })

  it('leaves once when a request finds that the session ended, and takes the link made off the page', async () => {
    const { model, leave } = await loaded([issuedAnswer('inv_2'), noSession()])
    await model.make('member')
    await vi.waitFor(() => { expect(leave).toHaveBeenCalled() })
    await model.make('member')
    expect([model.making.value, model.view.value.kind, leave.mock.calls.length]).toEqual([{ kind: 'leaving' }, 'leaving', 1])
  })

  it('forgets the link made and drops a late answer when another person is shown', async () => {
    const wait = later()
    const { model, sent } = await loaded([issuedAnswer('inv_2'), listed(), wait.answer, listed()])
    await model.make('member')
    await settled(sent, 2)
    const revoking = model.revoke('inv_1')
    await model.load(second)
    wait.give(revoked())
    await revoking
    expect([model.making.value, model.revoking.value.size, model.view.value.kind === 'read' ? model.view.value.forUser : null]).toEqual([{ kind: 'idle' }, 0, 'usr_second'])
    expect(new Headers(sent[3]?.init.headers).get(csrfHeader)).toBe('token-1')
  })
})

describe('following the console', () => {
  const signedIn = (role: 'admin' | 'member', session: Session = first): View => ({
    kind: 'signed_in', session, who: { id: session.userId, role }, signOut: { kind: 'idle' },
  })

  it('reads the invitations for an Admin and sends nothing for a Member', async () => {
    const { send, sent } = answering([listed(), listed()])
    const model = createInvites({ send, leave: vi.fn() })
    const frame = signal<View>({ kind: 'reading', slow: false })
    const stop = followInvites(frame, model)
    frame.value = signedIn('member')
    const asMember = methods(sent)
    frame.value = signedIn('admin', second)
    await vi.waitFor(() => { expect(model.view.value.kind).toBe('read') })
    stop()
    frame.value = signedIn('admin')
    expect([asMember, methods(sent), model.view.value.kind === 'read' ? model.view.value.forUser : null]).toEqual([[], [`GET ${invitesPath}`], 'usr_second'])
  })
})
