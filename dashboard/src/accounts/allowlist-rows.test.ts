// @vitest-environment happy-dom
//
// The allowlist panel in each step: the accessibility rules, where an alert
// and a line a screen reader reads out are, which buttons are marked, what a
// press asks of the model, what the form sends, and where the focus goes when
// the control that held it goes away. What a step says is not checked here:
// that is read in a browser.
import { afterEach, describe, expect, it, vi } from 'vitest'
import { signal } from '@preact/signals'
import { act, cleanup, fireEvent, render } from '@testing-library/preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { AllowlistPanel } from './allowlist-rows'
import type { Add, AllowlistModel, ListView, Remove } from './allowlist'
import type { Entry, Registrable } from './allowlist-wire'

const entry = (id: string, extra: Partial<Entry> = {}): Entry =>
  ({ id, identity: { provider: 'github', userId: 12345 }, registrar: 'usr_first', status: { kind: 'open' }, ...extra })
const readView = (entries: readonly Entry[]): ListView => ({ kind: 'read', forUser: 'usr_first', entries })
const showing = (view: ListView, adding: Add = { kind: 'idle' }, removing: ReadonlyMap<string, Remove> = new Map()): AllowlistModel => ({
  view: signal(view),
  adding: signal(adding),
  removing: signal(removing),
  load: vi.fn(() => Promise.resolve()),
  retry: vi.fn(() => Promise.resolve()),
  add: vi.fn(() => Promise.resolve()),
  remove: vi.fn(() => Promise.resolve()),
  stop: vi.fn(),
})
const panelOf = (model: AllowlistModel) =>
  render(html`<main><h1>내 계정</h1><${AllowlistPanel} model=${model} /></main>`).container
const buttonNamed = (container: Element, text: string) =>
  [...container.querySelectorAll<HTMLButtonElement>('button')].find((one) => one.textContent?.trim().startsWith(text))
const fieldOf = (container: Element) => container.querySelector<HTMLInputElement>('#allowlist-account')
const type = (container: Element, text: string): void => {
  const field = fieldOf(container)
  if (field !== null) fireEvent.input(field, { target: { value: text } })
}
const submit = (container: Element): void => {
  const button = container.querySelector<HTMLButtonElement>('form button[type=submit]')
  if (button !== null) fireEvent.click(button)
}
const pick = (container: Element, provider: string): void => {
  const radio = container.querySelector<HTMLInputElement>(`input[name="allowlist-provider"][value="${provider}"]`)
  if (radio !== null) fireEvent.click(radio)
}
const someone: Registrable = { provider: 'github', userId: 777 }

afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

describe('the allowlist panel', () => {
  const many = [
    entry('reg_open'),
    entry('reg_google', { identity: { provider: 'google', sub: '109876543210987654321' }, registrar: 'usr_other' }),
    entry('reg_held', { status: { kind: 'removal_pending' } }),
    entry('reg_removed', { status: { kind: 'removed' } }),
    entry('reg_used', { status: { kind: 'consumed', joined: 'usr_joined' } }),
    entry('reg_new_word', { status: { kind: 'unrecognised' }, identity: { provider: 'unrecognised' } }),
  ]
  const forbiddenProblem = { kind: 'refused', status: 403, reason: 'only an Admin' } as const
  const unreadList: ListView = { kind: 'failed', forUser: 'usr_first', failure: { problem: { kind: 'unreachable' }, attempts: 2 }, next: 'idle' }
  const notAdmin: ListView = { kind: 'failed', forUser: 'usr_first', failure: { problem: forbiddenProblem, attempts: 1 }, next: 'idle' }
  const steps: ReadonlyArray<readonly [string, AllowlistModel]> = [
    ['while the list is read', showing({ kind: 'reading', forUser: 'usr_first', slow: true })],
    ['when the list could not be read', showing(unreadList)],
    ['when the account is not an Admin now', showing(notAdmin)],
    ['with a registration refused and a list that could not be read again', showing(unreadList, { kind: 'refused', identity: someone, problem: { kind: 'refused', status: 409, reason: 'bound' }, attempts: 1 })],
    ['with no entry', showing(readView([]))],
    ['with an entry in each status', showing(readView(many))],
    ['while an account is registered', showing(readView([]), { kind: 'sending', identity: someone })],
    ['with an account just registered', showing(readView([]), { kind: 'done', identity: someone, registered: { id: 'reg_new', previouslyDeleted: false } })],
    ['with an account of a person deleted before just registered', showing(readView([]), { kind: 'done', identity: someone, registered: { id: 'reg_new', previouslyDeleted: true } })],
    ['with a registration refused', showing(readView([]), { kind: 'refused', identity: someone, problem: forbiddenProblem, attempts: 2 })],
    ['with a registration whose end it does not know', showing(readView([]), { kind: 'unknown', identity: { provider: 'google', sub: 'abc' }, problem: { kind: 'unreadable' }, attempts: 1 })],
    ['while an entry is removed', showing(readView([entry('reg_1')]), { kind: 'idle' }, new Map([['reg_1', { kind: 'sending' }]]))],
    ['with a removal refused', showing(readView([entry('reg_1')]), { kind: 'idle' }, new Map([['reg_1', { kind: 'refused', problem: { kind: 'refused', status: 404, reason: null }, attempts: 1 }]]))],
    ['with a removal whose end it does not know', showing(readView([entry('reg_1')]), { kind: 'idle' }, new Map([['reg_1', { kind: 'unknown', problem: { kind: 'unreachable' }, attempts: 1 }]]))],
    ['with an entry removed here', showing(readView([entry('reg_1', { status: { kind: 'removed' } })]), { kind: 'idle' }, new Map([['reg_1', { kind: 'done', before: false }]]))],
    ['while the browser leaves', showing({ kind: 'leaving', forUser: 'usr_first' }, { kind: 'leaving' })],
    ['while the browser leaves after a registration with the list shown', showing(readView([]), { kind: 'leaving' })],
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

  it('passes the accessibility rules with the closed entries shown, and with an account typed that is not one', async () => {
    const container = panelOf(showing(readView(many)))
    const toggle = container.querySelector<HTMLButtonElement>('[aria-controls="allowlist-closed"]')
    if (toggle !== null) fireEvent.click(toggle)
    type(container, 'octocat')
    submit(container)
    await act(() => undefined)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('says each request that came to nothing where a screen reader announces it', () => {
    expect(each((container) => container.querySelectorAll('[role=alert]').length)).toEqual(named({
      'when the list could not be read': 1,
      'when the account is not an Admin now': 1,
      'with a registration refused and a list that could not be read again': 2,
      'with a registration refused': 1,
      'with a registration whose end it does not know': 1,
      'with a removal refused': 1,
      'with a removal whose end it does not know': 1,
    }, 0))
  })

  it('marks the button that registers while a registration runs, or the browser leaves', () => {
    expect(each((container) => container.querySelector('form button[type=submit]')?.getAttribute('aria-disabled') ?? 'none')).toEqual(named({
      'while the list is read': 'none',
      'when the list could not be read': 'none',
      'when the account is not an Admin now': 'none',
      'with a registration refused and a list that could not be read again': 'none',
      'while an account is registered': 'true',
      'while the browser leaves': 'none',
      'while the browser leaves after a registration with the list shown': 'true',
    }, 'false'))
  })

  it('lists the open entries in the order of the server with a remove button, and the closed ones behind a button', async () => {
    const container = panelOf(showing(readView(many)))
    const rows = (selector: string) => [...container.querySelectorAll(`${selector} > li`)].map((row) => [row.querySelector('h3')?.id, row.querySelector('button') !== null])
    const toggle = container.querySelector<HTMLButtonElement>('[aria-controls="allowlist-closed"]')
    const closed = container.querySelector('#allowlist-closed')
    const before = [toggle?.getAttribute('aria-expanded'), closed?.hasAttribute('hidden')]
    if (toggle !== null) fireEvent.click(toggle)
    await act(() => undefined)
    expect([rows('.rows:not(#allowlist-closed)'), rows('#allowlist-closed'), before, [toggle?.getAttribute('aria-expanded'), closed?.hasAttribute('hidden')]]).toEqual([
      [['allowlist-title-reg_open', true], ['allowlist-title-reg_google', true], ['allowlist-title-reg_held', true]],
      [['allowlist-title-reg_removed', false], ['allowlist-title-reg_used', false], ['allowlist-title-reg_new_word', false]],
      ['false', true],
      ['true', false],
    ])
  })

  it('has no button for closed entries when there are none', () => {
    const container = panelOf(showing(readView([entry('reg_1')])))
    expect(container.querySelector('[aria-controls="allowlist-closed"]')).toBeNull()
  })

  it('keeps an entry removed here with the open ones, and puts the focus on its title', async () => {
    const view = signal<ListView>(readView([entry('reg_1')]))
    const removing = signal<ReadonlyMap<string, Remove>>(new Map())
    const container = panelOf({ ...showing(readView([])), view, removing })
    container.querySelector<HTMLButtonElement>('#allowlist-remove-reg_1')?.focus()
    await act(() => {
      removing.value = new Map([['reg_1', { kind: 'done', before: false }]])
      view.value = readView([entry('reg_1', { status: { kind: 'removed' } })])
    })
    const open = [...container.querySelectorAll('.rows:not(#allowlist-closed) > li h3')].map((one) => one.id)
    expect([open, document.activeElement?.id, container.querySelector('#allowlist-closed')]).toEqual([['allowlist-title-reg_1'], 'allowlist-title-reg_1', null])
  })

  it('puts the focus on the heading when the row that held it is no longer listed', async () => {
    const view = signal<ListView>(readView([entry('reg_1'), entry('reg_2')]))
    const container = panelOf({ ...showing(readView([])), view })
    container.querySelector<HTMLButtonElement>('#allowlist-remove-reg_1')?.focus()
    await act(() => { view.value = readView([entry('reg_2')]) })
    await act(() => Promise.resolve())
    expect(document.activeElement?.id).toBe('allowlist-heading')
  })

  it('names every button with what it does and the entry it is for, and says what a press does', () => {
    const container = panelOf(showing(readView([entry('reg_1')])))
    const button = container.querySelector<HTMLButtonElement>('#allowlist-remove-reg_1')
    const line = () => document.getElementById(button?.getAttribute('aria-describedby') ?? '')?.textContent?.trim() ?? null
    const before = line()
    if (button !== null) fireEvent.click(button)
    const tipOf = (selector: string) => document.getElementById(container.querySelector(selector)?.getAttribute('aria-describedby') ?? '')?.textContent?.trim() ?? ''
    expect([
      button?.getAttribute('aria-labelledby'), container.querySelector('#allowlist-back-reg_1')?.getAttribute('aria-labelledby'), before, line() !== '',
      tipOf('form button[type=submit]') !== '', tipOf('#allowlist-account') !== '',
    ]).toEqual(['allowlist-remove-reg_1 allowlist-title-reg_1', 'allowlist-back-reg_1 allowlist-title-reg_1', '', true, true, true])
  })

  it('marks the remove button while its removal runs or is done, or the browser leaves', () => {
    const removals: ReadonlyArray<Remove | undefined> = [
      undefined, { kind: 'sending' }, { kind: 'done', before: true }, { kind: 'leaving' },
      { kind: 'refused', problem: { kind: 'refused', status: 404, reason: null }, attempts: 1 }, { kind: 'unknown', problem: { kind: 'unreachable' }, attempts: 1 },
    ]
    expect(removals.map((one) => {
      const container = panelOf(showing(readView([entry('reg_1')]), { kind: 'idle' }, one === undefined ? new Map() : new Map([['reg_1', one]])))
      const marked = container.querySelector('#allowlist-remove-reg_1')?.getAttribute('aria-disabled')
      cleanup()
      return marked
    })).toEqual(['false', 'true', 'true', 'true', 'false', 'false'])
  })

  it('removes only on a second press, and a step back puts the focus on the button', async () => {
    const model = showing(readView([entry('reg_1', { status: { kind: 'removal_pending' } })]))
    const container = panelOf(model)
    const button = container.querySelector<HTMLButtonElement>('#allowlist-remove-reg_1')
    if (button === null) throw new Error('no remove button')
    fireEvent.click(button)
    const asked = vi.mocked(model.remove).mock.calls.length
    const back = container.querySelector<HTMLButtonElement>('#allowlist-back-reg_1')
    back?.focus()
    if (back !== null) fireEvent.click(back)
    await act(() => undefined)
    const focus = document.activeElement
    fireEvent.click(button)
    fireEvent.click(button)
    expect([asked, focus === button, container.querySelector('#allowlist-back-reg_1'), vi.mocked(model.remove).mock.calls]).toEqual([0, true, null, [['reg_1']]])
  })

  it('asks for nothing on a press of a button that is marked', () => {
    const model = showing(readView([entry('reg_1')]), { kind: 'sending', identity: someone }, new Map([['reg_1', { kind: 'sending' }]]))
    const container = panelOf(model)
    type(container, '777')
    submit(container)
    const remove = container.querySelector<HTMLButtonElement>('#allowlist-remove-reg_1')
    if (remove !== null) fireEvent.click(remove)
    if (remove !== null) fireEvent.click(remove)
    expect([vi.mocked(model.add).mock.calls.length, vi.mocked(model.remove).mock.calls.length]).toEqual([0, 0])
  })

  it('registers the account typed for the way of signing in picked', () => {
    const model = showing(readView([]))
    const container = panelOf(model)
    type(container, ' 777 ')
    submit(container)
    pick(container, 'google')
    type(container, '109876543210987654321')
    submit(container)
    expect(vi.mocked(model.add).mock.calls).toEqual([[someone], [{ provider: 'google', sub: '109876543210987654321' }]])
  })

  it('sends nothing for what is not an account the server takes, says so, and puts the focus on the field', async () => {
    const model = showing(readView([]))
    const container = panelOf(model)
    const seen = []
    for (const text of ['', 'octocat']) {
      type(container, text)
      submit(container)
      await act(() => undefined)
      const described = (fieldOf(container)?.getAttribute('aria-describedby') ?? '').split(' ').map((id) => document.getElementById(id)?.querySelector('[role=alert]') !== null)
      seen.push([container.querySelectorAll('[role=alert]').length, fieldOf(container)?.getAttribute('aria-invalid'), document.activeElement?.id, described])
    }
    type(container, '7')
    const fixing = [container.querySelectorAll('[role=alert]').length, fieldOf(container)?.getAttribute('aria-invalid')]
    submit(container)
    type(container, 'octocat')
    submit(container)
    await act(() => undefined)
    pick(container, 'google')
    await act(() => undefined)
    const picked = [container.querySelectorAll('[role=alert]').length, fieldOf(container)?.getAttribute('aria-invalid')]
    expect([seen, fixing, picked, vi.mocked(model.add).mock.calls]).toEqual([
      [[1, 'true', 'allowlist-account', [false, true]], [1, 'true', 'allowlist-account', [false, true]]], [0, 'false'], [0, 'false'], [[{ provider: 'github', userId: 7 }]],
    ])
  })

  it('makes a new alert for each mistake in a row, so a screen reader says the second one too', async () => {
    const container = panelOf(showing(readView([])))
    submit(container)
    await act(() => undefined)
    const firstAlert = container.querySelector('[role=alert]')
    submit(container)
    await act(() => undefined)
    const secondAlert = container.querySelector('[role=alert]')
    expect([firstAlert !== null, secondAlert !== null, firstAlert === secondAlert]).toEqual([true, true, false])
  })

  it('asks for numbers on a GitHub account and for text on a Google one', async () => {
    const container = panelOf(showing(readView([])))
    const github = fieldOf(container)?.getAttribute('inputmode')
    pick(container, 'google')
    await act(() => undefined)
    expect([github, fieldOf(container)?.getAttribute('inputmode')]).toEqual(['numeric', 'text'])
  })

  it('empties the field once the server put the account on the list, and keeps it when the server refused', async () => {
    const adding = signal<Add>({ kind: 'idle' })
    const answers: Add['kind'][] = ['refused', 'done']
    const model: AllowlistModel = {
      ...showing(readView([])),
      adding,
      add: vi.fn((identity: Registrable) => {
        adding.value = answers.shift() === 'refused'
          ? { kind: 'refused', identity, problem: { kind: 'refused', status: 409, reason: null }, attempts: 1 }
          : { kind: 'done', identity, registered: { id: 'reg_new', previouslyDeleted: false } }
        return Promise.resolve()
      }),
    }
    const container = panelOf(model)
    type(container, '777')
    submit(container)
    await act(() => Promise.resolve())
    const refused = fieldOf(container)?.value
    submit(container)
    await act(() => Promise.resolve())
    expect([refused, fieldOf(container)?.value]).toEqual(['777', ''])
  })

  it('keeps what the Admin typed while a registration was sent when the server put the account sent on the list', async () => {
    const adding = signal<Add>({ kind: 'idle' })
    let answer: () => void = () => undefined
    const model: AllowlistModel = {
      ...showing(readView([])),
      adding,
      add: vi.fn((identity: Registrable) => {
        adding.value = { kind: 'sending', identity }
        return new Promise<void>((resolve) => {
          answer = () => {
            adding.value = { kind: 'done', identity, registered: { id: 'reg_new', previouslyDeleted: false } }
            resolve()
          }
        })
      }),
    }
    const container = panelOf(model)
    type(container, '777')
    submit(container)
    await act(() => undefined)
    type(container, '888')
    await act(() => { answer() })
    await act(() => Promise.resolve())
    expect(fieldOf(container)?.value).toBe('888')
  })

  it('makes a new alert when a registration of another account is refused as many times', async () => {
    const refused = (userId: number): Add => ({ kind: 'refused', identity: { provider: 'github', userId }, problem: { kind: 'refused', status: 409, reason: null }, attempts: 1 })
    const adding = signal(refused(777))
    const container = panelOf({ ...showing(readView([])), adding })
    const before = container.querySelector('[role=alert]')
    await act(() => { adding.value = refused(888) })
    expect([before !== null, container.querySelector('[role=alert]') === before]).toEqual([true, false])
  })

  it('keeps the way of signing in picked and what was typed when the form comes back with the list', async () => {
    const view = signal<ListView>(readView([]))
    const model = { ...showing(readView([])), view }
    const container = panelOf(model)
    pick(container, 'google')
    type(container, 'abc')
    await act(() => { view.value = unreadList })
    await act(() => { view.value = readView([]) })
    submit(container)
    expect([fieldOf(container)?.value, vi.mocked(model.add).mock.calls]).toEqual(['abc', [[{ provider: 'google', sub: 'abc' }]]])
  })

  it('puts the focus on the heading when a list that could not be read again takes the form away', async () => {
    const view = signal<ListView>(readView([]))
    const container = panelOf({ ...showing(readView([])), view })
    fieldOf(container)?.focus()
    await act(() => { view.value = unreadList })
    expect(document.activeElement?.id).toBe('allowlist-heading')
  })

  it('puts the focus on the heading once a retry read the list', async () => {
    const view = signal<ListView>(unreadList)
    const container = panelOf({ ...showing(readView([])), view })
    const retry = buttonNamed(container, '다시 시도')
    retry?.focus()
    await act(() => { view.value = readView([]) })
    expect([retry !== undefined, document.activeElement?.id]).toEqual([true, 'allowlist-heading'])
  })

  it('makes a new alert for each failure in a row, so a screen reader says the second one too', async () => {
    const failure = (attempts: number): ListView => ({ ...notAdmin, failure: { problem: forbiddenProblem, attempts } })
    const refused = (attempts: number): Add => ({ kind: 'refused', identity: someone, problem: forbiddenProblem, attempts })
    const unknown = (attempts: number): Remove => ({ kind: 'unknown', problem: { kind: 'unreachable' }, attempts })
    const view = signal(failure(1))
    const adding = signal(refused(1))
    const alerts = (container: Element) => [...container.querySelectorAll('[role=alert]')]
    const listed = panelOf({ ...showing(readView([])), view, adding })
    const firstAlerts = alerts(listed)
    await act(() => { view.value = failure(2); adding.value = refused(2) })
    const secondAlerts = alerts(listed)
    cleanup()
    const removing = signal<ReadonlyMap<string, Remove>>(new Map([['reg_1', unknown(1)]]))
    const row = panelOf({ ...showing(readView([entry('reg_1')])), removing })
    const firstRemove = alerts(row)
    await act(() => { removing.value = new Map([['reg_1', unknown(2)]]) })
    const secondRemove = alerts(row)
    expect([firstAlerts.length, secondAlerts.filter((one) => firstAlerts.includes(one)).length, firstRemove.length, secondRemove.filter((one) => firstRemove.includes(one)).length]).toEqual([2, 0, 1, 0])
  })

  it('keeps the line a screen reader reads out under the heading as one element in every step', async () => {
    const view = signal<ListView>({ kind: 'reading', forUser: 'usr_first', slow: true })
    const container = panelOf({ ...showing(readView([])), view })
    const line = () => container.querySelector('#allowlist-heading ~ [role=status]')
    const first = line()
    const seen = []
    for (const next of [unreadList, readView(many), { kind: 'leaving', forUser: 'usr_first' } as const]) {
      await act(() => { view.value = next })
      seen.push(line() === first)
    }
    expect(seen).toEqual([true, true, true])
  })
})
