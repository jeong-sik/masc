// @vitest-environment happy-dom
//
// The conversation of a Keeper: what the server's answers read as, what a
// reading sends, how the state moves, and the place of the conversation in a
// card in each step. What a step says and where it puts things is not
// checked here: that is read in a browser.
import { afterEach, describe, expect, it, vi } from 'vitest'
import { signal } from '@preact/signals'
import { act, cleanup, fireEvent, render } from '@testing-library/preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { slowAfterMs } from './notes'
import { createTalk } from './talk'
import type { TalkModel, TalkView } from './talk'
import { TalkPart } from './talk-area'
import { conversationOf, conversationPath, readConversation, talkProblemOf } from './talk-wire'
import type { Conversation, Turn } from './talk-wire'
import type { Send } from './wire'

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

const listedOne = (id: string, at = 1_000) => ({ conversation_id: id, provider_account_id: 'pa_1', started_at_ms: at })
const asked = { message: '안녕', asked_at_ms: 2_000 }
const answered = { ...asked, outcome: 'answered', text: '안녕하세요', model: 'claude-sonnet-5', answered_at_ms: 3_000 }
const failed = { ...asked, outcome: 'failed', failure: 'no_quota', failed_at_ms: 3_000, model_may_have_read: true }
const unrecorded = { ...asked, outcome: 'unrecorded', model_may_have_read: true }

/** The answer of a reading of `keeper` whose current conversation is the last listed. */
const body = (keeper: string, ids: readonly string[], turns: readonly unknown[]) => {
  const current = ids.at(-1) ?? null
  return { keeper_id: keeper, current_conversation_id: current, conversations: ids.map((id) => listedOne(id)), conversation_id: current, turns }
}
const conversationAnswer = (keeper: string, ids: readonly string[] = ['cv_1'], turns: readonly unknown[] = [answered]): Response =>
  json(200, body(keeper, ids, turns))
const refusedAnswer = (status: number, code: string): Response => json(status, { error: 'A sentence of the server.', code })
const noSession = (): Response => json(401, { error: 'no session cookie came with the request' })

afterEach(() => {
  cleanup()
  vi.useRealTimers()
  vi.restoreAllMocks()
})

describe('reading the answers about a conversation', () => {
  it('reads a Keeper that has had no conversation', () => {
    expect(readConversation(body('alpha', [], []), 'alpha')).toEqual({ id: null, turns: [], earlier: 0 })
  })

  it('reads the turns of the current conversation in each outcome, and counts the conversations before it', () => {
    expect(readConversation(body('alpha', ['cv_1', 'cv_2'], [answered, failed, unrecorded]), 'alpha')).toEqual({
      id: 'cv_2',
      earlier: 1,
      turns: [
        { message: '안녕', askedAtMs: 2_000, outcome: { kind: 'answered', text: '안녕하세요', model: 'claude-sonnet-5', atMs: 3_000 } },
        { message: '안녕', askedAtMs: 2_000, outcome: { kind: 'failed', failure: 'no_quota', atMs: 3_000, modelMayHaveRead: true } },
        { message: '안녕', askedAtMs: 2_000, outcome: { kind: 'unrecorded', modelMayHaveRead: true } },
      ],
    })
  })

  it('keeps a failure this console does not know apart', () => {
    const read = readConversation(body('alpha', ['cv_1'], [{ ...failed, failure: 'out_of_coffee' }]), 'alpha')
    expect(read?.turns[0]?.outcome).toEqual({ kind: 'failed', failure: 'unrecognised', atMs: 3_000, modelMayHaveRead: true })
  })

  it.each([
    ['another Keeper', { ...body('beta', ['cv_1'], []) }],
    ['a conversation shown that is not the current one', { ...body('alpha', ['cv_1', 'cv_2'], []), conversation_id: 'cv_1' }],
    ['a current conversation that is not the last listed', { ...body('alpha', ['cv_1', 'cv_2'], []), current_conversation_id: 'cv_1', conversation_id: 'cv_1' }],
    ['the last conversation shown when another is the current one', { ...body('alpha', ['cv_1', 'cv_2'], []), current_conversation_id: 'cv_1' }],
    ['no conversation and a turn', body('alpha', [], [answered])],
    ['no conversation and one listed', { ...body('alpha', ['cv_1'], []), current_conversation_id: null, conversation_id: null }],
    ['a conversation with an empty id', body('alpha', [''], [])],
    ['a conversation with no account', { ...body('alpha', ['cv_1'], []), conversations: [{ conversation_id: 'cv_1', started_at_ms: 1 }] }],
    ['no list of conversations', { ...body('alpha', ['cv_1'], []), conversations: null }],
    ['no list of turns', { ...body('alpha', ['cv_1'], []), turns: {} }],
    ['an outcome it does not know', body('alpha', ['cv_1'], [{ ...asked, outcome: 'pending' }])],
    ['an answer with no model', body('alpha', ['cv_1'], [{ ...answered, model: null }])],
    ['a time before 1970', body('alpha', ['cv_1'], [{ ...answered, asked_at_ms: -1 }])],
    ['a time that is not a whole number', body('alpha', ['cv_1'], [{ ...answered, answered_at_ms: 1.5 }])],
    ['a time no date holds', body('alpha', ['cv_1'], [{ ...answered, asked_at_ms: 8_640_000_000_000_001 }])],
    ['a conversation listed twice', body('alpha', ['cv_1', 'cv_1'], [])],
    ['a failure that is not a word', body('alpha', ['cv_1'], [{ ...failed, failure: 3 }])],
    ['a failure that does not say whether the Keeper may have read it', body('alpha', ['cv_1'], [{ ...failed, model_may_have_read: 'yes' }])],
    ['a turn whose end was not recorded that does not say it', body('alpha', ['cv_1'], [{ ...unrecorded, model_may_have_read: undefined }])],
  ])('refuses an answer with %s', (_name, answer) => {
    expect(readConversation(answer, 'alpha')).toBeNull()
  })

  it('reads a refusal by its code, keeps a code it does not know apart, and leaves on a missing session', async () => {
    expect(await Promise.all([
      talkProblemOf(refusedAnswer(503, 'conversation_record_unavailable')),
      talkProblemOf(refusedAnswer(500, 'out_of_coffee')),
      talkProblemOf(new Response('', { status: 502 })),
      talkProblemOf(noSession()),
    ])).toEqual([
      { kind: 'refused', status: 503, code: 'conversation_record_unavailable', reason: 'A sentence of the server.' },
      { kind: 'refused', status: 500, code: 'unrecognised', reason: 'A sentence of the server.' },
      { kind: 'refused', status: 502, code: 'unrecognised', reason: null },
      { kind: 'signed_out' },
    ])
  })

  it('asks for the current conversation of the Keeper, with the cookie of the session and no other credential', async () => {
    const { send, sent } = answering([conversationAnswer('alpha')])
    await conversationOf(send, 'alpha')
    const headers = new Headers(sent[0]?.init.headers)
    expect([sent[0]?.path, sent[0]?.init.method, sent[0]?.init.credentials, headers.has('authorization')])
      .toEqual([`${conversationPath}?keeper_id=alpha`, 'GET', 'same-origin', false])
  })
})

/** What the page that holds a conversation gives it: a way to the sign-in
    page that marks the session ended for the whole page, as keepers.ts does. */
const page = () => {
  let gone = false
  return { leave: vi.fn(() => { gone = true }), left: () => gone }
}

const readOf = (model: TalkModel): Conversation | null => {
  const now = model.view.value
  return now.kind === 'read' ? now.conversation : null
}

describe('the conversation of a Keeper', () => {
  it('reads the conversation, says when it is slow, and reads again after a failure', async () => {
    vi.useFakeTimers()
    const wait = later()
    const { send } = answering([wait.answer, conversationAnswer('alpha')])
    const model = createTalk({ send, ...page() })
    const run = model.open('alpha')
    await vi.advanceTimersByTimeAsync(1000)
    expect(model.view.value).toEqual({ kind: 'reading', keeperId: 'alpha', slow: true })
    wait.give(refusedAnswer(503, 'conversation_record_unavailable'))
    await run
    expect(model.view.value).toEqual({
      kind: 'failed',
      keeperId: 'alpha',
      failure: { problem: { kind: 'refused', status: 503, code: 'conversation_record_unavailable', reason: 'A sentence of the server.' }, attempts: 1 },
      next: 'idle',
    })
    await model.retry()
    expect(readOf(model)?.id).toBe('cv_1')
  })

  it('says it is slow only once the reading of the Keeper opened last has lasted long enough', async () => {
    vi.useFakeTimers()
    const { send } = answering([later().answer, later().answer])
    const model = createTalk({ send, ...page() })
    void model.open('alpha')
    await vi.advanceTimersByTimeAsync(slowAfterMs - 100)
    void model.open('beta')
    await vi.advanceTimersByTimeAsync(150)
    const early = model.view.value
    await vi.advanceTimersByTimeAsync(slowAfterMs)
    expect([early, model.view.value]).toEqual([
      { kind: 'reading', keeperId: 'beta', slow: false },
      { kind: 'reading', keeperId: 'beta', slow: true },
    ])
  })

  it('counts the failures in a row, and reads once while a retry runs', async () => {
    const wait = later()
    const { send, sent } = answering(['no answer', wait.answer])
    const model = createTalk({ send, ...page() })
    await model.open('alpha')
    const run = model.retry()
    await model.retry()
    wait.give(json(200, { nothing: true }))
    await run
    const now = model.view.value
    expect([now.kind === 'failed' ? [now.failure.problem.kind, now.failure.attempts] : null, sent.length]).toEqual([['unreadable', 2], 2])
  })

  it('does nothing on a retry when nothing failed', async () => {
    const { send, sent } = answering([conversationAnswer('alpha')])
    const model = createTalk({ send, ...page() })
    await model.retry()
    await model.open('alpha')
    await model.retry()
    expect([sent.length, model.view.value.kind]).toEqual([1, 'read'])
  })

  it('joins the reading of the Keeper whose conversation is being read', async () => {
    const wait = later()
    const { send, sent } = answering([wait.answer])
    const model = createTalk({ send, ...page() })
    const run = model.open('alpha')
    const again = model.open('alpha')
    wait.give(conversationAnswer('alpha'))
    await Promise.all([run, again])
    expect([sent.length, readOf(model)?.id]).toEqual([1, 'cv_1'])
  })

  it('shows the conversation of the Keeper opened last, whatever answer comes last', async () => {
    const wait = later()
    const { send } = answering([wait.answer, conversationAnswer('beta', ['cv_9'])])
    const model = createTalk({ send, ...page() })
    const run = model.open('alpha')
    await model.open('beta')
    wait.give(conversationAnswer('alpha'))
    await run
    const now = model.view.value
    expect(now.kind === 'read' ? [now.keeperId, now.conversation.id] : null).toEqual(['beta', 'cv_9'])
  })

  it('stays closed when the answer of a reading comes after it was closed', async () => {
    const wait = later()
    const { send } = answering([wait.answer])
    const model = createTalk({ send, ...page() })
    const run = model.open('alpha')
    model.close()
    wait.give(conversationAnswer('alpha'))
    await run
    expect(model.view.value).toEqual({ kind: 'closed' })
  })

  it('leaves for the sign-in page once when the reading finds that the session ended, and reads and closes nothing more', async () => {
    const way = page()
    const { send, sent } = answering([noSession()])
    const model = createTalk({ send, ...way })
    await model.open('alpha')
    await model.open('beta')
    model.close()
    expect([model.view.value, way.leave.mock.calls.length, sent.length]).toEqual([{ kind: 'leaving', keeperId: 'alpha' }, 1, 1])
  })

  it('reads nothing once another request of the page found that the session ended', async () => {
    const { send, sent } = answering([])
    const model = createTalk({ send, leave: vi.fn(), left: () => true })
    await model.open('alpha')
    expect([model.view.value, sent.length]).toEqual([{ kind: 'closed' }, 0])
  })

  it('takes no answer that comes after another request of the page found that the session ended', async () => {
    const wait = later()
    let gone = false
    const model = createTalk({ send: answering([wait.answer]).send, leave: vi.fn(), left: () => gone })
    const run = model.open('alpha')
    gone = true
    wait.give(conversationAnswer('alpha'))
    await run
    expect(model.view.value).toEqual({ kind: 'reading', keeperId: 'alpha', slow: false })
  })

  it('keeps the retry button on the page while the browser leaves', async () => {
    const way = page()
    const model = createTalk({ send: answering(['no answer', noSession()]).send, ...way })
    await model.open('alpha')
    await model.retry()
    const now = model.view.value
    expect([now.kind, now.kind === 'failed' ? now.next : null, way.leave.mock.calls.length]).toEqual(['failed', 'leaving', 1])
  })

  it('forgets the conversation on a reset, takes no answer that comes after, and reads again', async () => {
    const wait = later()
    const { send } = answering([wait.answer, conversationAnswer('beta', ['cv_9'])])
    const model = createTalk({ send, ...page() })
    const run = model.open('alpha')
    model.reset()
    wait.give(conversationAnswer('alpha'))
    await run
    expect(model.view.value).toEqual({ kind: 'closed' })
    await model.open('beta')
    expect(readOf(model)?.id).toBe('cv_9')
  })
})

// ---- the place of the conversation in a card ----

const turn = (outcome: Turn['outcome']): Turn => ({ message: '긴 말\n두 줄', askedAtMs: 1_763_000_000_000, outcome })
const conversation = (turns: readonly Turn[], earlier = 0): Conversation => ({ id: 'cv_1', turns, earlier })
const showingTalk = (view: TalkView): TalkModel => ({
  view: signal(view),
  open: vi.fn(() => Promise.resolve()),
  close: vi.fn(),
  retry: vi.fn(() => Promise.resolve()),
  reset: vi.fn(),
})
const cardOf = (talk: TalkModel) =>
  render(html`
    <main>
      <h1>내 계정</h1>
      <h2>Keeper</h2>
      <ul class="rows"><li class="row"><h3 id="keeper-title-alpha">alpha</h3><${TalkPart} keeperId="alpha" card="keeper-title-alpha" talk=${talk} /></li></ul>
    </main>
  `).container

describe('the conversation in a card', () => {
  const steps: ReadonlyArray<readonly [string, TalkView]> = [
    ['while it is closed', { kind: 'closed' }],
    ['while another Keeper\'s is open', { kind: 'read', keeperId: 'beta', conversation: conversation([]) }],
    ['while it is read', { kind: 'reading', keeperId: 'alpha', slow: true }],
    ['when it could not be read', { kind: 'failed', keeperId: 'alpha', failure: { problem: { kind: 'unreachable' }, attempts: 2 }, next: 'idle' }],
    ['when the record could not be read', {
      kind: 'failed',
      keeperId: 'alpha',
      failure: { problem: { kind: 'refused', status: 503, code: 'conversation_record_unavailable', reason: 'The record could not be read.' }, attempts: 1 },
      next: 'reading',
    }],
    ['with no turn', { kind: 'read', keeperId: 'alpha', conversation: conversation([]) }],
    ['with a turn in each outcome', {
      kind: 'read',
      keeperId: 'alpha',
      conversation: conversation([
        turn({ kind: 'answered', text: '답\n두 줄', model: 'claude-sonnet-5', atMs: 1_763_000_060_000 }),
        turn({ kind: 'failed', failure: 'silent', atMs: 1_763_000_120_000, modelMayHaveRead: true }),
        turn({ kind: 'failed', failure: 'unrecognised', atMs: 1_763_000_120_000, modelMayHaveRead: false }),
        turn({ kind: 'unrecorded', modelMayHaveRead: true }),
      ], 2),
    }],
    ['while the browser leaves', { kind: 'leaving', keeperId: 'alpha' }],
  ]

  it.each(steps)('passes the accessibility rules %s', async (_name, view) => {
    expect(await axe(cardOf(showingTalk(view)))).toHaveNoViolations()
  })

  it('has one line a screen reader reads out in the place of the conversation, which is on the page in every step', () => {
    const found = steps.map(([name, view]) => {
      const container = cardOf(showingTalk(view))
      const button = container.querySelector('button[aria-controls]')
      const place = container.querySelector(`#${button?.getAttribute('aria-controls') ?? ''}`)
      const lines = place?.querySelectorAll('[role=status]').length
      cleanup()
      return [name, lines]
    })
    expect(found).toEqual(steps.map(([name]) => [name, 1]))
  })

  it('says each reading that failed where a screen reader announces it', () => {
    const found = steps.map(([name, view]) => {
      const alerts = cardOf(showingTalk(view)).querySelectorAll('[role=alert]').length
      cleanup()
      return [name, alerts]
    })
    expect(found).toEqual(steps.map(([name]) => [name, name.includes('could not be read') ? 1 : 0]))
  })

  it('has words on the line a screen reader reads out while a reading waits, and while the browser leaves', () => {
    const found = steps.map(([name, view]) => {
      const words = cardOf(showingTalk(view)).querySelector('.talk [role=status]')?.textContent?.trim() ?? ''
      cleanup()
      return [name, words !== '']
    })
    const waiting = new Set(['while it is read', 'when the record could not be read', 'while the browser leaves', 'with no turn', 'with a turn in each outcome'])
    expect(found).toEqual(steps.map(([name]) => [name, waiting.has(name)]))
  })

  it('marks the retry button while it reads again', () => {
    const found = steps.map(([name, view]) => {
      const marked = cardOf(showingTalk(view)).querySelectorAll('button[aria-disabled=true]').length
      cleanup()
      return [name, marked]
    })
    expect(found).toEqual(steps.map(([name]) => [name, name === 'when the record could not be read' ? 1 : 0]))
  })

  it('says whether it is open on its button, and opens or closes on a press', () => {
    const closed = showingTalk({ kind: 'closed' })
    const opened = showingTalk({ kind: 'reading', keeperId: 'alpha', slow: false })
    const other = showingTalk({ kind: 'read', keeperId: 'beta', conversation: conversation([]) })
    const pressed = [closed, opened, other].map((talk) => {
      const button = cardOf(talk).querySelector<HTMLButtonElement>('button[aria-expanded]')
      const expanded = button?.getAttribute('aria-expanded')
      if (button !== null && button !== undefined) fireEvent.click(button)
      cleanup()
      return expanded
    })
    expect([pressed, vi.mocked(closed.open).mock.calls, vi.mocked(opened.close).mock.calls.length, vi.mocked(other.open).mock.calls])
      .toEqual([['false', 'true', 'false'], [['alpha']], 1, [['alpha']]])
  })

  it('reads again on a press of the retry button', () => {
    const talk = showingTalk({ kind: 'failed', keeperId: 'alpha', failure: { problem: { kind: 'unreachable' }, attempts: 1 }, next: 'idle' })
    const retry = cardOf(talk).querySelector<HTMLButtonElement>('.talk button')
    if (retry !== null) fireEvent.click(retry)
    expect([vi.mocked(talk.retry).mock.calls.length, vi.mocked(talk.open).mock.calls.length]).toEqual([1, 0])
  })

  it('names its buttons with the card', () => {
    const view: TalkView = { kind: 'failed', keeperId: 'alpha', failure: { problem: { kind: 'unreachable' }, attempts: 1 }, next: 'idle' }
    const buttons = [...cardOf(showingTalk(view)).querySelectorAll('button')]
    expect(buttons.map((one) => one.getAttribute('aria-labelledby'))).toEqual(buttons.map((one) => `${one.id} keeper-title-alpha`))
    expect(buttons).toHaveLength(2)
  })

  it('gives each time its moment in a form a machine reads', () => {
    const view: TalkView = { kind: 'read', keeperId: 'alpha', conversation: conversation([turn({ kind: 'unrecorded', modelMayHaveRead: true })]) }
    const times = [...cardOf(showingTalk(view)).querySelectorAll('time')].map((one) => one.getAttribute('datetime'))
    expect(times).toEqual([new Date(1_763_000_000_000).toISOString()])
  })

  it('keeps the line a screen reader reads out as one element through every step', async () => {
    const view = signal<TalkView>({ kind: 'closed' })
    const container = cardOf({ ...showingTalk({ kind: 'closed' }), view })
    const line = () => container.querySelector('.talk [role=status]')
    const first = line()
    const failure = { problem: { kind: 'unreachable' }, attempts: 1 } as const
    const same = []
    for (const next of [
      { kind: 'reading', keeperId: 'alpha', slow: true },
      { kind: 'failed', keeperId: 'alpha', failure, next: 'idle' },
      { kind: 'failed', keeperId: 'alpha', failure, next: 'reading' },
      { kind: 'read', keeperId: 'alpha', conversation: conversation([]) },
      { kind: 'closed' },
      { kind: 'leaving', keeperId: 'alpha' },
    ] satisfies TalkView[]) {
      await act(() => { view.value = next })
      same.push(line() === first)
    }
    expect([first !== null, ...same]).toEqual([true, true, true, true, true, true, true])
  })

  it('puts a new alert on the page when a reading fails again', async () => {
    const view = signal<TalkView>({ kind: 'failed', keeperId: 'alpha', failure: { problem: { kind: 'unreachable' }, attempts: 1 }, next: 'idle' })
    const container = cardOf({ ...showingTalk({ kind: 'closed' }), view })
    const before = container.querySelector('[role=alert]')
    await act(() => { view.value = { kind: 'failed', keeperId: 'alpha', failure: { problem: { kind: 'unreachable' }, attempts: 2 }, next: 'idle' } })
    expect(container.querySelector('[role=alert]') === before).toBe(false)
  })

  it('puts the focus on its button when a retry that read takes the retry button away', async () => {
    const view = signal<TalkView>({ kind: 'failed', keeperId: 'alpha', failure: { problem: { kind: 'unreachable' }, attempts: 1 }, next: 'idle' })
    const container = cardOf({ ...showingTalk({ kind: 'closed' }), view })
    container.querySelector<HTMLButtonElement>('.talk button')?.focus()
    await act(() => { view.value = { kind: 'read', keeperId: 'alpha', conversation: conversation([]) } })
    expect(document.activeElement?.getAttribute('aria-expanded')).toBe('true')
  })
})
