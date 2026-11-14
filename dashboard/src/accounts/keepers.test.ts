// @vitest-environment happy-dom
//
// The Keepers of a person: what the server's answers read as, what a make and
// an assignment send, how the list and the requests move, and the panel in
// each step. What a step says and where it puts things is not checked here:
// that is read in a browser.
import { afterEach, describe, expect, it, vi } from 'vitest'
import { signal } from '@preact/signals'
import { act, cleanup, fireEvent, render } from '@testing-library/preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { KeepersPanel, runtimeChoices } from './keeper-rows'
import { createKeepers } from './keepers'
import { assign, assignPath, keepersPath, make, readAssigned, readKeepers, readMade } from './keepers-wire'
import type { Assign, Keeper, KeepersModel, ListView, Make } from './keepers'
import { createChecks } from './check'
import { createConnect } from './connect'
import type { PanelView, SubscriptionsModel } from './subscriptions'
import type { TalkModel, TalkView } from './talk'
import { csrfHeader } from './wire'
import type { Integration, Owned, Send, Session } from './wire'

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

const listed = (...keepers: ReadonlyArray<readonly [string, string | null]>): Response =>
  json(200, { keepers: keepers.map(([keeper_id, runtime_id]) => ({ keeper_id, runtime_id })) })
const madeAnswer = (name: string, record = 'made'): Response => json(200, { keeper_id: name, record })
const assignedAnswer = (name: string, runtimeId: string, record = 'assigned'): Response =>
  json(200, { keeper_id: name, runtime_id: runtimeId, record })
const badName = (): Response => json(400, { error: 'keeper_name must match [A-Za-z0-9._-]+' })
const unknownRuntime = (): Response => json(404, { error: 'No Runtime of yours has this id.' })
const notReady = (): Response => json(503, { error: 'The Keeper could not be recorded.' })
const noSession = (): Response => json(401, { error: 'no session cookie came with the request' })

const first: Session = { userId: 'usr_first', csrfToken: 'token-1' }
const second: Session = { userId: 'usr_second', csrfToken: 'token-2' }

const paths = (sent: readonly Sent[]): string[] => sent.map((one) => one.path)
const bodies = (sent: readonly Sent[]): unknown[] => sent.filter((one) => one.init.method === 'POST').map((one) => JSON.parse(String(one.init.body)))
const keepersOf = (model: KeepersModel): readonly Keeper[] | null => {
  const now = model.view.value
  return now.kind === 'read' ? now.keepers : null
}

afterEach(() => {
  cleanup()
  vi.useRealTimers()
  vi.restoreAllMocks()
})

describe('reading the answers about Keepers', () => {
  it('reads the Keepers with the Runtime each runs on, or none', () => {
    expect(readKeepers({ keepers: [{ keeper_id: 'alpha', runtime_id: 'rt_1' }, { keeper_id: 'beta', runtime_id: null }] }))
      .toEqual([{ id: 'alpha', runtimeId: 'rt_1' }, { id: 'beta', runtimeId: null }])
    expect(readKeepers({ keepers: [] })).toEqual([])
  })

  it.each([
    ['no list', {}],
    ['a Keeper with no name', { keepers: [{ keeper_id: '', runtime_id: null }] }],
    ['a Keeper with no Runtime field', { keepers: [{ keeper_id: 'alpha' }] }],
    ['a Runtime that is not an id', { keepers: [{ keeper_id: 'alpha', runtime_id: 3 }] }],
  ])('refuses a list with %s', (_name, body) => {
    expect(readKeepers(body)).toBeNull()
  })

  it('reads whether a make or an assignment found it done before', () => {
    expect([readMade({ keeper_id: 'alpha', record: 'made' }), readMade({ keeper_id: 'alpha', record: 'existing' })])
      .toEqual([{ id: 'alpha', existing: false }, { id: 'alpha', existing: true }])
    expect([readAssigned({ keeper_id: 'alpha', runtime_id: 'rt_1', record: 'assigned' }), readAssigned({ keeper_id: 'alpha', runtime_id: 'rt_1', record: 'existing' })])
      .toEqual([{ id: 'alpha', runtimeId: 'rt_1', existing: false }, { id: 'alpha', runtimeId: 'rt_1', existing: true }])
    expect([
      readMade({ keeper_id: 'alpha', record: 'assigned' }),
      readAssigned({ keeper_id: 'alpha', record: 'assigned' }),
      readAssigned({ keeper_id: 'alpha', runtime_id: 'rt_1', record: 'made' }),
    ]).toEqual([null, null, null])
  })
})

describe('sending a make and an assignment', () => {
  it('names the Keeper and the Runtime, with the token of the session and no other credential', async () => {
    const { send, sent } = answering([madeAnswer('alpha'), assignedAnswer('alpha', 'rt_1')])
    await make(send, 'token-1', 'alpha')
    await assign(send, 'token-1', 'alpha', 'rt_1')
    expect(paths(sent)).toEqual([keepersPath, assignPath])
    for (const { init } of sent) {
      const headers = new Headers(init.headers)
      expect([init.method, init.credentials, headers.get(csrfHeader), headers.has('authorization')]).toEqual(['POST', 'same-origin', 'token-1', false])
    }
    expect(bodies(sent)).toEqual([{ keeper_id: 'alpha' }, { keeper_id: 'alpha', runtime_id: 'rt_1' }])
  })
})

describe('the Keepers of a person', () => {
  it('reads the list, says when it is slow, and reads again after a failure', async () => {
    vi.useFakeTimers()
    const wait = later()
    const { send } = answering([wait.answer, listed(['alpha', null])])
    const model = createKeepers({ send, leave: vi.fn() })
    const run = model.load(first)
    await vi.advanceTimersByTimeAsync(1000)
    expect(model.view.value).toEqual({ kind: 'reading', forUser: 'usr_first', slow: true })
    wait.give(notReady())
    await run
    expect(model.view.value.kind).toBe('failed')
    await model.retry()
    expect(keepersOf(model)).toEqual([{ id: 'alpha', runtimeId: null }])
  })

  it('makes a Keeper with the name trimmed, puts it in the list, and gives it the Runtime picked', async () => {
    const { send, sent } = answering([listed(), madeAnswer('alpha'), assignedAnswer('alpha', 'rt_1')])
    const model = createKeepers({ send, leave: vi.fn() })
    await model.load(first)
    expect(await model.make('  alpha ', 'rt_1')).toEqual({ kind: 'made', name: 'alpha', existing: false })
    await vi.waitFor(() => { expect(model.assigning.value.get('alpha')).toEqual({ kind: 'done', runtimeId: 'rt_1', existing: false }) })
    expect(bodies(sent)).toEqual([{ keeper_id: 'alpha' }, { keeper_id: 'alpha', runtime_id: 'rt_1' }])
    expect(keepersOf(model)).toEqual([{ id: 'alpha', runtimeId: 'rt_1' }])
  })

  it('makes a Keeper without a Runtime when none is picked', async () => {
    const { send, sent } = answering([listed(['beta', 'rt_2']), madeAnswer('alpha')])
    const model = createKeepers({ send, leave: vi.fn() })
    await model.load(first)
    await model.make('alpha', null)
    expect(paths(sent)).toEqual([keepersPath, keepersPath])
    expect(keepersOf(model)).toEqual([{ id: 'beta', runtimeId: 'rt_2' }, { id: 'alpha', runtimeId: null }])
  })

  it('sends nothing for an empty name or the name of a Keeper in the list, and counts the tries', async () => {
    const { send, sent } = answering([listed(['alpha', null])])
    const model = createKeepers({ send, leave: vi.fn() })
    await model.load(first)
    await model.make('  ', null)
    await model.make('', null)
    const blank = model.making.value
    await model.make('alpha', 'rt_1')
    expect([blank, model.making.value]).toEqual([
      { kind: 'not_sent', why: 'blank', name: '', attempts: 2 },
      { kind: 'not_sent', why: 'taken', name: 'alpha', attempts: 1 },
    ])
    expect(sent).toHaveLength(1)
  })

  it('reads the list again for a Keeper another page made first, and gives it nothing', async () => {
    const { send, sent } = answering([listed(), madeAnswer('alpha', 'existing'), listed(['alpha', 'rt_9'])])
    const model = createKeepers({ send, leave: vi.fn() })
    await model.load(first)
    await model.make('alpha', 'rt_1')
    await vi.waitFor(() => { expect(keepersOf(model)).toEqual([{ id: 'alpha', runtimeId: 'rt_9' }]) })
    expect(paths(sent)).toEqual([keepersPath, keepersPath, keepersPath])
    expect(model.assigning.value.size).toBe(0)
  })

  it('counts the refusals of one name in a row, and starts again for another', async () => {
    const { send } = answering([listed(), badName(), badName(), badName()])
    const model = createKeepers({ send, leave: vi.fn() })
    await model.load(first)
    await model.make('a b', null)
    await model.make('a b', null)
    const twice = model.making.value
    await model.make('c d', null)
    expect([twice, model.making.value]).toEqual([
      { kind: 'refused', name: 'a b', problem: { kind: 'refused', status: 400, reason: 'keeper_name must match [A-Za-z0-9._-]+' }, attempts: 2 },
      { kind: 'refused', name: 'c d', problem: { kind: 'refused', status: 400, reason: 'keeper_name must match [A-Za-z0-9._-]+' }, attempts: 1 },
    ])
  })

  it('reads the list again after a make or an assignment whose answer did not come', async () => {
    const { send, sent } = answering([listed(), 'no answer', listed(['alpha', null]), 'no answer', listed(['alpha', 'rt_1'])])
    const model = createKeepers({ send, leave: vi.fn() })
    await model.load(first)
    expect(await model.make('alpha', null)).toEqual({ kind: 'unknown', name: 'alpha', problem: { kind: 'unreachable' }, attempts: 1 })
    await vi.waitFor(() => { expect(keepersOf(model)).toEqual([{ id: 'alpha', runtimeId: null }]) })
    await model.assign('alpha', 'rt_1')
    expect(model.assigning.value.get('alpha')).toEqual({ kind: 'unknown', runtimeId: 'rt_1', problem: { kind: 'unreachable' }, attempts: 1 })
    await vi.waitFor(() => { expect(keepersOf(model)).toEqual([{ id: 'alpha', runtimeId: 'rt_1' }]) })
    expect(paths(sent)).toEqual([keepersPath, keepersPath, keepersPath, assignPath, keepersPath])
  })

  it('reads a failure of the server as a make whose end it does not know, and reads the list again', async () => {
    const { send, sent } = answering([listed(), notReady(), listed(['alpha', null])])
    const model = createKeepers({ send, leave: vi.fn() })
    await model.load(first)
    expect(await model.make('alpha', null)).toEqual({
      kind: 'unknown', name: 'alpha', problem: { kind: 'refused', status: 503, reason: 'The Keeper could not be recorded.' }, attempts: 1,
    })
    await vi.waitFor(() => { expect(keepersOf(model)).toEqual([{ id: 'alpha', runtimeId: null }]) })
    expect(paths(sent)).toEqual([keepersPath, keepersPath, keepersPath])
  })

  it('settles a make once the server made the Keeper, while the model picked is still being given', async () => {
    const wait = later()
    const { send } = answering([listed(), madeAnswer('alpha'), wait.answer])
    const model = createKeepers({ send, leave: vi.fn() })
    await model.load(first)
    expect([await model.make('alpha', 'rt_1'), model.assigning.value.get('alpha')]).toEqual([
      { kind: 'made', name: 'alpha', existing: false }, { kind: 'sending', runtimeId: 'rt_1' },
    ])
    wait.give(assignedAnswer('alpha', 'rt_1'))
    await vi.waitFor(() => { expect(keepersOf(model)).toEqual([{ id: 'alpha', runtimeId: 'rt_1' }]) })
  })

  it('reads the list again when a reading began before a make answered, and keeps the Keeper made', async () => {
    const stale = later()
    const { send, sent } = answering([listed(['alpha', null]), 'no answer', stale.answer, madeAnswer('gamma'), listed(['alpha', null], ['gamma', null])])
    const model = createKeepers({ send, leave: vi.fn() })
    await model.load(first)
    await model.assign('alpha', 'rt_1')
    await model.make('gamma', null)
    stale.give(listed(['alpha', null]))
    // The list holds gamma from the answer of the make before the stale
    // reading lands, so the test waits for the reading that follows it.
    await vi.waitFor(() => { expect(paths(sent)).toEqual([keepersPath, assignPath, keepersPath, keepersPath, keepersPath]) })
    await vi.waitFor(() => { expect(keepersOf(model)).toEqual([{ id: 'alpha', runtimeId: null }, { id: 'gamma', runtimeId: null }]) })
  })

  it('counts the refused assignments of one Runtime in a row, and starts again for another', async () => {
    const { send } = answering([listed(['alpha', null]), unknownRuntime(), unknownRuntime(), unknownRuntime()])
    const model = createKeepers({ send, leave: vi.fn() })
    await model.load(first)
    await model.assign('alpha', 'rt_1')
    await model.assign('alpha', 'rt_1')
    const twice = model.assigning.value.get('alpha')
    await model.assign('alpha', 'rt_2')
    expect([twice?.kind, twice?.kind === 'refused' ? twice.attempts : 0]).toEqual(['refused', 2])
    expect(model.assigning.value.get('alpha')).toMatchObject({ kind: 'refused', runtimeId: 'rt_2', attempts: 1 })
  })

  it('sends no second assignment of a Keeper while one runs, and assigns another Keeper alongside', async () => {
    const wait = later()
    const { send, sent } = answering([listed(['alpha', null], ['beta', null]), wait.answer, assignedAnswer('beta', 'rt_1')])
    const model = createKeepers({ send, leave: vi.fn() })
    await model.load(first)
    const run = model.assign('alpha', 'rt_1')
    await model.assign('alpha', 'rt_2')
    await model.assign('beta', 'rt_1')
    wait.give(assignedAnswer('alpha', 'rt_1'))
    await run
    expect(bodies(sent)).toEqual([{ keeper_id: 'alpha', runtime_id: 'rt_1' }, { keeper_id: 'beta', runtime_id: 'rt_1' }])
    expect(keepersOf(model)).toEqual([{ id: 'alpha', runtimeId: 'rt_1' }, { id: 'beta', runtimeId: 'rt_1' }])
  })

  it('sends no second make while one runs', async () => {
    const wait = later()
    const { send, sent } = answering([listed(), wait.answer])
    const model = createKeepers({ send, leave: vi.fn() })
    await model.load(first)
    const run = model.make('alpha', null)
    expect(await model.make('beta', null)).toBeNull()
    wait.give(madeAnswer('alpha'))
    await run
    expect(bodies(sent)).toEqual([{ keeper_id: 'alpha' }])
  })

  it('sends nothing before the list is read', async () => {
    const wait = later()
    const { send, sent } = answering([wait.answer])
    const model = createKeepers({ send, leave: vi.fn() })
    await model.make('alpha', null)
    await model.assign('alpha', 'rt_1')
    expect(sent).toHaveLength(0)
    const reading = model.load(first)
    await model.make('alpha', null)
    wait.give(listed())
    await reading
    expect(paths(sent)).toEqual([keepersPath])
  })

  it('leaves for the sign-in page once when a request finds that the session ended, and sends nothing more', async () => {
    const wait = later()
    const { send, sent } = answering([listed(['beta', null]), wait.answer, noSession()])
    const leave = vi.fn()
    const model = createKeepers({ send, leave })
    await model.load(first)
    const making = model.make('alpha', 'rt_1')
    await model.assign('beta', 'rt_1')
    expect(model.making.value).toEqual({ kind: 'leaving' })
    wait.give(madeAnswer('alpha'))
    await making
    await model.make('gamma', null)
    expect([leave.mock.calls.length, sent.length, model.assigning.value.get('beta')]).toEqual([1, 3, { kind: 'leaving' }])
  })

  it('leaves for the sign-in page when the list finds that the session ended', async () => {
    const leave = vi.fn()
    const model = createKeepers({ send: answering([noSession()]).send, leave })
    await model.load(first)
    expect([model.view.value, leave.mock.calls.length]).toEqual([{ kind: 'leaving', forUser: 'usr_first' }, 1])
  })

  it('makes Keepers again for the person shown after one whose session ended', async () => {
    const { send, sent } = answering([listed(['beta', null]), noSession(), listed(), madeAnswer('alpha')])
    const model = createKeepers({ send, leave: vi.fn() })
    await model.load(first)
    await model.assign('beta', 'rt_1')
    await model.load(second)
    expect(await model.make('alpha', null)).toEqual({ kind: 'made', name: 'alpha', existing: false })
    expect(sent).toHaveLength(4)
  })

  it('takes no answer of a reading or a make for a person no longer shown', async () => {
    const reading = later()
    const making = later()
    const { send } = answering([listed(), making.answer, reading.answer, listed(['beta', null])])
    const model = createKeepers({ send, leave: vi.fn() })
    await model.load(first)
    const run = model.make('alpha', null)
    const firstAgain = model.load({ ...second, userId: 'usr_third' })
    await model.load(second)
    making.give(madeAnswer('alpha'))
    reading.give(listed(['gamma', null]))
    expect([await run, await firstAgain]).toEqual([null, undefined])
    expect([keepersOf(model), model.making.value]).toEqual([[{ id: 'beta', runtimeId: null }], { kind: 'idle' }])
  })

  it('forgets everything for another person, and an answer that comes later changes nothing', async () => {
    const wait = later()
    const { send, sent } = answering([listed(['alpha', null]), wait.answer, listed(['beta', null]), madeAnswer('gamma')])
    const model = createKeepers({ send, leave: vi.fn() })
    await model.load(first)
    const run = model.assign('alpha', 'rt_1')
    await model.load(second)
    wait.give(assignedAnswer('alpha', 'rt_1'))
    await run
    expect([keepersOf(model), model.assigning.value.size]).toEqual([[{ id: 'beta', runtimeId: null }], 0])
    await model.make('gamma', null)
    expect(new Headers(sent[3]?.init.headers).get(csrfHeader)).toBe('token-2')
  })

  it('closes the conversation open for another person, and an answer that comes later changes nothing', async () => {
    const wait = later()
    const { send } = answering([listed(['alpha', null]), wait.answer, listed()])
    const model = createKeepers({ send, leave: vi.fn() })
    await model.load(first)
    const run = model.talking.open('alpha')
    await model.load(second)
    wait.give(json(200, { keeper_id: 'alpha', current_conversation_id: null, conversations: [], conversation_id: null, turns: [] }))
    await run
    expect(model.talking.view.value).toEqual({ kind: 'closed' })
  })

  it('reads no conversation once the list found that the session ended, and reads again for the person shown next', async () => {
    const { send, sent } = answering([noSession(), listed(['alpha', null]), json(200, { keeper_id: 'alpha', current_conversation_id: null, conversations: [], conversation_id: null, turns: [] })])
    const model = createKeepers({ send, leave: vi.fn() })
    await model.load(first)
    await model.talking.open('alpha')
    const before = sent.length
    await model.load(second)
    await model.talking.open('alpha')
    expect([before, model.talking.view.value.kind]).toEqual([1, 'read'])
  })

  it('leaves with what runs left behind when the conversation finds that the session ended', async () => {
    const wait = later()
    const leave = vi.fn()
    const { send, sent } = answering([listed(), wait.answer, noSession()])
    const model = createKeepers({ send, leave })
    await model.load(first)
    const making = model.make('alpha', null)
    await model.talking.open('alpha')
    wait.give(madeAnswer('alpha'))
    await making
    expect([model.making.value, leave.mock.calls.length, sent.length]).toEqual([{ kind: 'leaving' }, 1, 3])
  })
})

// ---- the panel ----

const claude: Integration = { id: 'claude_code', displayName: 'Claude Code', models: ['claude-sonnet-5'], calls: { kind: 'allowed' } }
const codex: Integration = { id: 'codex', displayName: 'Codex', models: ['gpt-5.5'], calls: { kind: 'refused', refusal: 'native_unpublished' } }
const owned: Owned = {
  accounts: [
    { id: 'acct_claude_1', integration: { read: true, value: 'claude_code' } },
    { id: 'acct_codex_1', integration: { read: true, value: 'codex' } },
  ],
  runtimes: [
    { id: 'rt_sonnet', accountId: 'acct_claude_1', model: { read: true, value: 'claude-sonnet-5' } },
    { id: 'rt_opus', accountId: 'acct_claude_1', model: { read: true, value: 'claude-opus-9' } },
    { id: 'rt_unread', accountId: 'acct_claude_1', model: { read: false, unread: 'runtime_not_bound' } },
    { id: 'rt_codex', accountId: 'acct_codex_1', model: { read: true, value: 'gpt-5.5' } },
  ],
}
const noRuntimes: Owned = { accounts: owned.accounts, runtimes: [] }

describe('the models a Keeper can be given', () => {
  it('are the models read on accounts whose subscription a Keeper may run on here', () => {
    expect(runtimeChoices([claude, codex], owned).map((one) => one.runtimeId)).toEqual(['rt_sonnet', 'rt_opus'])
  })
})

const nothingSent: Send = () => Promise.reject(new Error('nothing is sent'))

/** A subscriptions panel that shows `panel`. The panel has its own tests; here it only gives the models. */
const subscriptionsShowing = (panel: PanelView): SubscriptionsModel => ({
  view: signal(panel),
  load: vi.fn(() => Promise.resolve()),
  retry: vi.fn(() => Promise.resolve()),
  connecting: createConnect({ send: nothingSent, leave: vi.fn(), token: () => null, refresh: () => Promise.resolve() }),
  checking: createChecks({ send: nothingSent, leave: vi.fn(), token: () => null, refresh: () => Promise.resolve() }),
})
const readPanel = (mine: Owned = owned): PanelView => ({ kind: 'read', forUser: 'usr_first', integrations: [claude, codex], owned: mine })

interface Shows {
  readonly view?: ListView
  readonly making?: Make
  readonly assigning?: ReadonlyArray<readonly [string, Assign]>
  readonly talk?: TalkView
}
const keepersList = (...keepers: Keeper[]): ListView => ({ kind: 'read', forUser: 'usr_first', keepers })
const alpha: Keeper = { id: 'alpha', runtimeId: 'rt_sonnet' }

/** A conversation that shows what it is given. talk.test.ts reads the conversation itself. */
const talkShowing = (view: TalkView): TalkModel => ({
  view: signal(view),
  open: vi.fn(() => Promise.resolve()),
  close: vi.fn(),
  retry: vi.fn(() => Promise.resolve()),
  reset: vi.fn(),
})

/** A model of Keepers that shows what it is given and counts what it is asked. */
const showing = ({ view = keepersList(alpha), making = { kind: 'idle' }, assigning = [], talk = { kind: 'closed' } }: Shows = {}): KeepersModel => ({
  view: signal(view),
  making: signal(making),
  assigning: signal(new Map(assigning)),
  load: vi.fn(() => Promise.resolve()),
  retry: vi.fn(() => Promise.resolve()),
  make: vi.fn(() => Promise.resolve(null)),
  assign: vi.fn(() => Promise.resolve()),
  talking: talkShowing(talk),
})

const panelOf = (model: KeepersModel, panel: PanelView = readPanel()) =>
  render(html`<main><h1>내 계정</h1><${KeepersPanel} model=${model} subscriptions=${subscriptionsShowing(panel)} /></main>`).container

describe('the Keepers panel', () => {
  const refused = { kind: 'refused', status: 400, reason: 'keeper_name must match' } as const
  const steps: ReadonlyArray<readonly [string, Shows]> = [
    ['while the list is read', { view: { kind: 'reading', forUser: 'usr_first', slow: true } }],
    ['when the list could not be read', { view: { kind: 'failed', forUser: 'usr_first', failure: { problem: { kind: 'unreachable' }, attempts: 2 }, next: 'idle' } }],
    ['with no Keeper', { view: keepersList() }],
    ['with Keepers in each state', { view: keepersList(alpha, { id: 'beta', runtimeId: null }, { id: 'gamma', runtimeId: 'rt_codex' }, { id: 'delta', runtimeId: 'rt_gone' }) }],
    ['while a Keeper is made', { making: { kind: 'sending', name: 'beta' } }],
    ['after a Keeper was made', { making: { kind: 'made', name: 'beta', existing: false } }],
    ['with an empty name', { making: { kind: 'not_sent', why: 'blank', name: '', attempts: 1 } }],
    ['with a name in the list', { making: { kind: 'not_sent', why: 'taken', name: 'alpha', attempts: 2 } }],
    ['with a name the server refused', { making: { kind: 'refused', name: 'a b', problem: refused, attempts: 1 } }],
    ['with a make whose answer did not come', { making: { kind: 'unknown', name: 'beta', problem: { kind: 'unreachable' }, attempts: 1 } }],
    ['while a model is given', { assigning: [['alpha', { kind: 'sending', runtimeId: 'rt_sonnet' }]] }],
    ['after a model was given', { assigning: [['alpha', { kind: 'done', runtimeId: 'rt_sonnet', existing: false }]] }],
    ['with a model the server did not find', { assigning: [['alpha', { kind: 'refused', runtimeId: 'rt_sonnet', problem: { kind: 'refused', status: 404, reason: null }, attempts: 1 }]] }],
    ['with an assignment whose answer could not be read', { assigning: [['alpha', { kind: 'unknown', runtimeId: 'rt_sonnet', problem: { kind: 'unreadable' }, attempts: 3 }]] }],
    ['while the browser leaves', { making: { kind: 'leaving' }, assigning: [['alpha', { kind: 'leaving' }]] }],
    ['with a conversation open', { talk: { kind: 'read', keeperId: 'alpha', conversation: { id: 'cv_1', earlier: 0, turns: [{ message: '안녕', askedAtMs: 1, outcome: { kind: 'answered', text: '네', model: 'claude-sonnet-5', atMs: 2 } }] } } }],
    ['with a conversation that could not be read', { talk: { kind: 'failed', keeperId: 'alpha', failure: { problem: { kind: 'unreachable' }, attempts: 1 }, next: 'idle' } }],
  ]
  const count = (selector: string) => steps.map(([name, shows]) => {
    const found = panelOf(showing(shows)).querySelectorAll(selector).length
    cleanup()
    return [name, found]
  })
  const named = (counts: Readonly<Record<string, number>>) => steps.map(([name]) => [name, counts[name] ?? 0])

  it.each(steps)('passes the accessibility rules %s', async (_name, shows) => {
    expect(await axe(panelOf(showing(shows)))).toHaveNoViolations()
  })

  it('says each outcome that came to nothing where a screen reader announces it', () => {
    expect(count('[role=alert]')).toEqual(named({
      'when the list could not be read': 1,
      'with an empty name': 1,
      'with a name in the list': 1,
      'with a name the server refused': 1,
      'with a make whose answer did not come': 1,
      'with a model the server did not find': 1,
      'with an assignment whose answer could not be read': 1,
      'with a conversation that could not be read': 1,
    }))
  })

  it('has one line a screen reader reads out under the form and in each card with a field, in every step', () => {
    const lines = steps.map(([name, shows]) => {
      const container = panelOf(showing(shows))
      const found = [container.querySelectorAll('form.keeper-form ~ [role=status]').length, container.querySelectorAll('.row').length, container.querySelectorAll('.row > [role=status]').length]
      cleanup()
      return [name, found[0] === (shows.view === undefined || shows.view.kind === 'read' ? 1 : 0) && found[1] === found[2]]
    })
    expect(lines).toEqual(steps.map(([name]) => [name, true]))
  })

  it('marks the buttons whose request runs, or that the browser leaves', () => {
    expect(count('button[aria-disabled=true]')).toEqual(named({
      'while a Keeper is made': 1,
      'while a model is given': 1,
      'while the browser leaves': 2,
    }))
  })

  it('offers only the models a Keeper can run on, and no field to a Keeper when there is none', () => {
    const container = panelOf(showing({ view: keepersList(alpha, { id: 'gamma', runtimeId: 'rt_codex' }) }))
    const options = [...container.querySelectorAll('#keeper-field-gamma option')].map((one) => one.getAttribute('value'))
    expect(options).toEqual(['rt_sonnet', 'rt_opus'])
    cleanup()
    const none = panelOf(showing(), readPanel(noRuntimes))
    expect([none.querySelectorAll('form.check').length, none.querySelectorAll('#keeper-new-runtime').length]).toEqual([0, 0])
    cleanup()
    const unread = panelOf(showing(), { kind: 'reading', forUser: 'usr_first', slow: false })
    expect(unread.querySelectorAll('select')).toHaveLength(0)
  })

  it('gives the Keeper the model the person picked', () => {
    const model = showing({ view: keepersList({ id: 'beta', runtimeId: null }) })
    const container = panelOf(model)
    const select = container.querySelector('#keeper-field-beta')
    const form = container.querySelector('form.check')
    if (select === null || form === null) throw new Error('no field of a model in the card')
    fireEvent.change(select, { target: { value: 'rt_opus' } })
    fireEvent.submit(form)
    expect(model.assign).toHaveBeenCalledWith('beta', 'rt_opus')
  })

  it('has the model a Keeper works with picked in its card', () => {
    const container = panelOf(showing({ view: keepersList({ id: 'alpha', runtimeId: 'rt_opus' }) }))
    expect(container.querySelector<HTMLSelectElement>('#keeper-field-alpha')?.value).toBe('rt_opus')
  })

  it('marks a Keeper that cannot work with a border, not with a colour alone', () => {
    const container = panelOf(showing({ view: keepersList(alpha, { id: 'beta', runtimeId: null }, { id: 'gamma', runtimeId: 'rt_codex' }, { id: 'delta', runtimeId: 'rt_gone' }) }))
    const marked = [...container.querySelectorAll('.row')].map((row) => [row.querySelector('h3')?.textContent, row.querySelectorAll('.chip').length, row.querySelectorAll('.chip-todo').length])
    expect(marked).toEqual([['alpha', 1, 0], ['beta', 1, 1], ['gamma', 1, 1], ['delta', 0, 0]])
  })

  it('puts a new alert on the page when a make or an assignment comes to nothing again', async () => {
    const { send } = answering([listed(['alpha', null]), badName(), badName(), 'no answer', listed(['alpha', null]), 'no answer', listed(['alpha', null])])
    const model = createKeepers({ send, leave: vi.fn() })
    await model.load(first)
    const container = panelOf(model)
    const alerts: Element[] = []
    const alertOf = (selector: string) => {
      const found = container.querySelector(`${selector} ~ [role=alert]`)
      if (found === null) throw new Error(`no alert after ${selector}`)
      alerts.push(found)
    }
    for (let i = 0; i < 2; i += 1) {
      await act(async () => { await model.make('a b', null) })
      alertOf('form.keeper-form')
    }
    for (let i = 0; i < 2; i += 1) {
      await act(() => model.assign('alpha', 'rt_sonnet'))
      alertOf('form.check')
    }
    expect([alerts[0] === alerts[1], alerts[2] === alerts[3]]).toEqual([false, false])
  })

  it('puts the focus on the heading of the panel when a retry that read takes its button away', async () => {
    const view = signal<ListView>({ kind: 'failed', forUser: 'usr_first', failure: { problem: { kind: 'unreachable' }, attempts: 1 }, next: 'idle' })
    const model = { ...showing(), view }
    const container = panelOf(model)
    container.querySelector<HTMLButtonElement>('section button')?.focus()
    await act(() => { view.value = keepersList(alpha) })
    expect([document.activeElement?.id, document.activeElement?.getAttribute('tabindex')]).toEqual(['keepers-heading', '-1'])
  })

  it('makes a Keeper of the name typed and the model picked, or with none', () => {
    const model = showing()
    const container = panelOf(model)
    const name = container.querySelector<HTMLInputElement>('#keeper-name')
    const select = container.querySelector<HTMLSelectElement>('#keeper-new-runtime')
    const form = container.querySelector('form.keeper-form')
    if (name === null || select === null || form === null) throw new Error('no form of a new Keeper')
    fireEvent.input(name, { target: { value: 'beta' } })
    fireEvent.submit(form)
    fireEvent.change(select, { target: { value: '' } })
    fireEvent.submit(form)
    expect(vi.mocked(model.make).mock.calls).toEqual([['beta', 'rt_sonnet'], ['beta', null]])
  })

  it('sends nothing more while a request runs', () => {
    const model = showing({ making: { kind: 'sending', name: 'beta' }, assigning: [['alpha', { kind: 'sending', runtimeId: 'rt_sonnet' }]] })
    const container = panelOf(model)
    for (const form of container.querySelectorAll('form')) fireEvent.submit(form)
    expect([model.make, model.assign].map((one) => vi.mocked(one).mock.calls.length)).toEqual([0, 0])
  })

  const nameOf = (element: Element | null): string =>
    (element?.getAttribute('aria-labelledby') ?? '').split(' ').map((id) => document.getElementById(id)?.textContent?.trim() ?? '?').join(' ')

  it('opens the conversation of the Keeper of a card from the card', () => {
    const model = showing({ view: keepersList(alpha, { id: 'beta', runtimeId: null }) })
    const button = panelOf(model).querySelector<HTMLButtonElement>('[data-home="keeper-title-beta"] button[aria-expanded]')
    if (button !== null) fireEvent.click(button)
    expect(vi.mocked(model.talking.open).mock.calls).toEqual([['beta']])
  })

  it('names the field and the buttons of each card with the card', () => {
    const talk: TalkView = { kind: 'failed', keeperId: 'alpha', failure: { problem: { kind: 'unreachable' }, attempts: 1 }, next: 'idle' }
    const container = panelOf(showing({ view: keepersList({ id: 'alpha', runtimeId: null }, { id: 'beta', runtimeId: null }), talk }))
    const names = [...container.querySelectorAll('.row select, .row button')].map(nameOf)
    expect(new Set(names).size).toBe(names.length)
    expect(names.every((one) => !one.includes('?'))).toBe(true)
  })

  it('gives each element its own id, whatever the names of the Keepers', async () => {
    const names = ['x', 'label-x', 'field-x', 'button-x', 'title-x', 'open-x', 'talk-x', 'said-x', 'new-title', 'name']
    const conversation = { id: 'cv_1', turns: [], earlier: 0 }
    const container = panelOf(showing({ view: keepersList(...names.map((id) => ({ id, runtimeId: null }))), talk: { kind: 'read', keeperId: 'x', conversation } }))
    const ids = [...container.querySelectorAll('[id]')].map((one) => one.id)
    expect(ids.length - new Set(ids).size).toBe(0)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('clears the name once the Keeper is made, and puts the focus on the name when nothing was sent', async () => {
    const madeModel = createKeepers({ send: answering([listed(), madeAnswer('beta')]).send, leave: vi.fn() })
    await madeModel.load(first)
    const container = panelOf(madeModel, readPanel(noRuntimes))
    const name = container.querySelector<HTMLInputElement>('#keeper-name')
    const form = container.querySelector('form.keeper-form')
    if (name === null || form === null) throw new Error('no form of a new Keeper')
    name.value = 'beta'
    await act(async () => { fireEvent.submit(form); await Promise.resolve() })
    await vi.waitFor(() => { expect(madeModel.making.value.kind).toBe('made') })
    await vi.waitFor(() => { expect(name.value).toBe('') })
    const button = container.querySelector<HTMLButtonElement>('form.keeper-form button')
    button?.focus()
    name.value = 'beta'
    await act(async () => { fireEvent.submit(form); await Promise.resolve() })
    await vi.waitFor(() => { expect(document.activeElement).toBe(name) })
    expect(name.value).toBe('beta')
  })

  it.each([
    ['the field of the second card', '#keeper-button-beta', 'keeper-title-beta'],
    ['the model of a new Keeper', '#keeper-new-runtime', 'keeper-new-title'],
    ['an element outside the panel', '#elsewhere', 'elsewhere'],
  ])('puts the focus where it belongs when a reading takes the model fields away from %s', async (_name, focusedBefore, focusedAfter) => {
    const view = signal<PanelView>(readPanel())
    const subscriptions = { ...subscriptionsShowing(readPanel()), view }
    const model = showing({ view: keepersList(alpha, { id: 'beta', runtimeId: null }) })
    const container = render(html`<main><button id="elsewhere" type="button">다른 곳</button><${KeepersPanel} model=${model} subscriptions=${subscriptions} /></main>`).container
    container.querySelector<HTMLElement>(focusedBefore)?.focus()
    await act(() => { view.value = readPanel(noRuntimes) })
    const target = document.getElementById(focusedAfter)
    expect([container.querySelectorAll('select').length, document.activeElement === target, target?.tagName === 'BUTTON' || target?.getAttribute('tabindex') === '-1'])
      .toEqual([0, true, true])
  })

  it('empties the form once the Keeper is made, while the model picked is still being given', async () => {
    const wait = later()
    const model = createKeepers({ send: answering([listed(), madeAnswer('beta'), wait.answer]).send, leave: vi.fn() })
    await model.load(first)
    const container = panelOf(model)
    const name = container.querySelector<HTMLInputElement>('#keeper-name')
    const form = container.querySelector('form.keeper-form')
    if (name === null || form === null) throw new Error('no form of a new Keeper')
    name.value = 'beta'
    await act(async () => { fireEvent.submit(form); await Promise.resolve() })
    await vi.waitFor(() => { expect(name.value).toBe('') })
    expect(model.assigning.value.get('beta')?.kind).toBe('sending')
    wait.give(assignedAnswer('beta', 'rt_sonnet'))
    await vi.waitFor(() => { expect(model.assigning.value.get('beta')?.kind).toBe('done') })
  })
})
