// @vitest-environment happy-dom
//
// The field of a key in the card of a key account: which cards have it,
// what its button and its form ask of the replacements, what becomes of
// the key in the field, and where the focus goes. What a step says is not
// checked here: that is read in a browser.
import { afterEach, describe, expect, it, vi } from 'vitest'
import { signal } from '@preact/signals'
import { act, cleanup, fireEvent, render } from '@testing-library/preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { AccountList } from './account-rows'
import { createChecks } from './check'
import type { Kept } from './key-add'
import { createRemovals } from './key-remove'
import { createReplacements } from './key-replace'
import type { ReplacementsModel, Replacing } from './key-replace'
import type { Integration, Left, Owned, ProviderAccount, Send } from './wire'

const json = (status: number, body: unknown): Response =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } })

/** A key no provider gave: the server is not asked in these tests. */
const key = 'made-up-key-one'

const nothingSent: Send = () => Promise.reject(new Error('nothing is sent'))
const idle = { send: nothingSent, leave: vi.fn(), token: () => null, refresh: () => Promise.resolve() }

const claude: Integration = { id: 'claude_code', displayName: 'Claude Code', models: ['claude-sonnet-5'], withheld: [], calls: { kind: 'allowed' }, takesLogin: true, takesKey: true }
const keyAccount = (left: Left | null = null): ProviderAccount =>
  ({ id: 'acct_key', integration: 'claude_code', held: { kind: 'key', key: 'readable' }, left })
const loginAccount: ProviderAccount = { id: 'acct_login', integration: 'claude_code', held: { kind: 'login' }, left: null }
const owning = (...accounts: ProviderAccount[]): Owned => ({ accounts, runtimes: [] })

/** A model of replacements that shows `replacing` for the key account and
    counts what it is asked. A key it is given is one the field holds no
    longer. */
const showing = (replacing: Replacing | undefined) => ({
  replacing: signal(new Map(replacing === undefined ? [] : [['acct_key', replacing]])),
  open: vi.fn(),
  close: vi.fn(),
  replace: vi.fn((_accountId: string, _key: string): Promise<Kept> => Promise.resolve('dropped')),
  reset: vi.fn(),
}) satisfies ReplacementsModel

const card = (replacements: ReplacementsModel, owned: Owned = owning(keyAccount())) => render(html`
  <section aria-labelledby="h"><h2 id="h">구독</h2><${AccountList} integrations=${[claude]} owned=${owned}
    checks=${createChecks(idle)} removals=${createRemovals(idle)} replacements=${replacements} /></section>
`).container

function the<T extends Element>(container: Element, selector: string): T {
  const found = container.querySelector<T>(selector)
  if (found === null) throw new Error(`nothing matches ${selector}`)
  return found
}
const toggleOf = (container: Element): HTMLButtonElement => the(container, '#replace-acct_key')
const fieldOf = (container: Element): HTMLInputElement => the(container, '#replace-key-acct_key')
const formOf = (container: Element): HTMLFormElement => the(container, '#replace-steps-acct_key form')

afterEach(() => {
  cleanup()
})

describe('the field of a key in the card of an account', () => {
  const steps: ReadonlyArray<readonly [string, Replacing | undefined]> = [
    ['before any replacement', undefined],
    ['an open field', { kind: 'open', failure: null }],
    ['a key on its way', { kind: 'sending', failure: null }],
    ['a replacement the server did not start', { kind: 'open', failure: { kind: 'refused', status: 409, code: 'account_call_running', reason: 'busy', attempts: 1 } }],
    ['a replacement that left the account with no key', { kind: 'open', failure: { kind: 'refused', status: 503, code: 'key_not_stored', reason: 'not stored', attempts: 2 } }],
    ['a replacement refused with no code', { kind: 'open', failure: { kind: 'refused', status: 403, code: 'unrecognised', reason: null, attempts: 1 } }],
    ['a replacement with no answer', { kind: 'open', failure: { kind: 'unknown', answer: 'none', attempts: 1 } }],
    ['a key on its way after a replacement with no answer', { kind: 'sending', failure: { kind: 'unknown', answer: 'server_failed', attempts: 1 } }],
    ['a replacement that went through', { kind: 'replaced', oldKeysRemoved: true }],
    ['a replacement that left a file of the key before', { kind: 'replaced', oldKeysRemoved: false }],
    ['an account the server does not have, before the list says so', { kind: 'gone' }],
    ['a replacement that found no session', { kind: 'leaving' }],
  ]
  const named = (...names: string[]) => steps.map(([name]) => [name, names.includes(name) ? 1 : 0])
  const count = (selector: string) => steps.map(([name, replacing]) => {
    const found = card(showing(replacing)).querySelectorAll(selector).length
    cleanup()
    return [name, found]
  })

  it.each(steps)('passes the accessibility rules %s', async (_name, replacing) => {
    expect(await axe(card(showing(replacing)))).toHaveNoViolations()
  })

  it('passes the accessibility rules on an account a replacement was left on', async () => {
    expect(await axe(card(showing(undefined), owning(keyAccount({ kind: 'replacement', stage: 'start_given_up' }))))).toHaveNoViolations()
  })

  it('is on a key account, with or without a replacement left on it, and on no other account', () => {
    const buttons = (owned: Owned): number[] => {
      const found = [...card(showing(undefined), owned).querySelectorAll('li.row')].map((row) => row.querySelectorAll('button[id^="replace-"]').length)
      cleanup()
      return found
    }
    expect([
      buttons(owning(keyAccount(), loginAccount)),
      buttons(owning(keyAccount({ kind: 'replacement', stage: 'start_given_up' }))),
      buttons(owning(keyAccount({ kind: 'removal', stage: 'key_not_removed' }))),
    ]).toEqual([[1, 0], [1], [0]])
  })

  it('has the field and its form only while the field is open or a key is on its way', () => {
    const open = [
      'an open field', 'a key on its way', 'a replacement the server did not start', 'a replacement that left the account with no key',
      'a replacement refused with no code', 'a replacement with no answer', 'a key on its way after a replacement with no answer',
    ]
    expect([count('#replace-steps-acct_key form'), count('#replace-key-acct_key')]).toEqual([named(...open), named(...open)])
  })

  it('has one line a screen reader reads out in every step', () => {
    expect(count('#replace-steps-acct_key > [role=status]')).toEqual(named(...steps.map(([name]) => name)))
  })

  it('says a replacement that came to nothing where a screen reader announces it', () => {
    expect(count('#replace-steps-acct_key [role=alert]')).toEqual(named(
      'a replacement the server did not start', 'a replacement that left the account with no key', 'a replacement refused with no code',
      'a replacement with no answer', 'a key on its way after a replacement with no answer',
    ))
  })

  it('holds the key in a field that shows no key, takes no name and is not filled by the browser', () => {
    const container = card(showing({ kind: 'open', failure: null }))
    const field = fieldOf(container)
    expect([field.type, field.hasAttribute('name'), field.autocomplete, formOf(container).method]).toEqual(['password', false, 'off', 'post'])
  })

  it('opens the field when its button is pressed, and closes an open one', () => {
    const closed = showing(undefined)
    fireEvent.click(toggleOf(card(closed)))
    cleanup()
    const open = showing({ kind: 'open', failure: null })
    const container = card(open)
    fireEvent.click(toggleOf(container))
    fireEvent.click(the(container, '#replace-close-acct_key'))
    expect([closed.open.mock.calls, closed.close.mock.calls.length, open.open.mock.calls.length, open.close.mock.calls]).toEqual([[['acct_key']], 0, 0, [['acct_key'], ['acct_key']]])
  })

  it.each([
    ['a key on its way', { kind: 'sending', failure: null }],
    ['a replacement that found no session', { kind: 'leaving' }],
  ] as const)('opens and closes nothing during %s', (_name, replacing) => {
    const replacements = showing(replacing)
    const toggle = toggleOf(card(replacements))
    fireEvent.click(toggle)
    expect([replacements.open.mock.calls.length, replacements.close.mock.calls.length, toggle.getAttribute('aria-disabled')]).toEqual([0, 0, 'true'])
  })

  it('sends the key of the field for the account of the card, and nothing for an empty field', () => {
    const replacements = showing({ kind: 'open', failure: null })
    const container = card(replacements)
    fireEvent.submit(formOf(container))
    const empty = replacements.replace.mock.calls.length
    fieldOf(container).value = key
    fireEvent.submit(formOf(container))
    expect([empty, replacements.replace.mock.calls]).toEqual([0, [['acct_key', key]]])
  })

  it('sends nothing while a key is on its way, and holds the field as it is', () => {
    const replacements = showing({ kind: 'sending', failure: null })
    const container = card(replacements)
    const field = fieldOf(container)
    field.value = key
    fireEvent.submit(formOf(container))
    expect([replacements.replace.mock.calls.length, field.readOnly, the(container, '#replace-send-acct_key').getAttribute('aria-disabled')]).toEqual([0, true, 'true'])
  })

  it.each([
    ['empties the field once the server may hold the key', 'dropped', ''],
    ['keeps the key in the field after the server said it did not take it', 'kept', key],
  ] as const)('%s', async (_name, kept, left) => {
    const replacements = showing({ kind: 'open', failure: null })
    replacements.replace.mockImplementation(() => Promise.resolve(kept))
    const container = card(replacements)
    const field = fieldOf(container)
    field.value = key
    fireEvent.submit(formOf(container))
    await act(() => Promise.resolve())
    expect(field.value).toBe(left)
  })
})

describe('the field of a key over the replacements of the page', () => {
  it('puts the focus in the field once it opened, and back on its button once it closed', async () => {
    const container = card(createReplacements({ ...idle, token: () => 'token-1' }))
    const toggle = toggleOf(container)
    toggle.focus()
    await act(() => { fireEvent.click(toggle) })
    const opened = document.activeElement === fieldOf(container)
    const close = the<HTMLButtonElement>(container, '#replace-close-acct_key')
    close.focus()
    await act(() => { fireEvent.click(close) })
    expect([opened, container.querySelector('#replace-key-acct_key'), document.activeElement === toggle]).toEqual([true, null, true])
  })

  it('leaves a focus the person moved elsewhere where it is once the field closed', async () => {
    const replacements = createReplacements({ ...idle, token: () => 'token-1' })
    const container = card(replacements)
    await act(() => { fireEvent.click(toggleOf(container)) })
    const remove = the<HTMLButtonElement>(container, '#remove-acct_key')
    remove.focus()
    await act(() => { replacements.close('acct_key') })
    expect([container.querySelector('#replace-key-acct_key'), document.activeElement === remove]).toEqual([null, true])
  })

  it('moves a focus that was in the field to the title of the card once the list says a removal was left on the account', async () => {
    const replacements = createReplacements({ ...idle, token: () => 'token-1' })
    const checks = createChecks(idle)
    const removals = createRemovals(idle)
    const drawn = (owned: Owned) => html`
      <section aria-labelledby="h"><h2 id="h">구독</h2><${AccountList} integrations=${[claude]} owned=${owned}
        checks=${checks} removals=${removals} replacements=${replacements} /></section>
    `
    const view = render(drawn(owning(keyAccount())))
    await act(() => { fireEvent.click(toggleOf(view.container)) })
    const inField = document.activeElement === fieldOf(view.container)
    await act(() => { view.rerender(drawn(owning(keyAccount({ kind: 'removal', stage: 'key_not_removed' })))) })
    expect([inField, view.container.querySelector('#replace-acct_key'), document.activeElement === view.container.querySelector('#row-title-acct_key')])
      .toEqual([true, null, true])
  })

  it('sends the key once, takes the field away once the server put the key in place, and puts the focus back on its button', async () => {
    const sent: Array<{ readonly path: string; readonly body: unknown }> = []
    const send: Send = (path, init) => {
      sent.push({ path, body: init.body })
      return Promise.resolve(json(200, { provider_account_id: 'acct_key', old_keys_removed: true }))
    }
    const replacements = createReplacements({ ...idle, send, token: () => 'token-1' })
    const container = card(replacements)
    await act(() => { fireEvent.click(toggleOf(container)) })
    fieldOf(container).value = key
    const sendButton = the<HTMLButtonElement>(container, '#replace-send-acct_key')
    sendButton.focus()
    await act(() => { fireEvent.submit(formOf(container)) })
    await vi.waitFor(() => { expect(replacements.replacing.value.get('acct_key')?.kind).toBe('replaced') })
    await act(() => Promise.resolve())
    expect([sent, container.querySelector('#replace-key-acct_key'), document.activeElement === toggleOf(container)])
      .toEqual([[{ path: '/api/v1/setup/accounts/key/acct_key', body: JSON.stringify({ key }) }], null, true])
  })
})
