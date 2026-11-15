// @vitest-environment happy-dom
//
// The invitations panel in each step: the accessibility rules, where an
// alert and a line a screen reader reads out are, which buttons are marked,
// what a press asks of the model, and where the focus goes when the control
// that held it goes away. What a step says is not checked here: that is
// read in a browser.
import { afterEach, describe, expect, it, vi } from 'vitest'
import { signal } from '@preact/signals'
import { act, cleanup, fireEvent, render } from '@testing-library/preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { InvitesPanel } from './invite-rows'
import type { InvitesModel, ListView, Make, Revoke } from './invites'
import type { Invite } from './invites-wire'

const hour = 3_600_000
const expiresAt = 1_763_086_400_000

const invite = (id: string, extra: Partial<Invite> = {}): Invite =>
  ({ id, role: 'member', issuer: { kind: 'admin', userId: 'usr_first' }, expiresAtMs: expiresAt, status: { kind: 'open' }, ...extra })
const readView = (invites: readonly Invite[]): ListView => ({ kind: 'read', forUser: 'usr_first', invites })
const showing = (view: ListView, making: Make = { kind: 'idle' }, revoking: ReadonlyMap<string, Revoke> = new Map()): InvitesModel => ({
  view: signal(view),
  making: signal(making),
  revoking: signal(revoking),
  load: vi.fn(() => Promise.resolve()),
  retry: vi.fn(() => Promise.resolve()),
  make: vi.fn(() => Promise.resolve()),
  forget: vi.fn(),
  revoke: vi.fn(() => Promise.resolve()),
  stop: vi.fn(),
})
const panelOf = (model: InvitesModel) =>
  render(html`<main><h1>내 계정</h1><${InvitesPanel} model=${model} /></main>`).container
const buttonNamed = (container: Element, text: string) =>
  [...container.querySelectorAll<HTMLButtonElement>('button')].find((one) => one.textContent?.trim().startsWith(text))

afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
  vi.restoreAllMocks()
})

describe('the invitations panel', () => {
  const many = [
    invite('inv_open'),
    invite('inv_admin', { role: 'admin', issuer: { kind: 'local_operator' }, expiresAtMs: expiresAt + hour }),
    invite('inv_held', { status: { kind: 'revocation_pending' }, issuer: { kind: 'admin', userId: 'usr_other' } }),
    invite('inv_expired', { status: { kind: 'expired' }, expiresAtMs: expiresAt - 2 * hour }),
    invite('inv_revoked', { status: { kind: 'revoked' }, expiresAtMs: expiresAt - 3 * hour }),
    invite('inv_used', { status: { kind: 'consumed', joined: 'usr_joined' }, expiresAtMs: expiresAt - 4 * hour }),
    invite('inv_new_word', { status: { kind: 'unrecognised' }, expiresAtMs: expiresAt - 5 * hour }),
  ]
  const forbiddenProblem = { kind: 'refused', status: 403, reason: 'only an Admin' } as const
  const unreadList: ListView = { kind: 'failed', forUser: 'usr_first', failure: { problem: { kind: 'unreachable' }, attempts: 2 }, next: 'idle' }
  const notAdmin: ListView = { kind: 'failed', forUser: 'usr_first', failure: { problem: forbiddenProblem, attempts: 1 }, next: 'idle' }
  const madeNow: Make = { kind: 'issued', issued: { id: 'inv_new', role: 'member', expiresAtMs: expiresAt, link: '/accounts/invite#secret' } }
  const steps: ReadonlyArray<readonly [string, InvitesModel]> = [
    ['while the list is read', showing({ kind: 'reading', forUser: 'usr_first', slow: true })],
    ['when the list could not be read', showing(unreadList)],
    ['when the account is not an Admin now', showing(notAdmin)],
    ['with a link just made and a list that could not be read again', showing(unreadList, madeNow)],
    ['with no invitation', showing(readView([]))],
    ['with an invitation in each status', showing(readView(many))],
    ['while a link is made', showing(readView([]), { kind: 'sending', role: 'admin' })],
    ['with an Admin link just made', showing(readView([]), { kind: 'issued', issued: { id: 'inv_new', role: 'admin', expiresAtMs: expiresAt, link: '/accounts/invite#secret_with_no_place_to_break_it_at_all' } })],
    ['with a make refused', showing(readView([]), { kind: 'refused', role: 'member', problem: forbiddenProblem, attempts: 2 })],
    ['with a make whose end it does not know', showing(readView([]), { kind: 'unknown', role: 'member', problem: { kind: 'unreadable' }, attempts: 1 })],
    ['while an invitation is revoked', showing(readView([invite('inv_1')]), { kind: 'idle' }, new Map([['inv_1', { kind: 'sending' }]]))],
    ['with a revoke refused', showing(readView([invite('inv_1')]), { kind: 'idle' }, new Map([['inv_1', { kind: 'refused', problem: { kind: 'refused', status: 404, reason: null }, attempts: 1 }]]))],
    ['with a revoke whose end it does not know', showing(readView([invite('inv_1')]), { kind: 'idle' }, new Map([['inv_1', { kind: 'unknown', problem: { kind: 'unreachable' }, attempts: 1 }]]))],
    ['with an invitation revoked here', showing(readView([invite('inv_1', { status: { kind: 'revoked' } })]), { kind: 'idle' }, new Map([['inv_1', { kind: 'done', before: false }]]))],
    ['with a revoke refused of an invitation closed since', showing(readView([invite('inv_1', { status: { kind: 'revoked' } })]), { kind: 'idle' }, new Map([['inv_1', { kind: 'refused', problem: { kind: 'refused', status: 404, reason: null }, attempts: 1 }]]))],
    ['while the browser leaves', showing({ kind: 'leaving', forUser: 'usr_first' }, { kind: 'leaving' })],
  ]
  const each = <T>(look: (container: Element) => T) => steps.map(([name, model]) => {
    const found = look(panelOf(model))
    cleanup()
    return [name, found]
  })
  const named = (values: Readonly<Record<string, unknown>>, otherwise: unknown) => steps.map(([name]) => [name, name in values ? values[name] : otherwise])

  it.each(steps)('passes the accessibility rules %s', async (_name, model) => {
    expect(await axe(panelOf(model))).toHaveNoViolations()
  })

  it('passes the accessibility rules with the closed invitations shown', async () => {
    const container = panelOf(showing(readView(many)))
    const toggle = container.querySelector<HTMLButtonElement>('[aria-controls="invites-closed"]')
    if (toggle !== null) fireEvent.click(toggle)
    await act(() => undefined)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('says each request that came to nothing where a screen reader announces it', () => {
    expect(each((container) => container.querySelectorAll('[role=alert]').length)).toEqual(named({
      'when the list could not be read': 1,
      'when the account is not an Admin now': 1,
      'with a link just made and a list that could not be read again': 1,
      'with a make refused': 1,
      'with a make whose end it does not know': 1,
      'with a revoke refused': 1,
      'with a revoke whose end it does not know': 1,
    }, 0))
  })

  it('marks the button that makes a link while one is made or shown, or the browser leaves', () => {
    expect(each((container) => container.querySelector('form button[type=submit]')?.getAttribute('aria-disabled') ?? 'none')).toEqual(named({
      'while the list is read': 'none',
      'when the list could not be read': 'none',
      'when the account is not an Admin now': 'none',
      'with a link just made and a list that could not be read again': 'none',
      'while a link is made': 'true',
      'with an Admin link just made': 'true',
      'while the browser leaves': 'none',
    }, 'false'))
  })

  it('lists the open invitations newest first with a revoke button, and the closed ones behind a button', async () => {
    const container = panelOf(showing(readView(many)))
    const rows = (selector: string) => [...container.querySelectorAll(`${selector} > li`)].map((row) => [row.querySelector('h3')?.id, row.querySelector('button') !== null])
    const toggle = container.querySelector<HTMLButtonElement>('[aria-controls="invites-closed"]')
    const closed = container.querySelector('#invites-closed')
    const before = [toggle?.getAttribute('aria-expanded'), closed?.hasAttribute('hidden')]
    if (toggle !== null) fireEvent.click(toggle)
    await act(() => undefined)
    expect([rows('.rows:not(#invites-closed)'), rows('#invites-closed'), before, [toggle?.getAttribute('aria-expanded'), closed?.hasAttribute('hidden')]]).toEqual([
      [['invite-title-inv_admin', true], ['invite-title-inv_open', true], ['invite-title-inv_held', true]],
      [['invite-title-inv_expired', false], ['invite-title-inv_revoked', false], ['invite-title-inv_used', false], ['invite-title-inv_new_word', false]],
      ['false', true],
      ['true', false],
    ])
  })

  it('has no button for closed invitations when there are none', () => {
    const container = panelOf(showing(readView([invite('inv_1')])))
    expect(container.querySelector('[aria-controls="invites-closed"]')).toBeNull()
  })

  it('keeps an invitation revoked here with the open ones, and puts the focus on its title', async () => {
    const view = signal<ListView>(readView([invite('inv_1')]))
    const revoking = signal<ReadonlyMap<string, Revoke>>(new Map())
    const container = panelOf({ ...showing(readView([])), view, revoking })
    container.querySelector<HTMLButtonElement>('#invite-revoke-inv_1')?.focus()
    await act(() => {
      revoking.value = new Map([['inv_1', { kind: 'done', before: false }]])
      view.value = readView([invite('inv_1', { status: { kind: 'revoked' } })])
    })
    const open = [...container.querySelectorAll('.rows:not(#invites-closed) > li h3')].map((one) => one.id)
    expect([open, document.activeElement?.id, container.querySelector('#invites-closed')]).toEqual([['invite-title-inv_1'], 'invite-title-inv_1', null])
  })

  it('keeps a row that closed elsewhere with the open ones while the list is on the page, and puts the focus on its title', async () => {
    const view = signal<ListView>(readView([invite('inv_1'), invite('inv_2')]))
    const container = panelOf({ ...showing(readView([])), view })
    container.querySelector<HTMLButtonElement>('#invite-revoke-inv_1')?.focus()
    await act(() => { view.value = readView([invite('inv_1', { status: { kind: 'expired' } }), invite('inv_2', { status: { kind: 'consumed', joined: 'usr_7' } })]) })
    const open = [...container.querySelectorAll('.rows:not(#invites-closed) > li h3')].map((one) => one.id)
    expect([open, document.activeElement?.id]).toEqual([['invite-title-inv_1', 'invite-title-inv_2'], 'invite-title-inv_1'])
  })

  it('puts the focus on the heading when the row that held it is no longer listed', async () => {
    const view = signal<ListView>(readView([invite('inv_1'), invite('inv_2')]))
    const container = panelOf({ ...showing(readView([])), view })
    container.querySelector<HTMLButtonElement>('#invite-revoke-inv_1')?.focus()
    await act(() => { view.value = readView([invite('inv_2')]) })
    await act(() => Promise.resolve())
    expect(document.activeElement?.id).toBe('invites-heading')
  })

  it('leaves a focus moved elsewhere where it is when a row closes', async () => {
    const view = signal<ListView>(readView([invite('inv_1')]))
    const container = panelOf({ ...showing(readView([])), view })
    const submit = container.querySelector<HTMLButtonElement>('form button[type=submit]')
    submit?.focus()
    await act(() => { view.value = readView([invite('inv_1', { status: { kind: 'revoked' } })]) })
    await act(() => Promise.resolve())
    expect([submit !== null, document.activeElement === submit]).toEqual([true, true])
  })

  it('keeps the role picked when the form comes back with the list', async () => {
    const view = signal<ListView>(readView([]))
    const model = { ...showing(readView([])), view }
    const container = panelOf(model)
    const admin = container.querySelector<HTMLInputElement>('input[name="invite-role"][value="admin"]')
    if (admin !== null) fireEvent.click(admin)
    await act(() => { view.value = unreadList })
    await act(() => { view.value = readView([]) })
    const submit = container.querySelector<HTMLButtonElement>('form button[type=submit]')
    if (submit !== null) fireEvent.click(submit)
    expect(vi.mocked(model.make).mock.calls).toEqual([['admin']])
  })

  it('names every button with what it does and the invitation it is for, and says what a press does', () => {
    const container = panelOf(showing(readView([invite('inv_1')])))
    const button = container.querySelector<HTMLButtonElement>('#invite-revoke-inv_1')
    const line = () => document.getElementById(button?.getAttribute('aria-describedby') ?? '')?.textContent?.trim() ?? null
    const before = line()
    if (button !== null) fireEvent.click(button)
    const submit = container.querySelector('form button[type=submit]')
    const tip = document.getElementById(submit?.getAttribute('aria-describedby') ?? '')?.textContent?.trim() ?? ''
    expect([
      button?.getAttribute('aria-labelledby'), container.querySelector('#invite-back-inv_1')?.getAttribute('aria-labelledby'), before, line() !== '', tip !== '',
    ]).toEqual(['invite-revoke-inv_1 invite-title-inv_1', 'invite-back-inv_1 invite-title-inv_1', '', true, true])
  })

  it('marks the revoke button while its revoke runs or is done, or the browser leaves', () => {
    const revokes: ReadonlyArray<Revoke | undefined> = [
      undefined, { kind: 'sending' }, { kind: 'done', before: true }, { kind: 'leaving' },
      { kind: 'refused', problem: { kind: 'refused', status: 404, reason: null }, attempts: 1 }, { kind: 'unknown', problem: { kind: 'unreachable' }, attempts: 1 },
    ]
    expect(revokes.map((one) => {
      const container = panelOf(showing(readView([invite('inv_1')]), { kind: 'idle' }, one === undefined ? new Map() : new Map([['inv_1', one]])))
      const marked = container.querySelector('#invite-revoke-inv_1')?.getAttribute('aria-disabled')
      cleanup()
      return marked
    })).toEqual(['false', 'true', 'true', 'true', 'false', 'false'])
  })

  it('revokes only on a second press, and a step back puts the focus on the button', async () => {
    const model = showing(readView([invite('inv_1', { status: { kind: 'revocation_pending' } })]))
    const container = panelOf(model)
    const button = container.querySelector<HTMLButtonElement>('#invite-revoke-inv_1')
    if (button === null) throw new Error('no revoke button')
    fireEvent.click(button)
    const asked = vi.mocked(model.revoke).mock.calls.length
    const back = container.querySelector<HTMLButtonElement>('#invite-back-inv_1')
    back?.focus()
    if (back !== null) fireEvent.click(back)
    await act(() => undefined)
    const focus = document.activeElement
    fireEvent.click(button)
    fireEvent.click(button)
    expect([asked, focus === button, container.querySelector('#invite-back-inv_1'), vi.mocked(model.revoke).mock.calls]).toEqual([0, true, null, [['inv_1']]])
  })

  it('asks for nothing on a press of a button that is marked', () => {
    const model = showing(readView([invite('inv_1')]), { kind: 'sending', role: 'member' }, new Map([['inv_1', { kind: 'sending' }]]))
    const container = panelOf(model)
    const submit = container.querySelector<HTMLButtonElement>('form button[type=submit]')
    if (submit !== null) fireEvent.click(submit)
    const revoke = container.querySelector<HTMLButtonElement>('#invite-revoke-inv_1')
    if (revoke !== null) fireEvent.click(revoke)
    if (revoke !== null) fireEvent.click(revoke)
    expect([vi.mocked(model.make).mock.calls.length, vi.mocked(model.revoke).mock.calls.length]).toEqual([0, 0])
  })

  it('makes a link for the role picked, and keeps the pick when the form is drawn again', async () => {
    const making = signal<Make>({ kind: 'idle' })
    const model = { ...showing(readView([])), making }
    const container = panelOf(model)
    const admin = container.querySelector<HTMLInputElement>('input[name="invite-role"][value="admin"]')
    if (admin !== null) fireEvent.click(admin)
    await act(() => { making.value = { kind: 'refused', role: 'admin', problem: { kind: 'refused', status: 400, reason: null }, attempts: 1 } })
    const submit = container.querySelector<HTMLButtonElement>('form button[type=submit]')
    if (submit !== null) fireEvent.click(submit)
    expect([container.querySelector<HTMLInputElement>('input[name="invite-role"]:checked')?.value, vi.mocked(model.make).mock.calls]).toEqual(['admin', [['admin']]])
  })

  it('shows the address of a link made in a field it can be copied from', async () => {
    const writeText = vi.fn(() => Promise.resolve())
    vi.stubGlobal('navigator', { ...navigator, clipboard: { writeText } })
    const container = panelOf(showing(readView([]), madeNow))
    const field = container.querySelector<HTMLTextAreaElement>('#invite-link')
    if (field !== null) fireEvent.focus(field)
    const copy = buttonNamed(container, '복사')
    if (copy !== undefined) fireEvent.click(copy)
    await vi.waitFor(() => { expect(writeText).toHaveBeenCalled() })
    const address = new URL('/accounts/invite#secret', location.origin).href
    expect([field?.value, field?.readOnly, field?.getAttribute('autocomplete'), [field?.selectionStart, field?.selectionEnd], writeText.mock.calls]).toEqual([
      address, true, 'off', [0, address.length], [[address]],
    ])
  })

  it('says so when the link could not be copied, on the same line each time', async () => {
    const said = []
    for (const clipboard of [{ writeText: vi.fn(() => Promise.reject(new Error('not allowed'))) }, null]) {
      vi.stubGlobal('navigator', clipboard === null ? {} : { clipboard })
      const container = panelOf(showing(readView([]), madeNow))
      const line = container.querySelector('[role=group] [role=status]')
      const copy = buttonNamed(container, '복사')
      if (copy !== undefined) fireEvent.click(copy)
      await vi.waitFor(() => { expect(container.querySelector('[role=group] [role=status]')?.textContent).not.toBe('') })
      said.push(container.querySelector('[role=group] [role=status]') === line)
      vi.unstubAllGlobals()
      cleanup()
    }
    expect(said).toEqual([true, true])
  })

  it('puts the focus on the title of the form once the Admin took the link', async () => {
    const making = signal<Make>(madeNow)
    const model = { ...showing(readView([])), making, forget: vi.fn(() => { making.value = { kind: 'idle' } }) }
    const container = panelOf(model)
    const done = buttonNamed(container, '다 옮겼어요')
    done?.focus()
    if (done !== undefined) fireEvent.click(done)
    await act(() => undefined)
    expect([model.forget.mock.calls.length, document.activeElement?.id]).toEqual([1, 'invite-new-title'])
  })

  it('keeps a link made on the page when the list could not be read again, and puts the focus on the heading once it was taken', async () => {
    const making = signal<Make>(madeNow)
    const model = { ...showing(unreadList), making, forget: vi.fn(() => { making.value = { kind: 'idle' } }) }
    const container = panelOf(model)
    const field = container.querySelector('#invite-link')
    const done = buttonNamed(container, '다 옮겼어요')
    done?.focus()
    if (done !== undefined) fireEvent.click(done)
    await act(() => undefined)
    expect([field !== null, document.activeElement?.id]).toEqual([true, 'invites-heading'])
  })

  it('puts the focus on the heading once a retry read the list', async () => {
    const view = signal<ListView>(unreadList)
    const container = panelOf({ ...showing(readView([])), view })
    const retry = buttonNamed(container, '다시 시도')
    retry?.focus()
    await act(() => { view.value = readView([]) })
    expect([retry !== undefined, document.activeElement?.id]).toEqual([true, 'invites-heading'])
  })

  it('makes a new alert for each failure in a row, so a screen reader says the second one too', async () => {
    const failure = (attempts: number): ListView => ({ ...notAdmin, failure: { problem: forbiddenProblem, attempts } })
    const refused = (attempts: number): Make => ({ kind: 'refused', role: 'member', problem: forbiddenProblem, attempts })
    const unknown = (attempts: number): Revoke => ({ kind: 'unknown', problem: { kind: 'unreachable' }, attempts })
    const view = signal(failure(1))
    const making = signal(refused(1))
    const alerts = (container: Element) => [...container.querySelectorAll('[role=alert]')]
    const listed = panelOf({ ...showing(readView([])), view, making })
    const firstAlerts = alerts(listed)
    await act(() => { view.value = failure(2); making.value = refused(2) })
    const secondAlerts = alerts(listed)
    cleanup()
    const revoking = signal<ReadonlyMap<string, Revoke>>(new Map([['inv_1', unknown(1)]]))
    const row = panelOf({ ...showing(readView([invite('inv_1')])), revoking })
    const firstRevoke = alerts(row)
    await act(() => { revoking.value = new Map([['inv_1', unknown(2)]]) })
    const secondRevoke = alerts(row)
    expect([firstAlerts.length, secondAlerts.filter((one) => firstAlerts.includes(one)).length, firstRevoke.length, secondRevoke.filter((one) => firstRevoke.includes(one)).length]).toEqual([2, 0, 1, 0])
  })

  it('keeps the line a screen reader reads out under the heading as one element in every step', async () => {
    const view = signal<ListView>({ kind: 'reading', forUser: 'usr_first', slow: true })
    const container = panelOf({ ...showing(readView([])), view })
    const line = () => container.querySelector('#invites-heading ~ [role=status]')
    const first = line()
    const seen = []
    for (const next of [unreadList, readView(many), { kind: 'leaving', forUser: 'usr_first' } as const]) {
      await act(() => { view.value = next })
      seen.push(line() === first)
    }
    expect(seen).toEqual([true, true, true])
  })
})
