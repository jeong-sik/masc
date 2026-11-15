// The steps of connecting a subscription: which step each answer of the
// server leads to, and which requests each step sends.
import { afterEach, describe, expect, it, vi } from 'vitest'
import { createConnect, transcriptLimit } from './connect'
import type { ConnectModel, Input } from './connect'
import { loginPath } from './login'
import type { Send } from './wire'

const id = 'a'.repeat(64)
const frame = (event: string, data: unknown): string => `event: ${event}\r\ndata: ${JSON.stringify(data)}\r\n\r\n`
const receipt = (status: string, more: Readonly<Record<string, unknown>> = {}) =>
  ({ login_id: id, integration_id: 'claude_code', status, invocation_verified: false, ...more })
const started = frame('started', receipt('running'))
const linked = frame('complete', receipt('complete', { account: 'linked', authentication: 'login_completed' }))
/** The client took the last reply. */
const took = frame('input_ready', {})
const printed = (text: string): string => frame('output', { stream: 'terminal', text })
const stopped = (status: string): string => frame('error', { message: 'a sentence for the operator', ...receipt(status) })
const json = (status: number, body: unknown): Response =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } })
const accepted = (): Response => json(202, { accepted: true })
const noSession = (): Response => json(401, { error: 'no session' })

const input = `${loginPath}/${id}/input`
const cancelled = `${loginPath}/${id}/cancel`
const standing = `${loginPath}/${id}`

/** A stream the test writes to, frame by frame. */
function live(): { readonly response: Response; readonly say: (text: string) => void; readonly end: () => void; readonly drop: () => void } {
  const held: { controller: ReadableStreamDefaultController<Uint8Array> | null } = { controller: null }
  const body = new ReadableStream<Uint8Array>({ start(controller) { held.controller = controller } })
  const controller = (): ReadableStreamDefaultController<Uint8Array> => {
    if (held.controller === null) throw new Error('the stream did not start')
    return held.controller
  }
  return {
    response: new Response(body, { status: 200, headers: { 'content-type': 'text/event-stream' } }),
    say: (text) => { controller().enqueue(new TextEncoder().encode(text)) },
    end: () => { controller().close() },
    drop: () => { controller().error(new TypeError('network error')) },
  }
}

interface Sent { readonly path: string; readonly method: string; readonly signal: AbortSignal | null }

/** Requests no answer was scripted for; each test checks at its end that there was none. */
const unscripted: string[] = []

type Scripted = Response | 'no answer' | Promise<Response>

function connecting(byPath: Readonly<Record<string, readonly Scripted[]>>, token: string | null = 'csrf') {
  const sent: Sent[] = []
  const left = new Map(Object.entries(byPath).map(([path, answers]) => [path, [...answers]]))
  const send: Send = (path, init) => {
    sent.push({ path, method: init.method ?? 'GET', signal: init.signal ?? null })
    const next = left.get(path)?.shift()
    if (next === undefined) {
      unscripted.push(path)
      return Promise.reject(new Error(`no answer was scripted for ${path}`))
    }
    return next === 'no answer' ? Promise.reject(new TypeError('fetch failed')) : Promise.resolve(next)
  }
  const leave = vi.fn()
  const refresh = vi.fn(() => Promise.resolve())
  const model = createConnect({ send, leave, token: () => token, refresh })
  return { model, sent, leave, refresh }
}

/** An answer the test gives when it wants. */
function held(): { readonly answer: Promise<Response>; readonly give: (response: Response) => void } {
  const hand: { give: (response: Response) => void } = { give: () => undefined }
  const answer = new Promise<Response>((resolve) => { hand.give = resolve })
  return { answer, give: (response) => { hand.give(response) } }
}

/** Lets the stream reader and the requests in flight go on. */
async function flush(): Promise<void> {
  for (let turn = 0; turn < 5; turn += 1) await new Promise((resolve) => setTimeout(resolve, 0))
}

const kind = (model: ConnectModel): string => model.view.value.kind
/** The input of a login whose stream the page reads, or the step it is in. */
const inputOf = (model: ConnectModel): Input | string => {
  const view = model.view.value
  return view.kind === 'running' || view.kind === 'cancelling' ? view.input : view.kind
}

/** A model whose login runs. */
async function following(more: Readonly<Record<string, readonly Scripted[]>> = {}) {
  const stream = live()
  const opened = connecting({ [loginPath]: [stream.response], ...more })
  opened.model.open()
  const done = opened.model.start('claude_code')
  stream.say(started)
  await flush()
  return { ...opened, stream, done }
}

/** A model whose login runs, whose stream then dropped. */
async function dropped(more: Readonly<Record<string, readonly Scripted[]>>) {
  const opened = await following(more)
  opened.stream.drop()
  await opened.done
  return opened
}

const text = { kind: 'text', text: 'code#1' } as const
const enter = { kind: 'key', key: 'enter' } as const

afterEach(() => {
  expect(unscripted.splice(0), 'requests that no answer was scripted for').toEqual([])
})

describe('opening and closing', () => {
  it('opens only when closed, and closes only where no stream is read', async () => {
    const { model, stream } = await following()
    expect(kind(model)).toBe('running')
    model.close()
    model.open()
    expect(kind(model)).toBe('running')
    stream.say(stopped('failed'))
    stream.end()
    await flush()
    model.open()
    expect(kind(model)).toBe('ended')
    model.close()
    expect(model.view.value).toEqual({ kind: 'closed', linked: false })
    model.open()
    expect(kind(model)).toBe('choosing')
  })

  it('closes on a detached login, and leaves it behind', async () => {
    const { model, sent } = await dropped({ [standing]: [json(503, { error: 'the files are being read again' })] })
    expect(kind(model)).toBe('detached')
    model.close()
    await model.check()
    expect([model.view.value, sent.length]).toEqual([{ kind: 'closed', linked: false }, 2])
  })
})

describe('a login', () => {
  it('follows a login that links an account, then reads the subscriptions again', async () => {
    const stream = live()
    const { model, refresh } = connecting({ [loginPath]: [stream.response] })
    model.open()
    const done = model.start('claude_code')
    expect(kind(model)).toBe('starting')
    stream.say(started)
    await flush()
    expect(model.view.value).toEqual({ kind: 'running', integrationId: 'claude_code', loginId: id, transcript: '', input: 'ready', cancelNotTaken: false })
    stream.say(printed('주소 ') + printed('https://example.com/x'))
    await flush()
    const view = model.view.value
    expect(view.kind === 'running' ? view.transcript : view.kind).toBe('주소 https://example.com/x')
    stream.say(linked)
    stream.end()
    await done
    expect([model.view.value, refresh.mock.calls.length]).toEqual([{ kind: 'closed', linked: true }, 1])
  })

  it('starts only from the list, once, and only with a session token', async () => {
    const stream = live()
    const once = connecting({ [loginPath]: [stream.response] })
    void once.model.start('claude_code')
    expect([kind(once.model), once.sent.length]).toEqual(['closed', 0])
    once.model.open()
    void once.model.start('claude_code')
    void once.model.start('claude_code')
    expect(once.sent.length).toBe(1)
    const without = connecting({}, null)
    without.model.open()
    await without.model.start('claude_code')
    expect([kind(without.model), without.sent.length]).toEqual(['choosing', 0])
  })

  it.each([
    ['failed', 'failed'],
    ['cancelled', 'cancelled'],
    ['interrupted', 'interrupted'],
    ['running', 'unrecorded'],
  ] as const)('ends a login whose stream says %s as %s, reads the subscriptions again, and starts again from there', async (status, ended) => {
    const first = live()
    const second = live()
    const { model, refresh, sent } = connecting({ [loginPath]: [first.response, second.response] })
    model.open()
    const done = model.start('claude_code')
    first.say(started + stopped(status))
    first.end()
    await done
    expect([model.view.value, refresh.mock.calls.length]).toEqual([{ kind: 'ended', integrationId: 'claude_code', ended }, 1])
    void model.start('claude_code')
    second.say(started)
    await flush()
    expect([kind(model), sent.length]).toEqual(['running', 2])
  })

  it('says a start the server refused, and starts again from there', async () => {
    const stream = live()
    const { model, sent } = connecting({ [loginPath]: [json(400, { error: 'This provider has no login here.' }), stream.response] })
    model.open()
    await model.start('claude_code')
    expect(model.view.value).toEqual({
      kind: 'failed', integrationId: 'claude_code',
      failure: { problem: { kind: 'refused', status: 400, reason: 'This provider has no login here.' }, attempts: 1 },
    })
    void model.start('claude_code')
    expect([kind(model), sent.length]).toEqual(['starting', 2])
  })

  it('leaves for the sign-in page when a start finds the session ended', async () => {
    const { model, leave } = connecting({ [loginPath]: [noSession()] })
    model.open()
    await model.start('claude_code')
    expect([kind(model), leave.mock.calls.length]).toEqual(['leaving', 1])
  })

  it('says a login failed when its stream was cut before it named the login', async () => {
    const stream = live()
    const { model, refresh } = connecting({ [loginPath]: [stream.response] })
    model.open()
    const done = model.start('claude_code')
    stream.end()
    await done
    expect([model.view.value, refresh.mock.calls.length]).toEqual([
      { kind: 'failed', integrationId: 'claude_code', failure: { problem: { kind: 'unreachable' }, attempts: 1 } }, 0,
    ])
  })

  it('keeps the newest part of what the client printed, from a whole character on', async () => {
    const { model, stream } = await following()
    stream.say(printed('x'.repeat(transcriptLimit)) + printed('y'))
    await flush()
    const plain = model.view.value
    expect(plain.kind === 'running' ? [plain.transcript.length, plain.transcript.slice(-2)] : plain.kind).toEqual([transcriptLimit, 'xy'])
    // Two units a character: the next one printed cuts the first in half.
    stream.say(printed('z' + '🌐'.repeat(transcriptLimit / 2)) + printed('y'))
    await flush()
    const wide = model.view.value
    expect(wide.kind === 'running' ? [wide.transcript.length, wide.transcript.codePointAt(0)] : wide.kind).toEqual([transcriptLimit - 1, 0x1f310])
  })
})

describe('a login whose stream was cut', () => {
  it.each([
    ['still runs', json(200, receipt('running')), 'detached', 0, 0],
    ['linked an account', json(200, receipt('complete', { account: 'linked', authentication: 'credential_captured' })), 'closed', 1, 0],
    ['was interrupted', json(200, receipt('interrupted')), 'ended', 1, 0],
    ['cannot be read now', json(503, { error: 'the files are being read again' }), 'detached', 0, 0],
    ['finds the session ended', noSession(), 'leaving', 0, 1],
  ] as const)('reads how the login stands: one that %s', async (_name, answer, step, refreshed, left) => {
    const { model, refresh, leave } = await dropped({ [standing]: [answer] })
    expect([kind(model), refresh.mock.calls.length, leave.mock.calls.length]).toEqual([step, refreshed, left])
  })

  it('reads a detached login again when asked', async () => {
    const { model, sent } = await dropped({ [standing]: [json(200, receipt('running')), json(200, receipt('failed'))] })
    expect(model.view.value).toEqual({ kind: 'detached', integrationId: 'claude_code', loginId: id, known: { kind: 'runs' } })
    await model.check()
    expect([model.view.value, sent.filter((one) => one.path === standing).length]).toEqual([{ kind: 'ended', integrationId: 'claude_code', ended: 'failed' }, 2])
  })

  it('keeps a login whose receipt cannot be read, says why, and counts the readings that failed in a row', async () => {
    const { model } = await dropped({
      [standing]: [json(503, { error: 'the files are being read again' }), 'no answer', json(200, receipt('running'))],
    })
    const known = (): unknown => {
      const view = model.view.value
      return view.kind === 'detached' ? view.known : view.kind
    }
    const first = known()
    await model.check()
    const second = known()
    await model.check()
    expect([first, second, known()]).toEqual([
      { kind: 'unread', failure: { problem: { kind: 'refused', status: 503, reason: 'the files are being read again' }, attempts: 1 } },
      { kind: 'unread', failure: { problem: { kind: 'unreachable' }, attempts: 2 } },
      { kind: 'runs' },
    ])
  })

  it.each(['running', 'cancelling'] as const)('reads the receipt of a login whose stream says what the page cannot read while it is %s', async (step) => {
    const { model, stream, done } = await following({ [cancelled]: [accepted()], [standing]: [json(200, receipt('running'))] })
    if (step === 'cancelling') await model.cancel()
    const before = kind(model)
    stream.say(frame('output', { stream: 'printer', text: '?' }))
    await done
    expect([before, model.view.value]).toEqual([step, { kind: 'detached', integrationId: 'claude_code', loginId: id, known: { kind: 'runs' } }])
  })

  it('says a login failed when its stream said what the page cannot read before it named the login', async () => {
    const stream = live()
    const { model, sent } = connecting({ [loginPath]: [stream.response] })
    model.open()
    const done = model.start('claude_code')
    stream.say(frame('started', { login_id: 'not an id' }))
    await done
    expect([model.view.value, sent.length]).toEqual([
      { kind: 'failed', integrationId: 'claude_code', failure: { problem: { kind: 'unreadable' }, attempts: 1 } }, 1,
    ])
  })
})

describe('replies', () => {
  it('sends a reply while the server holds none, and the next once the client took it', async () => {
    const { model, stream, sent } = await following({ [input]: [accepted(), accepted()] })
    expect(inputOf(model)).toBe('ready')
    const first = model.reply(text)
    expect(inputOf(model)).toBe('sending')
    expect(await model.reply(enter)).toBe(false)
    expect([await first, inputOf(model)]).toEqual([true, 'pending'])
    expect(await model.reply(enter)).toBe(false)
    stream.say(took)
    await flush()
    expect(inputOf(model)).toBe('ready')
    expect([await model.reply(enter), sent.filter((one) => one.path === input).length]).toEqual([true, 2])
  })

  it('keeps the input ready when the client took a reply before its answer came', async () => {
    const answer = held()
    const { model, stream } = await following({ [input]: [answer.answer] })
    const replying = model.reply(text)
    stream.say(took)
    await flush()
    answer.give(accepted())
    expect([await replying, inputOf(model)]).toEqual([true, 'ready'])
  })

  it('lets only the answer to the latest reply move the input', async () => {
    const first = held()
    const second = held()
    const { model, stream } = await following({ [input]: [first.answer, second.answer] })
    const one = model.reply({ kind: 'key', key: 'down' })
    stream.say(took)
    await flush()
    const two = model.reply(enter)
    first.give(accepted())
    await one
    expect(inputOf(model)).toBe('sending')
    second.give(json(409, { error: 'The previous login input has not been consumed yet.' }))
    expect([await two, inputOf(model)]).toEqual([false, 'not_taken'])
  })

  it('keeps a reply the server did not take ready to send again', async () => {
    const { model, sent } = await following({ [input]: [json(409, { error: 'An input is still pending.' }), 'no answer', accepted()] })
    expect([await model.reply(enter), inputOf(model)]).toEqual([false, 'not_taken'])
    expect([await model.reply(enter), inputOf(model)]).toEqual([false, 'not_taken'])
    expect([await model.reply(enter), inputOf(model), sent.filter((one) => one.path === input).length]).toEqual([true, 'pending', 3])
  })

  it('leaves for the sign-in page when a reply finds the session ended', async () => {
    const { model, leave } = await following({ [input]: [noSession()] })
    expect(await model.reply(text)).toBe(false)
    expect([kind(model), leave.mock.calls.length]).toEqual(['leaving', 1])
  })

  it('leaves for the sign-in page when a reply finds the session ended after a cancel went out', async () => {
    const answer = held()
    const { model, leave } = await following({ [input]: [answer.answer], [cancelled]: [accepted()] })
    const replying = model.reply(text)
    await model.cancel()
    answer.give(noSession())
    await replying
    expect([kind(model), leave.mock.calls.length]).toEqual(['leaving', 1])
  })
})

describe('cancelling', () => {
  it('waits for the stream to say how a cancelled login ended', async () => {
    const { model, stream, done } = await following({ [cancelled]: [accepted()] })
    const cancel = model.cancel()
    expect(kind(model)).toBe('cancelling')
    await cancel
    stream.say(printed('멈추는 중'))
    await flush()
    const view = model.view.value
    expect(view.kind === 'cancelling' ? view.transcript : view.kind).toBe('멈추는 중')
    stream.say(stopped('cancelled'))
    stream.end()
    await done
    expect(model.view.value).toEqual({ kind: 'ended', integrationId: 'claude_code', ended: 'cancelled' })
  })

  it('goes back to the login as it stands when the server did not take a cancel', async () => {
    const answer = held()
    const refusal = held()
    const { model, stream } = await following({ [input]: [answer.answer], [cancelled]: [refusal.answer] })
    const replying = model.reply(text)
    const cancelling = model.cancel()
    stream.say(printed('안내'))
    await flush()
    answer.give(accepted())
    await replying
    const taken = inputOf(model)
    stream.say(took)
    await flush()
    refusal.give(json(409, { error: 'The login is not running.' }))
    await cancelling
    const view = model.view.value
    expect([taken, view.kind === 'running' ? [view.cancelNotTaken, view.transcript, view.input] : view.kind]).toEqual(['pending', [true, '안내', 'ready']])
  })

  it('stops a detached login: says the server took the cancel, and reads how the login ended when asked', async () => {
    const { model, sent } = await dropped({
      [cancelled]: [accepted()],
      [standing]: [json(200, receipt('running')), json(200, receipt('cancelled'))],
    })
    const cancel = model.cancel()
    expect(kind(model)).toBe('checking')
    await cancel
    expect(model.view.value).toEqual({ kind: 'detached', integrationId: 'claude_code', loginId: id, known: { kind: 'cancel_taken' } })
    await model.check()
    expect([model.view.value, sent.filter((one) => one.path === standing).length]).toEqual([{ kind: 'ended', integrationId: 'claude_code', ended: 'cancelled' }, 2])
  })

  it.each([
    ['runs on', json(200, receipt('running')), { kind: 'detached', integrationId: 'claude_code', loginId: id, known: { kind: 'cancel_not_taken', problem: { kind: 'unreachable' } } }],
    ['stopped', json(200, receipt('interrupted')), { kind: 'ended', integrationId: 'claude_code', ended: 'interrupted' }],
  ] as const)('says a cancel of a detached login the server did not take, and reads the login, which %s', async (_name, answer, step) => {
    const { model } = await dropped({ [cancelled]: ['no answer'], [standing]: [json(200, receipt('running')), answer] })
    await model.cancel()
    expect(model.view.value).toEqual(step)
  })

  it('leaves for the sign-in page when a cancel finds the session ended', async () => {
    const { model, leave } = await following({ [cancelled]: [noSession()] })
    await model.cancel()
    expect([kind(model), leave.mock.calls.length]).toEqual(['leaving', 1])
  })

  it('leaves once: nothing the stream says after the session ended changes the step', async () => {
    const { model, stream, done, leave, refresh } = await following({ [cancelled]: [noSession()] })
    await model.cancel()
    stream.say(stopped('cancelled'))
    stream.end()
    await done
    expect([model.view.value, leave.mock.calls.length, refresh.mock.calls.length]).toEqual([{ kind: 'leaving' }, 1, 0])
  })
})

describe('another person', () => {
  it('leaves a running login behind: closes its stream, and nothing it says later changes the area', async () => {
    const { model, stream, done, refresh, sent } = await following()
    model.reset()
    stream.say(linked)
    stream.end()
    await done
    expect([model.view.value, refresh.mock.calls.length, sent[0]?.signal?.aborted]).toEqual([{ kind: 'closed', linked: false }, 0, true])
  })

  it('lets no frame of a login left behind take the place of a new one', async () => {
    const old = live()
    const fresh = live()
    const { model } = connecting({ [loginPath]: [old.response, fresh.response] })
    model.open()
    void model.start('claude_code')
    model.reset()
    model.open()
    void model.start('claude_code')
    old.say(started)
    await flush()
    expect(kind(model)).toBe('starting')
  })

  it('lets no reading of a login left behind change the area', async () => {
    const stream = live()
    const answer = held()
    const { model } = connecting({ [loginPath]: [stream.response], [standing]: [answer.answer] })
    model.open()
    const done = model.start('claude_code')
    stream.say(started)
    await flush()
    stream.drop()
    await flush()
    const before = kind(model)
    model.reset()
    answer.give(json(200, receipt('running')))
    await done
    expect([before, model.view.value]).toEqual(['checking', { kind: 'closed', linked: false }])
  })
})
