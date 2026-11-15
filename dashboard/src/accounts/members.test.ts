// @vitest-environment happy-dom
//
// The people of the server, as an Admin reads them: what the server's answer
// reads as, how the list moves, and the panel in each step. What a step says
// is not checked here: that is read in a browser.
import { afterEach, describe, expect, it, vi } from 'vitest'
import { signal } from '@preact/signals'
import { act, cleanup, fireEvent, render } from '@testing-library/preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import type { View } from './console'
import { MembersPanel } from './member-rows'
import { createMembers, followMembers } from './members'
import type { MembersModel, MembersView } from './members'
import { membersPath, readIdentity, readMembers } from './members-wire'
import type { Member } from './members-wire'
import type { Send, Session } from './wire'

interface Sent { readonly path: string; readonly init: RequestInit }
type Scripted = Response | 'no answer' | Promise<Response>

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

function later(): { readonly answer: Promise<Response>; readonly give: (response: Response) => void } {
  let give: (response: Response) => void = () => { throw new Error('the answer was given before it was asked for') }
  const answer = new Promise<Response>((resolve) => { give = resolve })
  return { answer, give: (response) => { give(response) } }
}

const json = (status: number, body: unknown): Response =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } })
const github = { provider: 'github', user_id: 12345 }
const google = { provider: 'google', sub: '109876543210987654321' }
const memberJson = (id: string, extra: Record<string, unknown> = {}) =>
  ({ user_id: id, identity: github, role: 'member', status: 'active', held: [], ...extra })
const listed = (...members: readonly unknown[]): Response => json(200, { members })

const first: Session = { userId: 'usr_first', csrfToken: 'token-1' }
const second: Session = { userId: 'usr_second', csrfToken: 'token-2' }

afterEach(() => {
  cleanup()
  vi.useRealTimers()
  vi.restoreAllMocks()
})

describe('reading the people of the server', () => {
  it('reads each person, the account they sign in with and a change held, with words it does not know kept apart', () => {
    expect(readMembers({
      members: [
        memberJson('usr_1', { role: 'admin' }),
        memberJson('usr_2', { identity: google, status: 'disabled', held: ['delete', 'disable', 'revoke'] }),
        memberJson('usr_3', { identity: { provider: 'gitlab', id: 7 }, status: 'paused', held: ['block', 'purge'] }),
      ],
    })).toEqual([
      { userId: 'usr_1', identity: { provider: 'github', userId: 12345 }, role: 'admin', status: 'active', held: [] },
      { userId: 'usr_2', identity: { provider: 'google', sub: '109876543210987654321' }, role: 'member', status: 'disabled', held: ['delete', 'disable', 'revoke'] },
      { userId: 'usr_3', identity: { provider: 'unrecognised' }, role: 'member', status: 'unrecognised', held: ['unrecognised'] },
    ])
  })

  it('does not read an identity the server would not have written', () => {
    expect([
      readIdentity({ user_id: 1, provider: 'github' }),
      readIdentity({ provider: 'github', user_id: 0 }),
      readIdentity({ provider: 'github', user_id: 1.5 }),
      readIdentity({ provider: 'github', user_id: '1' }),
      readIdentity({ provider: 'google', sub: '' }),
      readIdentity({ provider: 'google', sub: 's', extra: true }),
      readIdentity({ provider: 7 }),
      readIdentity('github'),
    ]).toEqual(Array.from({ length: 8 }, () => null))
  })

  it('does not read a list with a person that is not what the route promises', () => {
    const one = (extra: Record<string, unknown>) => readMembers({ members: [memberJson('usr_1', extra)] })
    expect([
      one({ user_id: '' }),
      one({ role: 'owner' }),
      one({ status: 1 }),
      one({ held: 'disable' }),
      one({ held: ['revoke', 'disable'] }),
      one({ held: ['disable', 'disable'] }),
      one({ held: [''] }),
      one({ identity: { provider: 'github' } }),
      readMembers({ members: [memberJson('usr_1'), memberJson('usr_1')] }),
      readMembers({ members: {} }),
    ]).toEqual(Array.from({ length: 10 }, () => null))
  })
})

describe('the people an Admin sees', () => {
  const peopleOf = (model: MembersModel): readonly string[] | null => {
    const now = model.view.value
    return now.kind === 'read' ? now.members.map((one) => one.userId) : null
  }

  it('reads the people with the cookie of the session, says when it waits, and reads again after a failure', async () => {
    vi.useFakeTimers()
    const wait = later()
    const { send, sent } = answering([wait.answer, json(503, { error: 'not now' }), listed(memberJson('usr_first', { role: 'admin' }))])
    const model = createMembers({ send, leave: vi.fn() })
    const run = model.load(first)
    await vi.advanceTimersByTimeAsync(1000)
    const slow = model.view.value
    wait.give(json(503, { error: 'not now' }))
    await run
    await model.retry()
    const failed = model.view.value
    await model.retry()
    expect([slow, failed.kind === 'failed' ? failed.failure.attempts : null, peopleOf(model)]).toEqual([{ kind: 'reading', forUser: 'usr_first', slow: true }, 2, ['usr_first']])
    expect(sent.map(({ path, init }) => [path, init.method, init.credentials, new Headers(init.headers).has('authorization')])).toEqual(
      Array.from({ length: 3 }, () => [membersPath, 'GET', 'same-origin', false]),
    )
  })

  it('leaves when the session ended, and reads nothing again for the person shown', async () => {
    const { send, sent } = answering([json(401, { error: 'no session' })])
    const leave = vi.fn()
    const model = createMembers({ send, leave })
    await model.load(first)
    await model.load(first)
    await model.retry()
    expect([model.view.value, leave.mock.calls.length, sent.length]).toEqual([{ kind: 'leaving', forUser: 'usr_first' }, 1, 1])
  })

  it('takes the reading of the latest person shown, not one that answers after it', async () => {
    const wait = later()
    const { send } = answering([wait.answer, listed(memberJson('usr_second', { role: 'admin' }))])
    const model = createMembers({ send, leave: vi.fn() })
    const firstRead = model.load(first)
    await model.load(second)
    wait.give(listed(memberJson('usr_first')))
    await firstRead
    expect([peopleOf(model), model.view.value.kind === 'read' ? model.view.value.forUser : null]).toEqual([['usr_second'], 'usr_second'])
  })

  it('reads the people for an Admin and sends nothing for a Member', async () => {
    const { send, sent } = answering([listed()])
    const model = createMembers({ send, leave: vi.fn() })
    const frame = signal<View>({ kind: 'reading', slow: false })
    const stop = followMembers(frame, model)
    frame.value = { kind: 'signed_in', session: first, who: { id: 'usr_first', role: 'member' }, signOut: { kind: 'idle' } }
    const asMember = sent.length
    frame.value = { kind: 'signed_in', session: second, who: { id: 'usr_second', role: 'admin' }, signOut: { kind: 'idle' } }
    await vi.waitFor(() => { expect(model.view.value.kind).toBe('read') })
    stop()
    expect([asMember, sent.length]).toEqual([0, 1])
  })
})

describe('the members panel', () => {
  const member = (id: string, extra: Partial<Member> = {}): Member =>
    ({ userId: id, identity: { provider: 'github', userId: 12345 }, role: 'member', status: 'active', held: [], ...extra })
  const readView = (members: readonly Member[]): MembersView => ({ kind: 'read', forUser: 'usr_first', members })
  const showing = (view: MembersView): MembersModel => ({ view: signal(view), load: vi.fn(() => Promise.resolve()), retry: vi.fn(() => Promise.resolve()) })
  const panelOf = (model: MembersModel) => render(html`<main><h1>내 계정</h1><${MembersPanel} model=${model} /></main>`).container
  const many = [
    member('usr_disabled', { status: 'disabled' }),
    member('usr_member', { identity: { provider: 'google', sub: '109876543210987654321' } }),
    member('usr_first', { role: 'admin' }),
    member('usr_held', { held: ['disable', 'revoke'] }),
    member('usr_new_word', { status: 'unrecognised', identity: { provider: 'unrecognised' }, role: 'admin' }),
  ]
  const unread: MembersView = { kind: 'failed', forUser: 'usr_first', failure: { problem: { kind: 'unreachable' }, attempts: 1 }, next: 'idle' }
  const steps: ReadonlyArray<readonly [string, MembersModel]> = [
    ['while the list is read', showing({ kind: 'reading', forUser: 'usr_first', slow: true })],
    ['when the list could not be read', showing(unread)],
    ['when the account is not an Admin now', showing({ ...unread, failure: { problem: { kind: 'refused', status: 403, reason: 'only an Admin reads this' }, attempts: 2 } })],
    ['with a person in each state', showing(readView(many))],
    ['with no one', showing(readView([]))],
    ['while the browser leaves', showing({ kind: 'leaving', forUser: 'usr_first' })],
  ]

  it.each(steps)('passes the accessibility rules %s', async (_name, model) => {
    expect(await axe(panelOf(model))).toHaveNoViolations()
  })

  it('says a list that could not be read where a screen reader announces it, and asks the model to read again', () => {
    const alerts = steps.map(([name, model]) => {
      const found = [name, panelOf(model).querySelectorAll('[role=alert]').length]
      cleanup()
      return found
    })
    const model = showing(unread)
    const retry = [...panelOf(model).querySelectorAll<HTMLButtonElement>('button')].find((one) => one.textContent === '다시 시도')
    if (retry !== undefined) fireEvent.click(retry)
    expect([alerts, vi.mocked(model.retry).mock.calls.length]).toEqual([
      steps.map(([name]) => [name, name === 'when the list could not be read' || name === 'when the account is not an Admin now' ? 1 : 0]), 1,
    ])
  })

  it('lists the people who can sign in first and Admins before Members, and marks the one signed in', () => {
    const container = panelOf(showing(readView(many)))
    const rows = [...container.querySelectorAll('.rows > li')]
    const marked = rows.map((row) => row.querySelectorAll('.chip').length)
    expect([rows.map((row) => row.querySelector('.mono')?.textContent), marked]).toEqual([
      ['…_first', '…member', '…w_word', '…sabled', '…r_held'],
      [2, 1, 2, 2, 2],
    ])
  })

  it('puts the focus on the heading once a retry read the list', async () => {
    const view = signal<MembersView>(unread)
    const container = panelOf({ ...showing(readView([])), view })
    const retry = [...container.querySelectorAll<HTMLButtonElement>('button')].find((one) => one.textContent === '다시 시도')
    retry?.focus()
    await act(() => { view.value = readView([]) })
    expect([retry !== undefined, document.activeElement?.id]).toEqual([true, 'members-heading'])
  })

  it('keeps the line a screen reader reads out under the heading as one element in every step', async () => {
    const view = signal<MembersView>({ kind: 'reading', forUser: 'usr_first', slow: true })
    const container = panelOf({ ...showing(readView([])), view })
    const line = () => container.querySelector('#members-heading ~ [role=status]')
    const firstLine = line()
    const seen = []
    for (const next of [unread, readView(many), { kind: 'leaving', forUser: 'usr_first' } as const]) {
      await act(() => { view.value = next })
      seen.push(line() === firstLine)
    }
    expect(seen).toEqual([true, true, true])
  })
})
