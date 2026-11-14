// The stream of a person's login and its controls: what is sent, how each
// frame is read, and which streams are refused.
import { describe, expect, it } from 'vitest'
import { cancel, connect, loginPath, reply, standingOf } from './login'
import type { LoginProgress } from './login'
import { csrfHeader } from './wire'
import type { Send } from './wire'

const id = 'a'.repeat(64)
const otherId = 'b'.repeat(64)
const frame = (event: string, data: unknown): string => `event: ${event}\r\ndata: ${JSON.stringify(data)}\r\n\r\n`
const receipt = (status: string, more: Readonly<Record<string, unknown>> = {}) =>
  ({ login_id: id, integration_id: 'claude_code', status, invocation_verified: false, ...more })
const started = frame('started', receipt('running'))
const linked = frame('complete', receipt('complete', { account: 'linked', authentication: 'login_completed' }))
const json = (status: number, body: unknown): Response =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } })

/** An answer whose body comes `size` bytes at a time. */
function streamed(body: string, size = 7): Response {
  const bytes = new TextEncoder().encode(body)
  return new Response(new ReadableStream({
    start(controller) {
      for (let at = 0; at < bytes.length; at += size) controller.enqueue(bytes.slice(at, at + size))
      controller.close()
    },
  }), { status: 200, headers: { 'content-type': 'text/event-stream' } })
}

/** An answer whose body breaks off after `body`, as a dropped connection does. */
function broken(body: string): Response {
  const bytes = new TextEncoder().encode(body)
  let given = false
  return new Response(new ReadableStream({
    pull(controller) {
      if (given) controller.error(new TypeError('network error'))
      else { given = true; controller.enqueue(bytes) }
    },
  }), { status: 200 })
}

interface Sent { readonly path: string; readonly init: RequestInit }

function sending(...answers: Array<Response | 'no answer'>): { readonly send: Send; readonly sent: Sent[] } {
  const sent: Sent[] = []
  const send: Send = (path, init) => {
    sent.push({ path, init })
    const next = answers.shift()
    if (next === undefined) return Promise.reject(new Error(`nothing was scripted for ${path}`))
    return next === 'no answer' ? Promise.reject(new TypeError('fetch failed')) : Promise.resolve(next)
  }
  return { send, sent }
}

const only = (sent: readonly Sent[]): Sent => {
  const [first, ...rest] = sent
  if (first === undefined || rest.length > 0) throw new Error(`${sent.length} requests were sent`)
  return first
}

const ignore = (): void => undefined

/** The signal of a stream nothing closes. */
const kept = (): AbortSignal => new AbortController().signal

describe('connect', () => {
  it('reads a login that links an account, frame by frame as the bytes come', async () => {
    const { send, sent } = sending(streamed(started + frame('output', { stream: 'terminal', text: '주소 https://example.com/x 🌐' })
      + frame('input_ready', {}) + linked))
    const progress: LoginProgress[] = []
    const signal = kept()
    expect(await connect(send, 'csrf', 'claude_code', signal, (one) => progress.push(one))).toEqual({ kind: 'linked' })
    expect(progress).toEqual([{ kind: 'started', loginId: id }, { kind: 'output', text: '주소 https://example.com/x 🌐' }, { kind: 'input_ready' }])
    const request = only(sent)
    const headers = new Headers(request.init.headers)
    expect([request.path, request.init.method, request.init.credentials, request.init.body, request.init.signal]).toEqual(
      [loginPath, 'POST', 'same-origin', JSON.stringify({ integration_id: 'claude_code' }), signal])
    expect([headers.get(csrfHeader), headers.get('authorization')]).toEqual(['csrf', null])
  })

  it.each([
    ['failed', 'failed'],
    ['cancelled', 'cancelled'],
    ['interrupted', 'interrupted'],
    ['running', 'unrecorded'],
  ] as const)('reads a login whose receipt says %s as ended %s', async (status, end) => {
    const { send } = sending(streamed(started + frame('error', { message: 'a sentence for the operator', ...receipt(status) })))
    expect(await connect(send, 'csrf', 'claude_code', kept(), ignore)).toEqual({ kind: 'ended', end })
  })

  it('reads a login that ended before its client ran', async () => {
    const progress: LoginProgress[] = []
    const { send } = sending(streamed(frame('error', { message: 'a sentence', ...receipt('failed') })))
    expect(await connect(send, 'csrf', 'claude_code', kept(), (one) => progress.push(one))).toEqual({ kind: 'ended', end: 'failed' })
    expect(progress).toEqual([])
  })

  it.each([
    ['after its client ran', streamed(started), id],
    ['before anything came', streamed(''), null],
    ['by a dropped connection', broken(started), id],
    ['inside a frame after its client ran', streamed(`${started}event: outp`), id],
    ['inside its first frame', streamed('event: sta'), null],
  ] as const)('says a stream that stopped %s was cut, with the login it named', async (_name, answer, loginId) => {
    expect(await connect(sending(answer).send, 'csrf', 'claude_code', kept(), ignore)).toEqual({ kind: 'cut', loginId })
  })

  it('keeps what the last frame said when the connection drops after it', async () => {
    expect(await connect(sending(broken(started + linked)).send, 'csrf', 'claude_code', kept(), ignore)).toEqual({ kind: 'linked' })
  })

  it.each([
    ['a refusal', json(400, { error: 'This provider has no login here.' }), { kind: 'refused', status: 400, reason: 'This provider has no login here.' }],
    ['an ended session', json(401, { error: 'no session' }), { kind: 'signed_out' }],
    ['no answer', 'no answer', { kind: 'unreachable' }],
  ] as const)('gives the problem of %s before any stream', async (_name, answer, problem) => {
    expect(await connect(sending(answer).send, 'csrf', 'claude_code', kept(), ignore)).toEqual({ kind: 'problem', problem })
  })

  it.each([
    ['a start that names an account reference', frame('started', receipt('running', { account_ref: otherId }))],
    ['a start of another subscription', frame('started', { ...receipt('running'), integration_id: 'codex' })],
    ['a start with a login id of another shape', frame('started', { ...receipt('running'), login_id: 'login-1' })],
    ['a start that says the invocation was checked', frame('started', { ...receipt('running'), invocation_verified: true })],
    ['output before the start', frame('output', { stream: 'stdout', text: 'x' })],
    ['a second start', started + started],
    ['output of no known stream', started + frame('output', { stream: 'tty', text: 'x' })],
    ['a wait that carries data', started + frame('input_ready', { text: 'x' })],
    ['an end with no linked account', started + frame('complete', receipt('complete', { authentication: 'login_completed' }))],
    ['an end whose authentication no receipt says', started + frame('complete', receipt('complete', { account: 'linked', authentication: 'guessed' }))],
    ['an end that names an account reference', started + frame('complete', receipt('complete', { account: 'linked', account_ref: otherId, authentication: 'authenticated' }))],
    ['an end of another login', started + frame('complete', { ...receipt('complete', { account: 'linked', authentication: 'authenticated' }), login_id: otherId })],
    ['an error of another login', started + frame('error', { ...receipt('failed'), login_id: otherId })],
    ['an error with no sentence', started + frame('error', receipt('failed'))],
    ['an error that says the login is complete', started + frame('error', receipt('complete', { account: 'linked', authentication: 'authenticated' }))],
    ['an event this console does not know', started + frame('progress', {})],
    ['a frame with a comment line', `: keep-alive\r\n${started}`],
    ['a frame with a second data line', `${started}event: input_ready\r\ndata: {}\r\ndata: {}\r\n\r\n`],
    ['a frame whose data is not JSON', 'event: started\r\ndata: {\r\n\r\n'],
  ])('refuses %s', async (_name, body) => {
    expect(await connect(sending(streamed(body)).send, 'csrf', 'claude_code', kept(), ignore)).toEqual({ kind: 'problem', problem: { kind: 'unreadable' } })
  })

  // Sizes that end a piece at the end of the last frame, before it and after it.
  it.each([1, 2, 7, linked.length, 4096])('refuses text after the last frame when the bytes come %i at a time', async (size) => {
    for (const after of [frame('output', { stream: 'stdout', text: 'x' }), 'event: outp']) {
      const answer = streamed(started + linked + after, size)
      expect(await connect(sending(answer).send, 'csrf', 'claude_code', kept(), ignore)).toEqual({ kind: 'problem', problem: { kind: 'unreadable' } })
    }
  })
})

describe('the controls of a login', () => {
  it.each([
    ['a code', (send: Send) => reply(send, 'csrf', id, { kind: 'text', text: 'code#123' }), `${loginPath}/${id}/input`, { kind: 'text', text: 'code#123' }],
    ['a key', (send: Send) => reply(send, 'csrf', id, { kind: 'key', key: 'enter' }), `${loginPath}/${id}/input`, { kind: 'key', key: 'enter' }],
    ['a cancel', (send: Send) => cancel(send, 'csrf', id), `${loginPath}/${id}/cancel`, {}],
  ] as const)('sends %s with the session token', async (_name, act, path, body) => {
    const { send, sent } = sending(json(202, { accepted: true }))
    expect(await act(send)).toEqual({ ok: true, value: null })
    const request = only(sent)
    const headers = new Headers(request.init.headers)
    expect([request.path, request.init.method, request.init.credentials, request.init.body]).toEqual([path, 'POST', 'same-origin', JSON.stringify(body)])
    expect([headers.get(csrfHeader), headers.get('authorization')]).toEqual(['csrf', null])
  })

  it('gives the problem of a reply the server refuses or does not confirm', async () => {
    expect(await reply(sending(json(409, { error: 'An input is still pending.' })).send, 'csrf', id, { kind: 'key', key: 'up' }))
      .toEqual({ ok: false, problem: { kind: 'refused', status: 409, reason: 'An input is still pending.' } })
    expect(await cancel(sending(json(202, {})).send, 'csrf', id)).toEqual({ ok: false, problem: { kind: 'unreadable' } })
  })
})

describe('standingOf', () => {
  it.each([
    ['running', { kind: 'running' }],
    ['failed', { kind: 'ended', end: 'failed' }],
    ['cancelled', { kind: 'ended', end: 'cancelled' }],
    ['interrupted', { kind: 'ended', end: 'interrupted' }],
  ] as const)('reads a receipt that says %s', async (status, standing) => {
    const { send, sent } = sending(json(200, receipt(status)))
    expect(await standingOf(send, id, 'claude_code')).toEqual({ ok: true, value: standing })
    expect(only(sent).path).toBe(`${loginPath}/${id}`)
  })

  it('reads a complete receipt as a linked account', async () => {
    const answer = json(200, receipt('complete', { account: 'linked', authentication: 'credential_captured' }))
    expect(await standingOf(sending(answer).send, id, 'claude_code')).toEqual({ ok: true, value: { kind: 'linked' } })
  })

  it.each([
    ['of another login', { ...receipt('failed'), login_id: otherId }],
    ['of another subscription', { ...receipt('failed'), integration_id: 'codex' }],
    ['with no status', { ...receipt('failed'), status: undefined }],
  ])('refuses a receipt %s', async (_name, body) => {
    expect(await standingOf(sending(json(200, body)).send, id, 'claude_code')).toEqual({ ok: false, problem: { kind: 'unreadable' } })
  })
})
