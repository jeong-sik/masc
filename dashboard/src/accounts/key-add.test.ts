// @vitest-environment happy-dom
//
// Connecting a subscription with an API key: what an add sends, what the
// server's answer reads as, how the add moves, and where the key is on the
// page. What a step says and where it puts things is not checked here: that
// is read in a browser. The keys here are made-up strings.
import { afterEach, describe, expect, it, vi } from 'vitest'
import { signal } from '@preact/signals'
import { act, cleanup, fireEvent, render } from '@testing-library/preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { addKey, addPath, createKeyAdds } from './key-add'
import type { AddFailure, AddView, KeyAddModel, Kept } from './key-add'
import { KeyArea } from './key-area'
import { csrfHeader } from './wire'
import type { Integration, Send } from './wire'

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

/** Something that settles when the test says so. */
function later<T>(): { readonly promise: Promise<T>; readonly give: (value: T) => void } {
  let give: (value: T) => void = () => { throw new Error('it was given before it was asked for') }
  const promise = new Promise<T>((resolve) => { give = resolve })
  return { promise, give: (value) => { give(value) } }
}

const json = (status: number, body: unknown): Response =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } })

/** A made-up key. No test may find it anywhere but in the field and in the body of the request. */
const key = 'made-up-key-0123456789'
const stored = (): Response => json(200, { provider_account_id: 'acct_new', kind: 'key' })
const refusedAs = (status: number, code: string): Response => json(status, { error: `The server said ${code}.`, code })
const notAKey = (): Response => refusedAs(400, 'not_a_key')
const accountStays = (): Response => json(503, { error: 'Remove this account, and send the key again.', code: 'account_not_removed', provider_account_id: 'acct_left' })
const noSession = (): Response => json(401, { error: 'no session cookie came with the request' })

afterEach(() => {
  cleanup()
})

describe('sending a key', () => {
  it('posts the subscription and the key, with the token of the session and no other credential, and follows no redirect', async () => {
    const { send, sent } = answering([stored()])
    expect(await addKey(send, 'token-1', 'claude_code', key)).toEqual({ kind: 'stored', accountId: 'acct_new' })
    const init: RequestInit = sent[0]?.init ?? {}
    const headers = new Headers(init.headers)
    expect([sent.map(({ path }) => path), init.method, init.credentials, init.redirect, headers.get(csrfHeader), headers.has('authorization'), headers.get('content-type')])
      .toEqual([[addPath], 'POST', 'same-origin', 'error', 'token-1', false, 'application/json'])
    expect(JSON.parse(String(init.body))).toEqual({ integration_id: 'claude_code', key })
  })

  it('sends the key as the person gave it: the server takes the blanks around it away', async () => {
    const { send, sent } = answering([stored()])
    await addKey(send, 'token-1', 'claude_code', `  ${key} `)
    expect(JSON.parse(String(sent[0]?.init.body))).toEqual({ integration_id: 'claude_code', key: `  ${key} ` })
  })

  it.each([
    ['invalid_request', 400], ['not_a_key', 400], ['unknown_integration', 400], ['integration_takes_no_key', 400], ['registration_refused', 403],
    ['internal_error', 500], ['configuration_unavailable', 503], ['registration_not_recorded', 503], ['key_not_stored', 503],
  ])('reads the refusal %s by its code', async (code, status) => {
    const { send } = answering([refusedAs(status, code)])
    expect(await addKey(send, 'token-1', 'claude_code', key))
      .toEqual({ kind: 'refused', status, code, reason: `The server said ${code}.`, accountId: null })
  })

  it.each([
    ['an account the server could not remove again', accountStays(),
      { kind: 'refused', status: 503, code: 'account_not_removed', reason: 'Remove this account, and send the key again.', accountId: 'acct_left' }],
    ['a session that ended', noSession(), { kind: 'signed_out' }],
    ['no answer', 'no answer' as const, { kind: 'unreachable' }],
    ['an answer of another route that says all is well', json(200, { provider_accounts: [] }), { kind: 'unreadable' }],
    ['an answer that names an account of another kind', json(200, { provider_account_id: 'acct_new', kind: 'login' }), { kind: 'unreadable' }],
    ['an answer that says all is well and names no account', json(200, { kind: 'key' }), { kind: 'unreadable' }],
    ['an answer that says all is well and is not JSON', new Response('<html>sign in</html>', { status: 200 }), { kind: 'unreadable' }],
    ['a refusal with a code it does not know', refusedAs(409, 'volume_away'), { kind: 'refused', status: 409, code: 'unrecognised', reason: 'The server said volume_away.', accountId: null }],
    ['a failure with a code it does not know', refusedAs(503, 'volume_away'), { kind: 'server_failed' }],
    ['a failure that is not JSON', new Response('Bad Gateway', { status: 502 }), { kind: 'server_failed' }],
    ['a refusal with no code', json(403, { error: 'the request carried no token' }), { kind: 'refused', status: 403, code: 'unrecognised', reason: 'the request carried no token', accountId: null }],
    ['a body that was too large', new Response('The body is larger than 16384 bytes.', { status: 413 }), { kind: 'refused', status: 413, code: 'unrecognised', reason: null, accountId: null }],
  ])('reads %s', async (_name, answer, sent) => {
    const { send } = answering([answer])
    expect(await addKey(send, 'token-1', 'claude_code', key)).toEqual(sent)
  })

  it('reads nothing of the key back from an answer', async () => {
    const { send } = answering([json(200, { provider_account_id: 'acct_new', kind: 'key', key })])
    expect(JSON.stringify(await addKey(send, 'token-1', 'claude_code', key))).not.toContain(key)
  })
})

/** An add over scripted answers, and what it asked of the panel. */
function adding(answers: readonly Scripted[], token: string | null = 'token-1') {
  const { send, sent } = answering(answers)
  const leave = vi.fn()
  const refresh = vi.fn(() => Promise.resolve())
  const model = createKeyAdds({ send, leave, token: () => token, refresh })
  return { model, sent, leave, refresh }
}

describe('the giving of a key', () => {
  it('opens and closes the form', () => {
    const { model } = adding([])
    const before = model.view.value
    model.open()
    const opened = model.view.value
    model.close()
    expect([before, opened, model.view.value]).toEqual([{ kind: 'closed', stored: null }, { kind: 'open', failure: null }, { kind: 'closed', stored: null }])
  })

  it('closes the form on the account the server made, drops the key, and reads the subscriptions again', async () => {
    const reading = later<undefined>()
    const { send } = answering([stored()])
    const refresh = vi.fn(() => reading.promise)
    const model = createKeyAdds({ send, leave: vi.fn(), token: () => 'token-1', refresh })
    model.open()
    const run = model.add('claude_code', key)
    await vi.waitFor(() => { expect(refresh).toHaveBeenCalledTimes(1) })
    // The form is off the page before the list is read: the key does not wait for it.
    const during = model.view.value
    reading.give(undefined)
    expect([during, await run]).toEqual([{ kind: 'closed', stored: 'acct_new' }, 'dropped'])
  })

  it('keeps the key and the form after a refusal that stored nothing, and reads nothing again', async () => {
    const { model, refresh } = adding([notAKey(), notAKey()])
    model.open()
    const first = await model.add('claude_code', key)
    const second = await model.add('claude_code', key)
    expect([first, second, model.view.value, refresh.mock.calls.length]).toEqual([
      'kept', 'kept',
      { kind: 'open', failure: { kind: 'refused', status: 400, code: 'not_a_key', reason: 'The server said not_a_key.', accountId: null, attempts: 2 } },
      0,
    ])
  })

  it.each([
    ['key_not_stored', 503], ['registration_not_recorded', 503], ['configuration_unavailable', 503], ['registration_refused', 403],
    ['internal_error', 500], ['invalid_request', 400], ['volume_away', 409],
  ])('reads nothing again after the refusal %s', async (code, status) => {
    const { model, refresh } = adding([refusedAs(status, code)])
    model.open()
    expect([await model.add('claude_code', key), refresh.mock.calls.length]).toEqual(['kept', 0])
  })

  it.each([
    ['an account the server could not remove again', accountStays()],
    ['a subscription the server does not have', refusedAs(400, 'unknown_integration')],
    ['a subscription that takes no key', refusedAs(400, 'integration_takes_no_key')],
  ])('reads the subscriptions again after %s, and keeps the key', async (_name, answer) => {
    const { model, refresh } = adding([answer])
    model.open()
    expect([await model.add('claude_code', key), model.view.value.kind, refresh.mock.calls.length]).toEqual(['kept', 'open', 1])
  })

  it.each([
    ['no answer', 'no answer' as const, 'none'],
    ['an answer it cannot read', json(200, { provider_accounts: [] }), 'unreadable'],
    ['a failure with no code of the route', new Response('Bad Gateway', { status: 502 }), 'server_failed'],
  ])('drops the key after %s, for the server may have stored it, and reads the subscriptions again', async (_name, answer, read) => {
    const { model, refresh } = adding([answer])
    model.open()
    expect([await model.add('claude_code', key), model.view.value, refresh.mock.calls.length])
      .toEqual(['dropped', { kind: 'open', failure: { kind: 'unknown', answer: read, attempts: 1 } }, 1])
  })

  it.each([
    ['no answer', 'no answer' as const],
    ['an answer it cannot read', json(200, { provider_accounts: [] })],
    ['a failure with no code of the route', new Response('Bad Gateway', { status: 502 })],
  ])('drops the key after %s without waiting for the subscriptions to be read again', async (_name, answer) => {
    const reading = later<void>()
    const refresh = vi.fn(() => reading.promise)
    const model = createKeyAdds({ send: answering([answer]).send, leave: vi.fn(), token: () => 'token-1', refresh })
    model.open()
    expect([await model.add('claude_code', key), refresh.mock.calls.length]).toEqual(['dropped', 1])
  })

  it('sends one request while a key is on its way, holds nothing of the key, and does not close meanwhile', async () => {
    const answer = later<Response>()
    const { model, sent } = adding([answer.promise])
    model.open()
    const first = model.add('claude_code', key)
    const second = await model.add('claude_code', key)
    model.close()
    const during = model.view.value
    answer.give(notAKey())
    await first
    expect([sent.length, second, during]).toEqual([1, 'kept', { kind: 'sending', failure: null }])
    expect(Object.keys(during)).toEqual(['kind', 'failure'])
  })

  it('sends nothing from a form that is not open, or before a session', async () => {
    const closed = adding([stored()])
    const early = adding([stored()], null)
    early.model.open()
    expect([await closed.model.add('claude_code', key), await early.model.add('claude_code', key), closed.sent.length, early.sent.length, early.model.view.value.kind])
      .toEqual(['kept', 'kept', 0, 0, 'open'])
  })

  it('leaves with the page once an add finds no session, and sends nothing after', async () => {
    const { model, sent, leave, refresh } = adding([noSession(), stored()])
    model.open()
    const first = await model.add('claude_code', key)
    model.open()
    const second = await model.add('claude_code', key)
    expect([first, second, model.view.value, leave.mock.calls.length, sent.length, refresh.mock.calls.length])
      .toEqual(['dropped', 'kept', { kind: 'leaving' }, 1, 1, 0])
  })

  it('forgets the add for another person, and an answer that comes later changes nothing', async () => {
    const answer = later<Response>()
    const { model, refresh } = adding([answer.promise])
    model.open()
    const run = model.add('claude_code', key)
    model.reset()
    answer.give(stored())
    expect([await run, model.view.value, refresh.mock.calls.length]).toEqual(['dropped', { kind: 'closed', stored: null }, 0])
  })

  it('gives a key again for the person shown after one whose session ended', async () => {
    const { model, sent } = adding([noSession(), stored()])
    model.open()
    await model.add('claude_code', key)
    model.reset()
    model.open()
    expect([await model.add('claude_code', key), model.view.value, sent.length]).toEqual(['dropped', { kind: 'closed', stored: 'acct_new' }, 2])
  })
})

// ---- the area ----

const claude: Integration = { id: 'claude_code', displayName: 'Claude Code', models: ['claude-sonnet-5'], withheld: [], calls: { kind: 'allowed' }, takesKey: true }
const second: Integration = { id: 'claude_team', displayName: 'Claude Team', models: ['claude-sonnet-5'], withheld: [], calls: { kind: 'allowed' }, takesKey: true }

/** A model that shows `view` and counts what it is asked. An add ends as `kept` says. */
const showing = (view: AddView, kept: Kept = 'kept') => ({
  view: signal(view),
  open: vi.fn(),
  close: vi.fn(),
  add: vi.fn((_integrationId: string, _key: string) => Promise.resolve(kept)),
  reset: vi.fn(),
}) satisfies KeyAddModel

const area = (model: KeyAddModel, integrations: readonly Integration[] = [claude]) =>
  render(html`<section aria-labelledby="h"><h2 id="h">구독</h2><${KeyArea} model=${model} integrations=${integrations} /></section>`).container

const fieldOf = (container: Element): HTMLInputElement => {
  const field = container.querySelector<HTMLInputElement>('#key-value')
  if (field === null) throw new Error('no field for the key')
  return field
}
const formOf = (container: Element): HTMLFormElement => {
  const form = container.querySelector('form')
  if (form === null) throw new Error('no form')
  return form
}
const refused: AddFailure = { kind: 'refused', status: 400, code: 'not_a_key', reason: 'not a key', accountId: null, attempts: 1 }

describe('the area where a key is given', () => {
  const steps: ReadonlyArray<readonly [string, AddView]> = [
    ['closed', { kind: 'closed', stored: null }],
    ['closed on an account it made', { kind: 'closed', stored: 'acct_new' }],
    ['open', { kind: 'open', failure: null }],
    ['a key on its way', { kind: 'sending', failure: null }],
    ['a key the server refused', { kind: 'open', failure: refused }],
    ['an account the server left behind', { kind: 'open', failure: { kind: 'refused', status: 503, code: 'account_not_removed', reason: 'left', accountId: 'acct_left', attempts: 2 } }],
    ['a refusal with no code', { kind: 'open', failure: { kind: 'refused', status: 403, code: 'unrecognised', reason: null, accountId: null, attempts: 1 } }],
    ['a key the server failed on with no code', { kind: 'open', failure: { kind: 'unknown', answer: 'server_failed', attempts: 1 } }],
    ['a key with no answer', { kind: 'open', failure: { kind: 'unknown', answer: 'none', attempts: 1 } }],
    ['a key with an answer it cannot read', { kind: 'open', failure: { kind: 'unknown', answer: 'unreadable', attempts: 3 } }],
    ['a key sent again after a refusal', { kind: 'sending', failure: refused }],
    ['an add that found no session', { kind: 'leaving' }],
  ]
  const named = (...names: string[]) => steps.map(([name]) => [name, names.includes(name) ? 1 : 0])
  const count = (selector: string) => steps.map(([name, view]) => [name, area(showing(view)).querySelectorAll(selector).length])
  const withForm = steps.filter(([, view]) => view.kind === 'open' || view.kind === 'sending').map(([name]) => name)

  it.each(steps)('passes the accessibility rules while %s', async (_name, view) => {
    expect(await axe(area(showing(view)))).toHaveNoViolations()
  })

  it('passes the accessibility rules with two subscriptions to pick from', async () => {
    expect(await axe(area(showing({ kind: 'open', failure: null }), [claude, second]))).toHaveNoViolations()
  })

  it('has no field and no form once no subscription takes a key, and still says what came of the key given before', async () => {
    const container = area(showing({ kind: 'open', failure: refused }), [])
    expect([container.querySelector('#key-value'), container.querySelector('form'), container.querySelectorAll('[role=alert]').length]).toEqual([null, null, 1])
    expect(await axe(container)).toHaveNoViolations()
  })

  it('has one line a screen reader reads out in every step, and the field only while the form is open', () => {
    expect(count('[role=status]')).toEqual(named(...steps.map(([name]) => name)))
    expect(count('#key-value')).toEqual(named(...withForm))
  })

  it('says an add that came to nothing where a screen reader announces it', () => {
    expect(count('[role=alert]')).toEqual(named(
      'a key the server refused', 'an account the server left behind', 'a refusal with no code', 'a key the server failed on with no code',
      'a key with no answer', 'a key with an answer it cannot read', 'a key sent again after a refusal',
    ))
  })

  it('takes the key in a field that hides it, that the browser does not complete, and that names what the person reads first', () => {
    const container = area(showing({ kind: 'open', failure: null }))
    const field = fieldOf(container)
    const described = field.getAttribute('aria-describedby') ?? ''
    expect([field.type, field.autocomplete, field.required, container.querySelectorAll(`#${described} li`).length]).toEqual(['password', 'off', true, 4])
  })

  it('carries no key in a submission the page does not handle: the field has no name, and the form posts', () => {
    const container = area(showing({ kind: 'open', failure: null }))
    fieldOf(container).value = key
    const form = formOf(container)
    expect([fieldOf(container).name, form.method, [...new FormData(form).keys()]]).toEqual(['', 'post', ['integration']])
  })

  it('handles the submission itself', async () => {
    const container = area(showing({ kind: 'open', failure: null }))
    fieldOf(container).value = key
    let unhandled = true
    await act(() => { unhandled = fireEvent.submit(formOf(container)) })
    expect(unhandled).toBe(false)
  })

  it('picks nothing for the person once the subscriptions change under the open form', () => {
    const model = showing({ kind: 'open', failure: null })
    const drawn = (integrations: readonly Integration[]) =>
      html`<section aria-labelledby="h"><h2 id="h">구독</h2><${KeyArea} model=${model} integrations=${integrations} /></section>`
    const picked = (container: Element): (readonly [string, boolean])[] =>
      [...container.querySelectorAll<HTMLInputElement>('input[type=radio]')].map((radio) => [radio.value, radio.defaultChecked] as const)
    const shrunk = render(drawn([claude, second]))
    shrunk.rerender(drawn([claude]))
    const afterTwo = picked(shrunk.container)
    cleanup()
    const grown = render(drawn([claude]))
    grown.rerender(drawn([claude, second]))
    expect([afterTwo, picked(grown.container)]).toEqual([[['claude_code', false]], [['claude_code', true], ['claude_team', false]]])
  })

  it('picks the one subscription there is, and none of two', () => {
    const picked = (integrations: readonly Integration[]): boolean[] =>
      [...area(showing({ kind: 'open', failure: null }), integrations).querySelectorAll<HTMLInputElement>('input[type=radio]')].map((radio) => radio.checked)
    expect([picked([claude]), picked([claude, second])]).toEqual([[true], [false, false]])
  })

  it('sends the picked subscription and the key once, and nothing for an empty field', async () => {
    const model = showing({ kind: 'open', failure: null })
    const container = area(model, [claude, second])
    const radio = container.querySelector<HTMLInputElement>('input[type=radio][value=claude_team]')
    if (radio === null) throw new Error('no radio for the second subscription')
    radio.checked = true
    await act(() => { fireEvent.submit(formOf(container)) })
    const empty = model.add.mock.calls.length
    fieldOf(container).value = key
    await act(() => { fireEvent.submit(formOf(container)) })
    expect([empty, model.add.mock.calls]).toEqual([0, [['claude_team', key]]])
  })

  it.each([
    ['keeps the key in the field after an add that kept it', 'kept', key],
    ['empties the field after an add that dropped the key', 'dropped', ''],
  ] as const)('%s', async (_name, kept, left) => {
    const container = area(showing({ kind: 'open', failure: null }, kept))
    fieldOf(container).value = key
    await act(() => { fireEvent.submit(formOf(container)) })
    expect(fieldOf(container).value).toBe(left)
  })

  it('leaves a key the person typed while the first was on its way', async () => {
    const answer = later<Kept>()
    const model = { ...showing({ kind: 'open', failure: null }), add: vi.fn(() => answer.promise) } satisfies KeyAddModel
    const container = area(model)
    fieldOf(container).value = key
    await act(() => { fireEvent.submit(formOf(container)) })
    fieldOf(container).value = 'another-made-up-key'
    await act(async () => {
      answer.give('dropped')
      await answer.promise
    })
    expect(fieldOf(container).value).toBe('another-made-up-key')
  })

  it('sends nothing and closes nothing while a key is on its way', async () => {
    const model = showing({ kind: 'sending', failure: null })
    const container = area(model)
    fieldOf(container).value = key
    await act(() => { fireEvent.submit(formOf(container)) })
    const disabled = [...container.querySelectorAll('button')].map((button) => button.getAttribute('aria-disabled'))
    expect([model.add.mock.calls.length, fieldOf(container).readOnly, disabled]).toEqual([0, true, ['true', 'true', 'true']])
  })

  it('empties the field once no answer came, while the subscriptions are still being read again, and sends nothing on a second press', async () => {
    const reading = later<void>()
    const { send, sent } = answering(['no answer'])
    const model = createKeyAdds({ send, leave: vi.fn(), token: () => 'token-1', refresh: () => reading.promise })
    const container = area(model)
    await act(() => { model.open() })
    fieldOf(container).value = key
    await act(async () => {
      fireEvent.submit(formOf(container))
      await vi.waitFor(() => { expect(model.view.value).toMatchObject({ kind: 'open', failure: { kind: 'unknown' } }) })
    })
    const left = fieldOf(container).value
    await act(() => { fireEvent.submit(formOf(container)) })
    expect([left, sent.length]).toEqual(['', 1])
  })

  it('draws the key nowhere but in its field', async () => {
    const { model } = adding([notAKey()])
    const container = area(model)
    await act(() => { model.open() })
    fieldOf(container).value = key
    await act(async () => {
      fireEvent.submit(formOf(container))
      await vi.waitFor(() => { expect(model.view.value).toMatchObject({ kind: 'open', failure: { kind: 'refused' } }) })
    })
    expect([container.textContent?.includes(key), container.innerHTML.includes(key), fieldOf(container).value]).toEqual([false, false, key])
  })

  it('keeps the same form, with what the person typed and the focus, while a key is on its way and after it was refused', async () => {
    const answer = later<Response>()
    const { model } = adding([answer.promise])
    const container = area(model)
    await act(() => { model.open() })
    const field = fieldOf(container)
    const submit = container.querySelector<HTMLButtonElement>('button[type=submit]')
    if (submit === null) throw new Error('no button that sends the key')
    field.value = key
    submit.focus()
    await act(() => { fireEvent.submit(formOf(container)) })
    const during = [fieldOf(container) === field, document.activeElement === submit]
    await act(async () => {
      answer.give(notAKey())
      await vi.waitFor(() => { expect(model.view.value.kind).toBe('open') })
    })
    expect([during, fieldOf(container) === field, field.value, document.activeElement === submit]).toEqual([[true, true], true, key, true])
  })

  it('moves the focus to the button that opens the form once a key was stored and the form closed', async () => {
    const { model } = adding([stored()])
    const container = area(model)
    await act(() => { model.open() })
    const field = fieldOf(container)
    const submit = container.querySelector<HTMLButtonElement>('button[type=submit]')
    if (submit === null) throw new Error('no button that sends the key')
    field.value = key
    submit.focus()
    await act(async () => {
      fireEvent.submit(formOf(container))
      await vi.waitFor(() => { expect(model.view.value.kind).toBe('closed') })
    })
    expect([container.querySelector('#key-value'), field.value, document.activeElement === container.querySelector('button[aria-controls=key-steps]')])
      .toEqual([null, '', true])
  })

  it('puts a new alert on the page when an add comes to nothing again', async () => {
    const { model } = adding([notAKey(), notAKey()])
    const container = area(model)
    await act(() => { model.open() })
    await act(async () => { await model.add('claude_code', key) })
    const first = container.querySelector('[role=alert]')
    await act(async () => { await model.add('claude_code', key) })
    const second = container.querySelector('[role=alert]')
    expect([first === null, second === null, second === first]).toEqual([false, false, false])
  })

  it('opens and closes with its button, and not while a key is on its way', () => {
    const closed = showing({ kind: 'closed', stored: null })
    const open = showing({ kind: 'open', failure: null })
    const sending = showing({ kind: 'sending', failure: null })
    const toggle = (model: KeyAddModel): HTMLButtonElement => {
      const button = area(model).querySelector<HTMLButtonElement>('button[aria-controls=key-steps]')
      if (button === null) throw new Error('no button that opens the form')
      return button
    }
    fireEvent.click(toggle(closed))
    fireEvent.click(toggle(open))
    const whileSending = toggle(sending)
    expect([closed.open.mock.calls.length, open.close.mock.calls.length, whileSending.getAttribute('aria-disabled'), whileSending.getAttribute('aria-expanded')])
      .toEqual([1, 1, 'true', 'true'])
  })
})
