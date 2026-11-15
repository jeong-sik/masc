// @vitest-environment happy-dom
//
// The allowlist an Admin keeps: what the server's answers read as, what a
// registration and a removal send, what an account typed reads as, and how
// the list and the requests move. What a step says and where it puts things
// is not checked here: that is read in a browser.
import { afterEach, describe, expect, it, vi } from 'vitest'
import { signal } from '@preact/signals'
import type { View } from './console'
import { createAllowlist, followAllowlist, readTyped } from './allowlist'
import type { AllowlistModel } from './allowlist'
import { allowlistPath, list, readEntries, readRegistered, register, remove } from './allowlist-wire'
import type { Entry } from './allowlist-wire'
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

const github = { provider: 'github', user_id: 12345 }
const google = { provider: 'google', sub: '109876543210987654321' }
const entryJson = (id: string, extra: Record<string, unknown> = {}) =>
  ({ registration_id: id, identity: github, registrar: 'usr_first', status: 'open', ...extra })
const listed = (...registrations: readonly unknown[]): Response => json(200, { registrations })
const registered = (id: string, previouslyDeleted = false): Response => json(200, { registration_id: id, previously_deleted: previouslyDeleted })
const removed = (): Response => new Response(null, { status: 204 })
const someone = { provider: 'github', userId: 777 } as const

const first: Session = { userId: 'usr_first', csrfToken: 'token-1' }
const second: Session = { userId: 'usr_second', csrfToken: 'token-2' }

const methods = (sent: readonly Sent[]): string[] => sent.map((one) => `${String(one.init.method)} ${one.path}`)
const entriesOf = (model: AllowlistModel): readonly Entry[] | null => {
  const now = model.view.value
  return now.kind === 'read' ? now.entries : null
}

afterEach(() => {
  vi.useRealTimers()
  vi.restoreAllMocks()
})

describe('reading the answers about the allowlist', () => {
  it('reads every entry, who registered it and who joined through it, with a status it does not know kept apart', () => {
    expect(readEntries({
      registrations: [
        entryJson('reg_1'),
        entryJson('reg_2', { identity: google, status: 'consumed', user_id: 'usr_7' }),
        entryJson('reg_3', { status: 'removal_pending' }),
        entryJson('reg_4', { status: 'removed', registrar: 'usr_other' }),
        entryJson('reg_5', { status: 'paused' }),
        entryJson('reg_6', { status: 'paused', user_id: 'usr_8', identity: { provider: 'gitlab', id: 1 } }),
      ],
    })).toEqual([
      { id: 'reg_1', identity: { provider: 'github', userId: 12345 }, registrar: 'usr_first', status: { kind: 'open' } },
      { id: 'reg_2', identity: { provider: 'google', sub: '109876543210987654321' }, registrar: 'usr_first', status: { kind: 'consumed', joined: 'usr_7' } },
      { id: 'reg_3', identity: { provider: 'github', userId: 12345 }, registrar: 'usr_first', status: { kind: 'removal_pending' } },
      { id: 'reg_4', identity: { provider: 'github', userId: 12345 }, registrar: 'usr_other', status: { kind: 'removed' } },
      { id: 'reg_5', identity: { provider: 'github', userId: 12345 }, registrar: 'usr_first', status: { kind: 'unrecognised' } },
      { id: 'reg_6', identity: { provider: 'unrecognised' }, registrar: 'usr_first', status: { kind: 'unrecognised' } },
    ])
  })

  it('does not read a list with an entry that is not what the route promises', () => {
    const one = (extra: Record<string, unknown>) => readEntries({ registrations: [entryJson('reg_1', extra)] })
    expect([
      one({ registration_id: '' }),
      one({ registrar: '' }),
      one({ registrar: 7 }),
      one({ identity: { provider: 'github', user_id: 0 } }),
      one({ identity: null }),
      one({ status: 7 }),
      one({ status: 'consumed' }),
      one({ status: 'open', user_id: 'usr_7' }),
      one({ status: 'removed', user_id: 'usr_7' }),
      one({ status: 'consumed', user_id: '' }),
      one({ status: 'consumed', user_id: null }),
      readEntries({ registrations: [entryJson('reg_1'), entryJson('reg_1')] }),
      readEntries({ registrations: ['reg_1'] }),
      readEntries({ registrations: {} }),
      readEntries([]),
    ]).toEqual(Array.from({ length: 15 }, () => null))
  })

  it('reads a registration with its id and whether a person with the account was deleted before', () => {
    expect([
      readRegistered({ registration_id: 'reg_9', previously_deleted: true }),
      readRegistered({ registration_id: 'reg_9', previously_deleted: false }),
      readRegistered({ registration_id: '', previously_deleted: false }),
      readRegistered({ registration_id: 'reg_9' }),
      readRegistered({ registration_id: 'reg_9', previously_deleted: 'no' }),
    ]).toEqual([{ id: 'reg_9', previouslyDeleted: true }, { id: 'reg_9', previouslyDeleted: false }, null, null, null])
  })
})

describe('reading an account the Admin typed', () => {
  it('reads a GitHub user id and a Google sub as the server takes them, with the spaces at either end left out', () => {
    expect([
      readTyped('github', ' 12345 '),
      readTyped('github', String(Number.MAX_SAFE_INTEGER)),
      readTyped('github', '007'),
      readTyped('google', ' 109876543210987654321\n'),
      readTyped('google', 'a'.repeat(255)),
    ]).toEqual([
      { ok: true, identity: { provider: 'github', userId: 12345 } },
      { ok: true, identity: { provider: 'github', userId: Number.MAX_SAFE_INTEGER } },
      { ok: true, identity: { provider: 'github', userId: 7 } },
      { ok: true, identity: { provider: 'google', sub: '109876543210987654321' } },
      { ok: true, identity: { provider: 'google', sub: 'a'.repeat(255) } },
    ])
  })

  it('says why what was typed is not an account the server takes', () => {
    expect([
      readTyped('github', ''),
      readTyped('google', '   '),
      readTyped('github', 'octocat'),
      readTyped('github', '0'),
      readTyped('github', '-5'),
      readTyped('github', '1.5'),
      readTyped('github', '1e3'),
      readTyped('github', String(2 ** 53)),
      readTyped('google', 'a'.repeat(256)),
      readTyped('google', 'one two'),
      readTyped('google', '하나'),
    ].map((one) => (one.ok ? 'read' : one.why))).toEqual([
      'empty', 'empty',
      'not_a_number', 'not_a_number', 'not_a_number', 'not_a_number', 'not_a_number', 'not_a_number',
      'not_a_sub', 'not_a_sub', 'not_a_sub',
    ])
  })
})

describe('sending about the allowlist', () => {
  it('lists, registers and removes with the cookie of the session, and the CSRF token on each write', async () => {
    const { send, sent } = answering([listed(), registered('reg_1'), registered('reg_2'), removed()])
    await list(send)
    await register(send, 'token-1', { provider: 'github', userId: 12345 })
    await register(send, 'token-1', { provider: 'google', sub: 'abc' })
    await remove(send, 'token-1', 'reg_1/x')
    expect(sent.map(({ path, init }) => {
      const headers = new Headers(init.headers)
      return [path, init.method, init.credentials, headers.get(csrfHeader), headers.has('authorization'), init.body ?? null]
    })).toEqual([
      [allowlistPath, 'GET', 'same-origin', null, false, null],
      [allowlistPath, 'POST', 'same-origin', 'token-1', false, JSON.stringify({ provider: 'github', user_id: 12345 })],
      [allowlistPath, 'POST', 'same-origin', 'token-1', false, JSON.stringify({ provider: 'google', sub: 'abc' })],
      [`${allowlistPath}/reg_1%2Fx`, 'DELETE', 'same-origin', 'token-1', false, null],
    ])
  })

  it('takes a removal only from a 204, and a registration only from an answer it reads', async () => {
    const { send } = answering([json(200, {}), json(409, { error: 'removed before' }), json(200, { registration_id: 'reg_1' })])
    expect([await remove(send, 't', 'reg_1'), await remove(send, 't', 'reg_1'), await register(send, 't', someone)]).toEqual([
      { ok: false, problem: { kind: 'unreadable' } },
      { ok: false, problem: { kind: 'refused', status: 409, reason: 'removed before' } },
      { ok: false, problem: { kind: 'unreadable' } },
    ])
  })
})

describe('the allowlist an Admin sees', () => {
  const loaded = async (answers: readonly Scripted[]) => {
    const { send, sent } = answering([listed(entryJson('reg_1')), ...answers])
    const leave = vi.fn()
    const model = createAllowlist({ send, leave })
    await model.load(first)
    return { model, sent, leave }
  }
  const settled = async (sent: readonly Sent[], gets: number) => {
    await vi.waitFor(() => { expect(sent.filter((one) => one.init.method === 'GET').length).toBe(gets) })
  }

  it('reads the entries, says when it waits, and reads again after a failure', async () => {
    vi.useFakeTimers()
    const wait = later()
    const { send } = answering([wait.answer, json(503, { error: 'not now' }), listed(entryJson('reg_1'))])
    const model = createAllowlist({ send, leave: vi.fn() })
    const run = model.load(first)
    await vi.advanceTimersByTimeAsync(1000)
    const slow = model.view.value
    wait.give(json(503, { error: 'not now' }))
    await run
    await model.retry()
    const failed = model.view.value
    await model.retry()
    expect([slow, failed.kind === 'failed' ? failed.failure.attempts : null, entriesOf(model)?.length]).toEqual([{ kind: 'reading', forUser: 'usr_first', slow: true }, 2, 1])
  })

  it('registers the account asked for, says whether a person with it was deleted before, and reads the list again', async () => {
    const { model, sent } = await loaded([registered('reg_2', true), listed(entryJson('reg_1'), entryJson('reg_2', { identity: { provider: 'github', user_id: 777 } }))])
    await model.add(someone)
    await vi.waitFor(() => { expect(entriesOf(model)?.length).toBe(2) })
    expect([model.adding.value, JSON.parse(String(sent[1]?.init.body))]).toEqual([
      { kind: 'done', identity: someone, registered: { id: 'reg_2', previouslyDeleted: true } }, { provider: 'github', user_id: 777 },
    ])
  })

  it('counts the refusals of a registration, and does not know what came of one the server failed', async () => {
    const { model, sent } = await loaded([json(409, { error: 'bound' }), listed(), json(403, { error: 'only an Admin' }), listed(), json(503, { error: 'uncertain' }), listed(), 'no answer', listed(), json(200, { registration_id: 'reg_3' }), listed()])
    const kinds = []
    for (let n = 0; n < 5; n += 1) {
      await model.add(someone)
      await settled(sent, n + 2)
      const now = model.adding.value
      kinds.push(now.kind === 'refused' || now.kind === 'unknown' ? [now.kind, now.identity, now.attempts] : null)
    }
    expect(kinds).toEqual([['refused', someone, 1], ['refused', someone, 2], ['unknown', someone, 3], ['unknown', someone, 4], ['unknown', someone, 5]])
  })

  it('registers one account at a time, and none before the list is read', async () => {
    const wait = later()
    const { model, sent } = await loaded([wait.answer, listed()])
    const run = model.add(someone)
    await model.add(someone)
    wait.give(registered('reg_2'))
    await run
    const reading = createAllowlist({ send: answering([]).send, leave: vi.fn() })
    await reading.add(someone)
    const unread = answering([json(503, { error: 'not now' })])
    const failing = createAllowlist({ send: unread.send, leave: vi.fn() })
    await failing.load(first)
    await failing.add(someone)
    expect([methods(sent).filter((one) => one.startsWith('POST')).length, reading.adding.value, methods(unread.sent)]).toEqual([1, { kind: 'idle' }, [`GET ${allowlistPath}`]])
  })

  it('drops a registration that answers after another Admin is shown, and reads their list again, which holds it', async () => {
    const wait = later()
    const { model, sent } = await loaded([wait.answer, listed(), listed(entryJson('reg_2'))])
    const adding = model.add(someone)
    await model.load(second)
    wait.give(registered('reg_2'))
    await adding
    await vi.waitFor(() => { expect(entriesOf(model)?.map((one) => one.id)).toEqual(['reg_2']) })
    expect([model.adding.value, methods(sent).filter((one) => one.startsWith('GET')).length]).toEqual([{ kind: 'idle' }, 3])
  })

  it('keeps the newest session of the person shown, and does not read the list again for it', async () => {
    const { model, sent } = await loaded([removed(), listed()])
    await model.load({ userId: 'usr_first', csrfToken: 'token-1b' })
    await model.remove('reg_1')
    await settled(sent, 2)
    expect([methods(sent), new Headers(sent[1]?.init.headers).get(csrfHeader)]).toEqual([
      [`GET ${allowlistPath}`, `DELETE ${allowlistPath}/reg_1`, `GET ${allowlistPath}`], 'token-1b',
    ])
  })

  it('takes the latest reading of the list, not one that answers after it', async () => {
    const wait = later()
    const { model } = await loaded([registered('reg_2'), wait.answer, removed(), listed(entryJson('reg_1', { status: 'removed' }), entryJson('reg_2'))])
    await model.add(someone)
    await model.remove('reg_1')
    await vi.waitFor(() => { expect(entriesOf(model)?.length).toBe(2) })
    wait.give(listed(entryJson('reg_1')))
    await new Promise((resolve) => { setTimeout(resolve, 20) })
    expect(entriesOf(model)?.map((one) => one.status.kind)).toEqual(['removed', 'open'])
  })

  it('reads the list again when a removal answers while the list is read', async () => {
    const slowRemove = later()
    const slowRead = later()
    const { model, sent } = await loaded([slowRemove.answer, json(404, { error: 'no entry' }), json(503, { error: 'not now' }), slowRead.answer, listed(entryJson('reg_1', { status: 'removed' }))])
    const removing = model.remove('reg_1')
    await model.remove('reg_2')
    await vi.waitFor(() => { expect(model.view.value.kind).toBe('failed') })
    const retried = model.retry()
    slowRemove.give(removed())
    await removing
    slowRead.give(listed(entryJson('reg_1')))
    await retried
    expect([entriesOf(model)?.map((one) => one.status.kind), sent.filter((one) => one.init.method === 'GET').length]).toEqual([['removed'], 4])
  })

  it('removes an entry and reads the list again, and takes one the server closed before as done', async () => {
    const { model, sent } = await loaded([removed(), listed(), json(409, { error: 'consumed' }), listed()])
    await model.remove('reg_1')
    await settled(sent, 2)
    const done = model.removing.value.get('reg_1')
    await model.remove('reg_2')
    await settled(sent, 3)
    expect([done, model.removing.value.get('reg_2')]).toEqual([{ kind: 'done', before: false }, { kind: 'done', before: true }])
  })

  it('counts the refusals of a removal, and does not know what came of one the server failed', async () => {
    const { model, sent } = await loaded([json(404, { error: 'no entry' }), listed(), json(404, { error: 'no entry' }), listed(), json(500, { error: 'failed' }), listed(), 'no answer', listed()])
    const kinds = []
    for (let n = 0; n < 4; n += 1) {
      await model.remove('reg_1')
      await settled(sent, n + 2)
      const now = model.removing.value.get('reg_1')
      kinds.push(now?.kind === 'refused' || now?.kind === 'unknown' ? [now.kind, now.attempts] : null)
    }
    expect(kinds).toEqual([['refused', 1], ['refused', 2], ['unknown', 3], ['unknown', 4]])
  })

  it('removes an entry once at a time', async () => {
    const wait = later()
    const { model, sent } = await loaded([wait.answer, listed()])
    const run = model.remove('reg_1')
    await model.remove('reg_1')
    wait.give(removed())
    await run
    expect(methods(sent).filter((one) => one.startsWith('DELETE')).length).toBe(1)
  })

  it('leaves once when two requests find that the session ended, and marks both under way', async () => {
    const wait = later()
    const { model, leave } = await loaded([wait.answer, noSession()])
    const removing = model.remove('reg_1')
    await model.add(someone)
    const marked = model.removing.value.get('reg_1')
    wait.give(noSession())
    await removing
    expect([model.adding.value, marked, model.removing.value.get('reg_1'), leave.mock.calls.length]).toEqual([{ kind: 'leaving' }, { kind: 'leaving' }, { kind: 'leaving' }, 1])
  })

  it('leaves once when a reading and a write both find that the session ended', async () => {
    const slowRead = later()
    const { model, leave } = await loaded([registered('reg_2'), slowRead.answer, noSession()])
    await model.add(someone)
    await model.remove('reg_1')
    slowRead.give(noSession())
    await new Promise((resolve) => { setTimeout(resolve, 20) })
    expect([leave.mock.calls.length, model.view.value.kind]).toEqual([1, 'read'])
  })

  it('reads once for two retries at once', async () => {
    const wait = later()
    const { send, sent } = answering([json(503, { error: 'not now' }), wait.answer])
    const model = createAllowlist({ send, leave: vi.fn() })
    await model.load(first)
    const retries = [model.retry(), model.retry()]
    wait.give(listed())
    await Promise.all(retries)
    expect([sent.length, model.view.value.kind]).toEqual([2, 'read'])
  })

  it('keeps what came of the requests before when the browser leaves', async () => {
    const { model, sent, leave } = await loaded([json(404, { error: 'no entry' }), listed(), noSession()])
    await model.remove('reg_9')
    await settled(sent, 2)
    await model.remove('reg_1')
    expect([model.removing.value.get('reg_9'), model.removing.value.get('reg_1'), leave.mock.calls.length]).toEqual([
      { kind: 'refused', problem: { kind: 'refused', status: 404, reason: 'no entry' }, attempts: 1 }, { kind: 'leaving' }, 1,
    ])
  })
})

describe('following the console', () => {
  const signedIn = (role: 'admin' | 'member', session: Session = first): View => ({
    kind: 'signed_in', session, who: { id: session.userId, role }, signOut: { kind: 'idle' },
  })

  it('reads the allowlist for an Admin and sends nothing for anyone else', async () => {
    const { send, sent } = answering([listed(), listed()])
    const model = createAllowlist({ send, leave: vi.fn() })
    const frame = signal<View>({ kind: 'reading', slow: false })
    const stop = followAllowlist(frame, model)
    frame.value = signedIn('member')
    frame.value = { kind: 'signed_in', session: first, who: { id: first.userId, role: 'unrecognised' }, signOut: { kind: 'idle' } }
    const asMember = methods(sent)
    frame.value = signedIn('admin', second)
    await vi.waitFor(() => { expect(model.view.value.kind).toBe('read') })
    stop()
    frame.value = signedIn('admin')
    expect([asMember, methods(sent), model.view.value.kind === 'read' ? model.view.value.forUser : null]).toEqual([[], [`GET ${allowlistPath}`], 'usr_second'])
  })

  it('forgets the list once the console shows no Admin, reads nothing for an answer that comes after, and reads afresh for the Admin again', async () => {
    const wait = later()
    const { send, sent } = answering([listed(entryJson('reg_1')), wait.answer, listed(entryJson('reg_1'), entryJson('reg_2'))])
    const model = createAllowlist({ send, leave: vi.fn() })
    const frame = signal<View>(signedIn('admin'))
    const stop = followAllowlist(frame, model)
    await vi.waitFor(() => { expect(model.view.value.kind).toBe('read') })
    const adding = model.add(someone)
    frame.value = { kind: 'changed', next: 'idle' }
    const stopped = [model.view.value, model.adding.value]
    wait.give(registered('reg_2'))
    await adding
    const late = [model.adding.value, methods(sent).filter((one) => one.startsWith('GET')).length]
    frame.value = signedIn('admin')
    await vi.waitFor(() => { expect(model.view.value.kind === 'read' ? model.view.value.entries.length : null).toBe(2) })
    stop()
    expect([stopped, late]).toEqual([[{ kind: 'waiting' }, { kind: 'idle' }], [{ kind: 'idle' }, 1]])
  })
})
