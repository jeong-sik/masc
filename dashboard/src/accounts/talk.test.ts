// @vitest-environment happy-dom
//
// The conversation of a Keeper: what the server's answers read as, what a
// reading, a message and a new conversation send, how the state moves, and
// the place of the conversation in a card in each step. What a step says and where it puts things is not
// checked here: that is read in a browser.
import { afterEach, describe, expect, it, vi } from 'vitest'
import { signal } from '@preact/signals'
import { act, cleanup, fireEvent, render } from '@testing-library/preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { slowAfterMs } from './notes'
import { createTalk } from './talk'
import type { Act, TalkModel, TalkView } from './talk'
import { TalkPart } from './talk-area'
import { refusalOf } from './talk-say'
import { conversationOf, conversationPath, messageLimitBytes, readAnswered, readConversation, readStarted, say, start, talkProblemOf, turnPath, unsendable } from './talk-wire'
import type { Conversation, Turn } from './talk-wire'
import { csrfHeader } from './wire'
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

const turnAnswer = (keeper: string, extra: Record<string, unknown> = { conversation_id: 'cv_1', continued: true }) =>
  ({ keeper_id: keeper, runtime_id: 'rt_1', model: 'claude-sonnet-5', text: '네', ...extra })

describe('sending a message and starting a conversation', () => {
  it('reads an answer the conversation recorded, and one it did not', () => {
    expect([readAnswered(turnAnswer('alpha'), 'alpha'), readAnswered(turnAnswer('alpha', {}), 'alpha')]).toEqual([
      { text: '네', model: 'claude-sonnet-5', recorded: true },
      { text: '네', model: 'claude-sonnet-5', recorded: false },
    ])
  })

  it.each([
    ['another Keeper', turnAnswer('beta')],
    ['no Runtime', { ...turnAnswer('alpha'), runtime_id: '' }],
    ['no model', { ...turnAnswer('alpha'), model: '' }],
    ['no text', { ...turnAnswer('alpha'), text: null }],
    ['a conversation and no word of whether it went on', turnAnswer('alpha', { conversation_id: 'cv_1' })],
    ['a word of whether it went on and no conversation', turnAnswer('alpha', { continued: false })],
  ])('refuses the answer of a turn with %s', (_name, answer) => {
    expect(readAnswered(answer, 'alpha')).toBeNull()
  })

  it('reads the conversation a start made, for the Keeper asked about only', () => {
    expect([readStarted({ keeper_id: 'alpha', conversation_id: 'cv_2' }, 'alpha'), readStarted({ keeper_id: 'beta', conversation_id: 'cv_2' }, 'alpha'), readStarted({ keeper_id: 'alpha', conversation_id: '' }, 'alpha')])
      .toEqual(['cv_2', null, null])
  })

  it('sends no message the server would refuse as blank or too long, by the rules of the server', () => {
    const hangul = '가'
    expect([
      unsendable(''),
      unsendable(' \t\n\r\f'),
      unsendable('\u00a0'),
      unsendable('a'.repeat(messageLimitBytes)),
      unsendable('a'.repeat(messageLimitBytes + 1)),
      unsendable(hangul.repeat(1365)),
      unsendable(hangul.repeat(1366)),
    ]).toEqual(['blank', 'blank', null, null, 'too_long', null, 'too_long'])
  })

  it('sends the message and the start with the token of the session and no other credential', async () => {
    const { send, sent } = answering([json(200, turnAnswer('alpha')), json(200, { keeper_id: 'alpha', conversation_id: 'cv_2' })])
    await say(send, 'token-1', 'alpha', '안녕')
    await start(send, 'token-1', 'alpha')
    expect(sent.map((one) => {
      const headers = new Headers(one.init.headers)
      return [one.path, one.init.method, one.init.credentials, headers.get(csrfHeader), headers.has('authorization'), JSON.parse(String(one.init.body))]
    })).toEqual([
      [turnPath, 'POST', 'same-origin', 'token-1', false, { keeper_id: 'alpha', message: '안녕' }],
      [conversationPath, 'POST', 'same-origin', 'token-1', false, { keeper_id: 'alpha' }],
    ])
  })

  it('waits for a turn as long as the server runs it', async () => {
    vi.useFakeTimers()
    let answer: (response: Response) => void = () => undefined
    const send: Send = (_path, init) => new Promise((resolve) => {
      expect(init.signal ?? null).toBe(null)
      answer = resolve
    })
    const run = say(send, 'token-1', 'alpha', '안녕')
    await vi.advanceTimersByTimeAsync(10 * 60_000)
    answer(json(200, { keeper_id: 'alpha', runtime_id: 'pa_x.gpt-5.5', model: 'gpt-5.5', text: '네' }))
    expect(await run).toEqual({ ok: true, value: { text: '네', model: 'gpt-5.5', recorded: false } })
  })
})

/** What the page that holds a conversation gives it: a way to the sign-in
    page that marks the session ended for the whole page, as keepers.ts does. */
const page = () => {
  let gone = false
  return { leave: vi.fn(() => { gone = true }), left: () => gone, token: () => 'token-1' }
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
    const model = createTalk({ send, leave: vi.fn(), left: () => true, token: () => 'token-1' })
    await model.open('alpha')
    expect([model.view.value, sent.length]).toEqual([{ kind: 'closed' }, 0])
  })

  it('takes no answer that comes after another request of the page found that the session ended', async () => {
    const wait = later()
    let gone = false
    const model = createTalk({ send: answering([wait.answer]).send, leave: vi.fn(), left: () => gone, token: () => 'token-1' })
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

/** A conversation of alpha read, with the answers after it scripted. */
async function readFirst(answers: readonly Scripted[], token: string | null = 'token-1') {
  const { send, sent } = answering([conversationAnswer('alpha'), ...answers])
  const way = page()
  const model = createTalk({ send, leave: way.leave, left: way.left, token: () => token })
  await model.open('alpha')
  return { model, sent, way }
}
const posted = (sent: readonly Sent[]) => sent.filter((one) => one.init.method === 'POST').map((one) => one.path)
const reads = (sent: readonly Sent[]) => sent.filter((one) => one.init.method === 'GET').length
/** Waits until the conversation is read again after a request: its
    answer is taken from the script when it is sent. */
const settled = async (model: TalkModel, sent: readonly Sent[], gets: number) => {
  await vi.waitFor(() => { expect([reads(sent), model.view.value.kind]).toEqual([gets, 'read']) })
}

describe('a message and a new conversation of the Keeper', () => {
  it('sends the message, says it waits, takes the answer, and reads the conversation again', async () => {
    const wait = later()
    const { model, sent } = await readFirst([wait.answer, conversationAnswer('alpha', ['cv_1'], [answered, answered])])
    const run = model.say('안녕')
    const during = model.act.value
    wait.give(json(200, turnAnswer('alpha')))
    expect([during, await run]).toEqual([{ kind: 'sending', message: '안녕' }, { kind: 'answered', answer: { text: '네', model: 'claude-sonnet-5', recorded: true } }])
    await vi.waitFor(() => { expect([reads(sent), readOf(model)?.turns.length]).toEqual([2, 2]) })
  })

  it('reads a refusal by its code, counts refusals in a row, and reads the conversation again after each', async () => {
    const { model, sent } = await readFirst([refusedAnswer(429, 'no_quota'), conversationAnswer('alpha'), refusedAnswer(409, 'account_call_running'), conversationAnswer('alpha')])
    await model.say('안녕')
    await settled(model, sent, 2)
    const second = await model.say('안녕')
    await settled(model, sent, 3)
    expect(second).toEqual({ kind: 'refused', step: 'say', problem: { kind: 'refused', status: 409, code: 'account_call_running', reason: 'A sentence of the server.' }, attempts: 2 })
  })

  it('does not know what came of a message with no answer, or with a failure from in front of the server', async () => {
    const { model, sent } = await readFirst(['no answer', conversationAnswer('alpha'), json(502, { error: 'bad gateway' }), conversationAnswer('alpha'), json(403, { error: 'origin' }), conversationAnswer('alpha')])
    const kinds = []
    for (let n = 0; n < 3; n += 1) {
      kinds.push((await model.say('안녕'))?.kind)
      await settled(model, sent, n + 2)
    }
    expect(kinds).toEqual(['unknown', 'unknown', 'refused'])
  })

  it('sends nothing the server would refuse, and counts it in a row', async () => {
    const { model, sent } = await readFirst([])
    const outcomes = [await model.say(' \n'), await model.say('a'.repeat(messageLimitBytes + 1))]
    expect([outcomes, posted(sent)]).toEqual([[{ kind: 'not_sent', why: 'blank', attempts: 1 }, { kind: 'not_sent', why: 'too_long', attempts: 2 }], []])
  })

  it('sends one request at a time, and nothing before the conversation is read or without a token', async () => {
    const wait = later()
    const { model, sent } = await readFirst([wait.answer])
    const run = model.say('하나')
    expect([await model.say('둘'), posted(sent)]).toEqual([null, [turnPath]])
    await model.start()
    expect(posted(sent)).toEqual([turnPath])
    model.close()
    wait.give(json(200, turnAnswer('alpha')))
    expect([await run, model.act.value]).toEqual([null, { kind: 'idle' }])
    const reading = await readFirst([], null)
    expect([await reading.model.say('안녕'), posted(reading.sent)]).toEqual([null, []])
  })

  it('takes no answer of a message after another conversation was opened, and reads nothing for it', async () => {
    const wait = later()
    const { model, sent } = await readFirst([wait.answer, conversationAnswer('beta', ['cv_9'])])
    const run = model.say('안녕')
    await model.open('beta')
    wait.give(json(200, turnAnswer('alpha')))
    expect([await run, model.act.value, reads(sent)]).toEqual([null, { kind: 'idle' }, 2])
  })

  it('leaves for the sign-in page once when a message finds that the session ended', async () => {
    const { model, sent, way } = await readFirst([noSession()])
    expect([await model.say('안녕'), way.leave.mock.calls.length, reads(sent)]).toEqual([{ kind: 'leaving' }, 1, 1])
    expect(await model.say('안녕')).toBeNull()
  })

  it('starts a new conversation and reads it, also when the conversation could not be read', async () => {
    const { send, sent } = answering([refusedAnswer(503, 'conversation_row_half_written'), json(200, { keeper_id: 'alpha', conversation_id: 'cv_2' }), conversationAnswer('alpha', ['cv_1', 'cv_2'], [])])
    const model = createTalk({ send, ...page() })
    await model.open('alpha')
    await model.start()
    await settled(model, sent, 2)
    expect([model.act.value, readOf(model)?.earlier]).toEqual([{ kind: 'started' }, 1])
  })

  it('shows what a message came to only once the conversation was read again, and sends nothing meanwhile', async () => {
    const reread = later()
    const { model, sent } = await readFirst([json(200, turnAnswer('alpha')), reread.answer])
    const run = model.say('안녕')
    await vi.waitFor(() => { expect(reads(sent)).toBe(2) })
    const during = model.act.value.kind
    const second = await model.say('또')
    reread.give(conversationAnswer('alpha', ['cv_1'], [answered, answered]))
    expect([during, second, (await run)?.kind, posted(sent)]).toEqual(['sending', null, 'answered', [turnPath]])
  })

  it('counts on a reading that fails again after a request, so the same failure is announced again', async () => {
    const { send } = answering([refusedAnswer(503, 'conversation_record_unavailable'), refusedAnswer(409, 'account_call_running'), refusedAnswer(503, 'conversation_record_unavailable')])
    const model = createTalk({ send, ...page() })
    await model.open('alpha')
    await model.start()
    const now = model.view.value
    expect([model.act.value.kind, now.kind === 'failed' ? now.failure.attempts : null]).toEqual(['refused', 2])
  })

  it('counts the failures of a message and of a start apart', async () => {
    const { model } = await readFirst([
      refusedAnswer(409, 'account_call_running'), conversationAnswer('alpha'),
      refusedAnswer(409, 'account_call_running'), conversationAnswer('alpha'),
      refusedAnswer(429, 'no_quota'), conversationAnswer('alpha'),
    ])
    await model.say(' ')
    const after = []
    for (const step of [() => model.start(), () => model.start(), () => model.say('안녕')]) {
      await step()
      after.push(model.act.value)
    }
    expect(after.map((one) => (one.kind === 'refused' ? one.attempts : null))).toEqual([1, 2, 1])
  })

  it('says nothing of a message whose conversation, read again, found that the session ended', async () => {
    const { model, way } = await readFirst([json(200, turnAnswer('alpha')), noSession()])
    expect([await model.say('안녕'), model.view.value.kind, way.leave.mock.calls.length]).toEqual([{ kind: 'idle' }, 'leaving', 1])
  })

  it('knows which refusals of a message come after the server took the message in', () => {
    const codes = ['not_signed_in', 'no_quota', 'silent', 'not_started', 'configuration_refused', 'no_answer', 'answer_unrecorded', 'message_blank', 'account_call_running', 'runtime_reassigned', 'conversation_record_unavailable'] as const
    expect(codes.map((code) => refusalOf(code)?.sent)).toEqual([true, true, true, true, true, true, true, false, false, false, false])
  })

  it('says a start was refused with the step it was', async () => {
    const { model, sent } = await readFirst([refusedAnswer(409, 'keeper_has_no_runtime'), conversationAnswer('alpha')])
    await model.start()
    await settled(model, sent, 2)
    const now = model.act.value
    expect(now.kind === 'refused' ? [now.step, now.problem.code] : null).toEqual(['start', 'keeper_has_no_runtime'])
  })
})

// ---- the place of the conversation in a card ----

const turn = (outcome: Turn['outcome']): Turn => ({ message: '긴 말\n두 줄', askedAtMs: 1_763_000_000_000, outcome })
const conversation = (turns: readonly Turn[], earlier = 0): Conversation => ({ id: 'cv_1', turns, earlier })
const showingTalk = (view: TalkView, act: Act = { kind: 'idle' }): TalkModel => ({
  view: signal(view),
  act: signal(act),
  open: vi.fn(() => Promise.resolve()),
  close: vi.fn(),
  retry: vi.fn(() => Promise.resolve()),
  say: vi.fn(() => Promise.resolve(null)),
  start: vi.fn(() => Promise.resolve()),
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

  it('has one line a screen reader reads out in the place of the conversation, which is on the page in every step, and one under the form when it is open', () => {
    const found = steps.map(([name, view]) => {
      const container = cardOf(showingTalk(view))
      const button = container.querySelector('button[aria-controls]')
      const place = container.querySelector(`#${button?.getAttribute('aria-controls') ?? ''}`)
      const lines = place?.querySelectorAll('[role=status]').length
      cleanup()
      return [name, lines]
    })
    expect(found).toEqual(steps.map(([name, view]) => [name, view.kind === 'closed' || view.keeperId !== 'alpha' ? 1 : 2]))
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
      const marked = cardOf(showingTalk(view)).querySelectorAll('#keeper-again-alpha[aria-disabled=true]').length
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
    expect(buttons).toHaveLength(4)
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

// ---- the form of a message ----

describe('the form of a message', () => {
  const read: TalkView = { kind: 'read', keeperId: 'alpha', conversation: conversation([]) }
  const failedRead: TalkView = { kind: 'failed', keeperId: 'alpha', failure: { problem: { kind: 'unreachable' }, attempts: 1 }, next: 'idle' }
  const noQuota = { kind: 'refused', status: 429, code: 'no_quota', reason: 'The subscription of this Runtime has no quota left.' } as const
  const internal = { kind: 'refused', status: 500, code: 'internal_error', reason: null } as const
  const steps: ReadonlyArray<readonly [string, TalkView, Act]> = [
    ['while the conversation is read', { kind: 'reading', keeperId: 'alpha', slow: true }, { kind: 'idle' }],
    ['when the conversation could not be read', failedRead, { kind: 'idle' }],
    ['before anything is sent', read, { kind: 'idle' }],
    ['while a message is sent', read, { kind: 'sending', message: '긴 말\n두 줄' }],
    ['while a conversation starts', read, { kind: 'starting' }],
    ['after an answer', read, { kind: 'answered', answer: { text: '네', model: 'claude-sonnet-5', recorded: true } }],
    ['after an answer the record does not keep', read, { kind: 'answered', answer: { text: '네', model: 'gpt-5.5', recorded: false } }],
    ['after a start', read, { kind: 'started' }],
    ['with a blank message', read, { kind: 'not_sent', why: 'blank', attempts: 1 }],
    ['with a refusal it has words for', read, { kind: 'refused', step: 'say', problem: noQuota, attempts: 2 }],
    ['with a refusal it has no words for', read, { kind: 'refused', step: 'start', problem: internal, attempts: 1 }],
    ['with a message whose end it does not know', read, { kind: 'unknown', step: 'say', problem: { kind: 'unreachable' }, attempts: 1 }],
    ['with a start whose end it does not know and a conversation not read again', failedRead, { kind: 'unknown', step: 'start', problem: { kind: 'unreadable' }, attempts: 1 }],
    ['while the browser leaves', read, { kind: 'leaving' }],
  ]
  const each = <T>(look: (container: Element) => T) => steps.map(([name, view, now]) => {
    const found = look(cardOf(showingTalk(view, now)))
    cleanup()
    return [name, found]
  })
  const named = (values: Readonly<Record<string, unknown>>, otherwise: unknown) => steps.map(([name]) => [name, name in values ? values[name] : otherwise])

  it.each(steps)('passes the accessibility rules %s', async (_name, view, now) => {
    expect(await axe(cardOf(showingTalk(view, now)))).toHaveNoViolations()
  })

  it('says each request that came to nothing where a screen reader announces it', () => {
    expect(each((container) => container.querySelectorAll('form ~ [role=alert]').length)).toEqual(named({
      'with a blank message': 1,
      'with a refusal it has words for': 1,
      'with a refusal it has no words for': 1,
      'with a message whose end it does not know': 1,
      'with a start whose end it does not know and a conversation not read again': 1,
    }, 0))
  })

  it('marks what cannot be pressed yet: a message before the conversation is read, either while a request runs', () => {
    const marked = (container: Element) => ['#talk-send', '#talk-start'].map((id) => container.querySelector(id)?.getAttribute('aria-disabled'))
    expect(each(marked)).toEqual(named({
      'while the conversation is read': ['true', 'true'],
      'when the conversation could not be read': ['true', 'false'],
      'with a start whose end it does not know and a conversation not read again': ['true', 'false'],
      'while a message is sent': ['true', 'true'],
      'while a conversation starts': ['true', 'true'],
      'while the browser leaves': ['true', 'true'],
    }, ['false', 'false']))
  })

  it('shows a message while it is sent, and an answer only when the record does not keep it', () => {
    expect(each((container) => container.querySelectorAll('.talk > .turn-part').length)).toEqual(named({
      'while a message is sent': 1,
      'after an answer the record does not keep': 1,
    }, 0))
  })

  it('says what the server meant by a code it has words for', () => {
    const container = cardOf(showingTalk(read, { kind: 'refused', step: 'say', problem: noQuota, attempts: 1 }))
    expect(container.querySelector('form ~ [role=alert]')?.textContent).toContain(refusalOf('no_quota')?.words)
  })

  it('keeps the field from being changed while a request runs', () => {
    expect(each((container) => container.querySelector('textarea')?.readOnly)).toEqual(named({
      'while a message is sent': true,
      'while a conversation starts': true,
      'while the browser leaves': true,
    }, false))
  })

  it('keeps the line a screen reader reads out under the form as one element through every request', async () => {
    const now = signal<Act>({ kind: 'idle' })
    const container = cardOf({ ...showingTalk(read), act: now })
    const line = () => container.querySelector('form ~ [role=status]')
    const first = line()
    const same = []
    for (const next of steps.map(([, , one]) => one)) {
      await act(() => { now.value = next })
      same.push(line() === first)
    }
    expect([first !== null, same.every(Boolean)]).toEqual([true, true])
  })

  it('puts a new alert on the page when a request fails again', async () => {
    const now = signal<Act>({ kind: 'refused', step: 'say', problem: noQuota, attempts: 1 })
    const container = cardOf({ ...showingTalk(read), act: now })
    const before = container.querySelector('form ~ [role=alert]')
    await act(() => { now.value = { kind: 'refused', step: 'say', problem: noQuota, attempts: 2 } })
    expect(container.querySelector('form ~ [role=alert]') === before).toBe(false)
  })

  it('sends what is typed, on the button and on Ctrl+Enter, and empties the field once the Keeper answered', async () => {
    const talk = showingTalk(read)
    vi.mocked(talk.say).mockResolvedValue({ kind: 'answered', answer: { text: '네', model: 'claude-sonnet-5', recorded: true } })
    const container = cardOf(talk)
    const field = container.querySelector('textarea')
    if (field === null) throw new Error('no field')
    fireEvent.input(field, { target: { value: '안녕\n두 줄' } })
    fireEvent.keyDown(field, { key: 'Enter', ctrlKey: true })
    await vi.waitFor(() => { expect(field.value).toBe('') })
    fireEvent.input(field, { target: { value: '또' } })
    fireEvent.keyDown(field, { key: 'Enter' })
    const button = container.querySelector<HTMLButtonElement>('#talk-send')
    if (button !== null) fireEvent.click(button)
    await vi.waitFor(() => { expect(vi.mocked(talk.say).mock.calls).toEqual([['안녕\n두 줄'], ['또']]) })
  })

  it('keeps a message the server refused, and puts the focus on the field when nothing was sent', async () => {
    const refusing = showingTalk(read)
    vi.mocked(refusing.say).mockResolvedValue({ kind: 'refused', step: 'say', problem: noQuota, attempts: 1 })
    const field = cardOf(refusing).querySelector('textarea')
    fireEvent.input(field as HTMLTextAreaElement, { target: { value: '안녕' } })
    fireEvent.submit(field?.form as HTMLFormElement)
    await vi.waitFor(() => { expect(refusing.say).toHaveBeenCalled() })
    const kept = field?.value
    cleanup()
    const blank = showingTalk(read)
    vi.mocked(blank.say).mockResolvedValue({ kind: 'not_sent', why: 'blank', attempts: 1 })
    const empty = cardOf(blank).querySelector('textarea')
    fireEvent.submit(empty?.form as HTMLFormElement)
    await vi.waitFor(() => { expect(document.activeElement).toBe(empty) })
    expect(kept).toBe('안녕')
  })

  it('leaves an Enter that ends the composing of a syllable to it', () => {
    const talk = showingTalk(read)
    const field = cardOf(talk).querySelector('textarea')
    fireEvent.keyDown(field as HTMLTextAreaElement, { key: 'Enter', ctrlKey: true, isComposing: true })
    expect(vi.mocked(talk.say).mock.calls.length).toBe(0)
  })

  it('asks for nothing on a press of a button that is marked', () => {
    const talk = showingTalk({ kind: 'reading', keeperId: 'alpha', slow: false })
    const container = cardOf(talk)
    for (const id of ['#talk-send', '#talk-start']) {
      const button = container.querySelector<HTMLButtonElement>(id)
      if (button !== null) fireEvent.click(button)
    }
    expect([vi.mocked(talk.say).mock.calls.length, vi.mocked(talk.start).mock.calls.length]).toEqual([0, 0])
  })

  it('starts a new conversation on a press', () => {
    const talk = showingTalk(failedRead)
    const button = cardOf(talk).querySelector<HTMLButtonElement>('#talk-start')
    if (button !== null) fireEvent.click(button)
    expect(vi.mocked(talk.start).mock.calls.length).toBe(1)
  })
})
