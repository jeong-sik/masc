// A person's login to a subscription. POST /api/v1/setup/accounts/login
// answers an event stream (lib/server/server_setup_account_login.ml, `start`):
// `started` once the official client runs, `output` for what it prints,
// `input_ready` once the client took a reply, and last `complete` or `error`.
// A person's login always makes a new account, which the authorization log
// links to them: no frame names an account reference, and the last frame of
// a login that worked says `"account": "linked"`
// (lib/runtime/runtime_setup_login_receipt.ml, `to_json`).
//
// The stream is read as strictly as wire.ts reads an answer: a frame that is
// not what the stream promises, or text after the last frame, ends the
// reading as unreadable. The sentence of an `error` frame is not read: it is
// written for the server's operator.

import { isRecord } from '../lib/type-guards'
import { bodyOf, csrfHeader, deliver, get, problemOf } from './wire'
import type { Answer, Problem, Send } from './wire'

export const loginPath = '/api/v1/setup/accounts/login'

/** What the official client did while a login runs. */
export type LoginProgress =
  | { readonly kind: 'started'; readonly loginId: string }
  | { readonly kind: 'output'; readonly text: string }
  /** The client took the last reply: the server takes another. */
  | { readonly kind: 'input_ready' }

/** How a login that made no account stopped, as its receipt keeps it. */
export type Stopped = 'failed' | 'cancelled' | 'interrupted'

/** How the stream says a login ended without an account. */
export type LoginEnd =
  | Stopped
  /** The server could not write how the login ended: its receipt still says it runs. */
  | 'unrecorded'

export type LoginOutcome =
  /** The new account is linked to the person. */
  | { readonly kind: 'linked' }
  | { readonly kind: 'ended'; readonly end: LoginEnd }
  /** The stream stopped before its last frame, so how the login ended is not known here. */
  | { readonly kind: 'cut'; readonly loginId: string | null }
  | { readonly kind: 'problem'; readonly problem: Problem }

/** How a login stands, read from its receipt. */
export type LoginStanding =
  /** Its client still runs. */
  | { readonly kind: 'running' }
  | { readonly kind: 'linked' }
  | { readonly kind: 'ended'; readonly end: Stopped }

/** What a person sends to the client: text, or one of the keys the server takes. */
export type Reply =
  | { readonly kind: 'text'; readonly text: string }
  | { readonly kind: 'key'; readonly key: 'enter' | 'up' | 'down' | 'tab' | 'eof' }

/** How a receipt says the client of a login was let in
    (lib/runtime/runtime_setup_login_receipt.ml, `of_json`). */
const authentications: readonly string[] = ['authenticated', 'login_completed', 'credential_captured']

const loginIdShape = /^[a-f0-9]{64}$/
const loginIdOf = (value: unknown): string | null => (typeof value === 'string' && loginIdShape.test(value) ? value : null)

/** The login id of a receipt of a person's login of `integrationId` whose
    status is one of `statuses`, or null. A person's receipt names no account
    reference; only a complete one says its account is linked. */
function receiptOf(json: unknown, integrationId: string, statuses: readonly string[]): string | null {
  if (!isRecord(json) || json.integration_id !== integrationId || json.invocation_verified !== false) return null
  if (json.account_ref !== undefined || typeof json.status !== 'string' || !statuses.includes(json.status)) return null
  const fits = json.status === 'complete'
    ? json.account === 'linked' && typeof json.authentication === 'string' && authentications.includes(json.authentication)
    : json.account === undefined && json.authentication === undefined
  return fits ? loginIdOf(json.login_id) : null
}

function endOf(status: unknown): LoginEnd | null {
  switch (status) {
    case 'failed': return 'failed'
    case 'cancelled': return 'cancelled'
    case 'interrupted': return 'interrupted'
    case 'running': return 'unrecorded'
    default: return null
  }
}

/** A frame of the stream: its event name and its data, read as JSON. */
interface Frame { readonly event: string; readonly data: unknown }

/** The frame of the text between two blank lines, or null when it is not one
    `event:` line and one `data:` line of JSON, as the server writes them. */
function frameOf(block: string): Frame | null {
  const [eventLine, dataLine, ...rest] = block.split('\n')
  if (eventLine === undefined || dataLine === undefined || rest.length > 0) return null
  if (!eventLine.startsWith('event: ') || !dataLine.startsWith('data: ')) return null
  try {
    return { event: eventLine.slice('event: '.length), data: JSON.parse(dataLine.slice('data: '.length)) as unknown }
  } catch {
    return null
  }
}

type Reading =
  | { readonly kind: 'next'; readonly loginId: string }
  | { readonly kind: 'last'; readonly outcome: LoginOutcome }

/** What one frame says, given the login id the stream named so far, or
    null when the stream does not promise that frame there. */
function read(frame: Frame, integrationId: string, loginId: string | null, onProgress: (progress: LoginProgress) => void): Reading | null {
  const same = (id: string | null): boolean => id !== null && (loginId === null || id === loginId)
  switch (frame.event) {
    case 'started': {
      const id = receiptOf(frame.data, integrationId, ['running'])
      if (loginId !== null || id === null) return null
      onProgress({ kind: 'started', loginId: id })
      return { kind: 'next', loginId: id }
    }
    case 'output': {
      const data = frame.data
      if (loginId === null || !isRecord(data) || typeof data.text !== 'string') return null
      if (data.stream !== 'stdout' && data.stream !== 'stderr' && data.stream !== 'terminal') return null
      onProgress({ kind: 'output', text: data.text })
      return { kind: 'next', loginId }
    }
    case 'input_ready':
      if (loginId === null || !isRecord(frame.data) || Object.keys(frame.data).length !== 0) return null
      onProgress({ kind: 'input_ready' })
      return { kind: 'next', loginId }
    case 'complete':
      return loginId !== null && receiptOf(frame.data, integrationId, ['complete']) === loginId
        ? { kind: 'last', outcome: { kind: 'linked' } }
        : null
    case 'error': {
      const data = frame.data
      const id = receiptOf(data, integrationId, ['running', 'failed', 'cancelled', 'interrupted'])
      const end = isRecord(data) && typeof data.message === 'string' ? endOf(data.status) : null
      return same(id) && end !== null ? { kind: 'last', outcome: { kind: 'ended', end } } : null
    }
    default:
      return null
  }
}

/** Starts a login of `integrationId` and reads its stream to the end. Each
    step of the client goes to `onProgress` as it comes. `signal` closes the
    stream, and the server stops a login whose stream closed. */
export async function connect(
  to: Send,
  csrfToken: string,
  integrationId: string,
  signal: AbortSignal,
  onProgress: (progress: LoginProgress) => void,
): Promise<LoginOutcome> {
  const response = await deliver(to, loginPath, {
    method: 'POST',
    headers: { accept: 'text/event-stream', 'content-type': 'application/json', [csrfHeader]: csrfToken },
    body: JSON.stringify({ integration_id: integrationId }),
    signal,
  })
  if (response === null) return { kind: 'problem', problem: { kind: 'unreachable' } }
  if (!response.ok) return { kind: 'problem', problem: await problemOf(response) }
  if (response.body === null) return { kind: 'problem', problem: { kind: 'unreadable' } }
  const reader = response.body.getReader()
  const decoder = new TextDecoder()
  const unreadable: LoginOutcome = { kind: 'problem', problem: { kind: 'unreadable' } }
  let buffer = ''
  let loginId: string | null = null
  /** What the last frame said, once it came. The server closes the stream
      after it, and the reading goes on to that end. */
  let last: LoginOutcome | null = null
  try {
    for (;;) {
      let chunk: ReadableStreamReadResult<Uint8Array>
      try {
        chunk = await reader.read()
      } catch {
        return last ?? { kind: 'cut', loginId }
      }
      buffer = (buffer + decoder.decode(chunk.value, { stream: !chunk.done })).replace(/\r\n/g, '\n')
      for (let cut = buffer.indexOf('\n\n'); cut >= 0; cut = buffer.indexOf('\n\n')) {
        const frame = frameOf(buffer.slice(0, cut))
        buffer = buffer.slice(cut + 2)
        const reading: Reading | null = frame === null || last !== null ? null : read(frame, integrationId, loginId, onProgress)
        if (reading === null) return unreadable
        if (reading.kind === 'last') last = reading.outcome
        else loginId = reading.loginId
      }
      if (last !== null && buffer.trim() !== '') return unreadable
      // A stream that ends inside a frame was cut there.
      if (chunk.done) return last ?? { kind: 'cut', loginId }
    }
  } finally {
    await reader.cancel().catch(() => undefined)
  }
}

const readAccepted = (json: unknown): null | undefined => (isRecord(json) && json.accepted === true ? null : undefined)

async function control(to: Send, csrfToken: string, path: string, body: unknown): Promise<Answer<null>> {
  const response = await deliver(to, path, {
    method: 'POST',
    headers: { accept: 'application/json', 'content-type': 'application/json', [csrfHeader]: csrfToken },
    body: JSON.stringify(body),
  })
  if (response === null) return { ok: false, problem: { kind: 'unreachable' } }
  if (!response.ok) return { ok: false, problem: await problemOf(response) }
  return readAccepted(await bodyOf(response)) === null ? { ok: true, value: null } : { ok: false, problem: { kind: 'unreadable' } }
}

/** Sends a reply to the client of the login `loginId`. The server answers 202. */
export const reply = (to: Send, csrfToken: string, loginId: string, input: Reply): Promise<Answer<null>> =>
  control(to, csrfToken, `${loginPath}/${loginId}/input`, input)

/** Asks the server to stop the login `loginId`. Its stream then ends with `cancelled`. */
export const cancel = (to: Send, csrfToken: string, loginId: string): Promise<Answer<null>> =>
  control(to, csrfToken, `${loginPath}/${loginId}/cancel`, {})

/** How the login `loginId` of `integrationId` stands, read from its receipt
    once its stream was cut. The server says `running` only while the client
    still runs, and `interrupted` once it does not
    (lib/server/server_setup_account_login.ml, `status`). */
export function standingOf(to: Send, loginId: string, integrationId: string): Promise<Answer<LoginStanding>> {
  return get(to, `${loginPath}/${loginId}`, (json): LoginStanding | null => {
    if (receiptOf(json, integrationId, ['complete']) === loginId) return { kind: 'linked' }
    if (receiptOf(json, integrationId, ['running', 'failed', 'cancelled', 'interrupted']) !== loginId || !isRecord(json)) return null
    switch (json.status) {
      case 'running': return { kind: 'running' }
      case 'failed': return { kind: 'ended', end: 'failed' }
      case 'cancelled': return { kind: 'ended', end: 'cancelled' }
      case 'interrupted': return { kind: 'ended', end: 'interrupted' }
      default: return null
    }
  })
}
