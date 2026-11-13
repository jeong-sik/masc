// @vitest-environment happy-dom
//
// The area where a person connects a subscription: that each step passes the
// accessibility rules, what each step lets a person press, where the focus
// goes as the steps change, and that what a client printed stays text. What
// a step says and where it puts things is not checked here: that is read in a
// browser.
import { afterEach, describe, expect, it, vi } from 'vitest'
import { signal } from '@preact/signals'
import { act, cleanup, fireEvent, render } from '@testing-library/preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { ConnectArea, printable } from './connect-area'
import type { ConnectModel, ConnectView, Ended } from './connect'
import type { Integration } from './wire'

const integrations: readonly Integration[] = [
  { id: 'claude_code', displayName: 'Claude Code', models: ['claude-sonnet-5'], calls: { kind: 'allowed' } },
  { id: 'codex', displayName: '', models: ['gpt-5.5'], calls: { kind: 'refused', refusal: 'native_tools_reach_other_homes' } },
]
const loginId = 'a'.repeat(64)
const printed = 'Open https://claude.ai/oauth/authorize?code=true&state=x to sign in.\nPaste code here: '
const running = (input: 'not_asked' | 'asked' | 'sending' | 'not_taken', cancelNotTaken = false): ConnectView =>
  ({ kind: 'running', integrationId: 'claude_code', loginId, transcript: printed, input, cancelNotTaken })
const ended = (end: Ended): ConnectView => ({ kind: 'ended', integrationId: 'claude_code', ended: end })
const unreachable = { problem: { kind: 'unreachable' }, attempts: 2 } as const

const views: ReadonlyArray<readonly [string, ConnectView]> = [
  ['closed', { kind: 'closed', linked: false }],
  ['closed after a link', { kind: 'closed', linked: true }],
  ['choosing', { kind: 'choosing' }],
  ['starting', { kind: 'starting', integrationId: 'claude_code' }],
  ['running, not asked', running('not_asked')],
  ['running, asked', running('asked')],
  ['running, sending', running('sending')],
  ['running, a reply not taken', running('not_taken')],
  ['running, a cancel not taken', running('asked', true)],
  ['cancelling', { kind: 'cancelling', integrationId: 'claude_code', loginId, transcript: printed }],
  ['checking', { kind: 'checking', integrationId: 'claude_code', loginId }],
  ['detached', { kind: 'detached', integrationId: 'claude_code', loginId, failure: null }],
  ['detached, its receipt unread', { kind: 'detached', integrationId: 'claude_code', loginId, failure: unreachable }],
  ['ended: failed', ended('failed')],
  ['ended: cancelled', ended('cancelled')],
  ['ended: interrupted', ended('interrupted')],
  ['ended: unrecorded', ended('unrecorded')],
  ['ended: unknown', ended('unknown')],
  ['failed', { kind: 'failed', integrationId: 'claude_code', failure: unreachable }],
  ['leaving', { kind: 'leaving' }],
]
const names = views.map(([name]) => name)
const named = (...picked: string[]) => views.map(([name]) => [name, picked.includes(name) ? 1 : 0])
const except = (...left: string[]) => named(...names.filter((name) => !left.includes(name)))

/** A model that only counts what it is asked, over a view the test moves. */
function counting(view: ConnectView) {
  return {
    view: signal(view),
    open: vi.fn(),
    close: vi.fn(),
    start: vi.fn((_integrationId: string) => Promise.resolve()),
    reply: vi.fn((_input: unknown) => Promise.resolve()),
    cancel: vi.fn(() => Promise.resolve()),
    check: vi.fn(() => Promise.resolve()),
    reset: vi.fn(),
  } satisfies ConnectModel
}

const drawn = (view: ConnectView) => {
  const model = counting(view)
  return { container: render(html`<${ConnectArea} model=${model} integrations=${integrations} />`).container, model }
}
const count = (selector: string) => views.map(([name, view]) => [name, drawn(view).container.querySelectorAll(selector).length])

/** The one element of `container` that `selector` names. */
function the<T extends Element = HTMLElement>(container: Element, selector: string): T {
  const found = container.querySelectorAll<T>(selector)
  const [first] = found
  if (first === undefined || found.length !== 1) throw new Error(`${found.length} elements match ${selector}`)
  return first
}

afterEach(() => {
  cleanup()
})

describe('each step', () => {
  it.each(views)('passes the accessibility rules while %s', async (_name, view) => {
    expect(await axe(drawn(view).container)).toHaveNoViolations()
  })

  it('has one line a screen reader reads out', () => {
    expect(count('[role=status]')).toEqual(named(...names))
  })

  it('says a problem where a screen reader announces it only when the login failed or ended without the person', () => {
    expect(count('[role=alert]')).toEqual(named(
      'detached, its receipt unread', 'ended: failed', 'ended: interrupted', 'ended: unrecorded', 'ended: unknown', 'failed',
    ))
  })

  it('has a heading once the steps are open', () => {
    expect(count('h3')).toEqual(except('closed', 'closed after a link'))
    expect(count('button[aria-expanded=true]')).toEqual(except('closed', 'closed after a link'))
  })

  it('lets the steps close only where nothing runs', () => {
    expect(count('button[aria-controls=connect-steps][aria-disabled=true]')).toEqual(except(
      'closed', 'closed after a link', 'choosing', 'ended: failed', 'ended: cancelled', 'ended: interrupted', 'ended: unrecorded',
      'ended: unknown', 'failed',
    ))
  })

  it('offers the subscriptions to pick from when a login can start', () => {
    expect(count('input[type=radio]').map(([name, radios]) => [name, radios === integrations.length ? 1 : 0])).toEqual(named(
      'choosing', 'ended: failed', 'ended: cancelled', 'ended: interrupted', 'ended: unrecorded', 'ended: unknown', 'failed',
    ))
  })

  it('shows what the client printed while a login runs', () => {
    expect(count('pre.transcript')).toEqual(named(
      'running, not asked', 'running, asked', 'running, sending', 'running, a reply not taken', 'running, a cancel not taken', 'cancelling',
    ))
  })

  it('marks the reply buttons while the client is not asking', () => {
    const marked = views.map(([name, view]) => [name, drawn(view).container.querySelectorAll('form.reply button[aria-disabled=true], [role=group] button[aria-disabled=true]').length])
    expect(marked).toEqual(views.map(([name]) => [name, name === 'running, not asked' || name === 'running, sending' ? 6 : 0]))
  })

  it('offers to check again and to cancel a login the page lost track of', () => {
    for (const name of ['detached', 'detached, its receipt unread']) {
      const view = views.find(([one]) => one === name)?.[1]
      if (view === undefined) throw new Error(`no step ${name}`)
      const { container, model } = drawn(view)
      const [check, cancel] = container.querySelectorAll('#connect-steps button')
      if (check === undefined || cancel === undefined) throw new Error(`no buttons in ${name}`)
      fireEvent.click(check)
      fireEvent.click(cancel)
      expect([name, model.check.mock.calls.length, model.cancel.mock.calls.length]).toEqual([name, 1, 1])
      cleanup()
    }
  })
})

describe('the controls', () => {
  it('opens the steps when closed, and closes them when they are open', () => {
    const closed = drawn({ kind: 'closed', linked: false })
    fireEvent.click(the(closed.container, 'button[aria-controls=connect-steps]'))
    cleanup()
    const choosing = drawn({ kind: 'choosing' })
    fireEvent.click(the(choosing.container, 'button[aria-controls=connect-steps]'))
    expect([closed.model.open.mock.calls.length, choosing.model.close.mock.calls.length]).toEqual([1, 1])
  })

  it('starts a login of the subscription picked, and of none when none is picked', () => {
    const { container, model } = drawn({ kind: 'choosing' })
    const form = the<HTMLFormElement>(container, 'form.connect-form')
    fireEvent.submit(form)
    const radio = container.querySelector<HTMLInputElement>('input[value=codex]')
    if (radio === null) throw new Error('codex is not offered')
    radio.checked = true
    fireEvent.submit(form)
    expect(model.start.mock.calls).toEqual([['codex']])
  })

  it('sends a code and empties its field only while the client asks', () => {
    const notAsked = drawn(running('not_asked'))
    const field = the<HTMLInputElement>(notAsked.container, '#connect-code')
    field.value = 'code#1'
    fireEvent.submit(the(notAsked.container, 'form.reply'))
    const kept = field.value
    cleanup()
    const asked = drawn(running('asked'))
    const askedField = the<HTMLInputElement>(asked.container, '#connect-code')
    askedField.value = 'code#1'
    fireEvent.submit(the(asked.container, 'form.reply'))
    expect([kept, notAsked.model.reply.mock.calls.length, askedField.value, asked.model.reply.mock.calls]).toEqual([
      'code#1', 0, '', [[{ kind: 'text', text: 'code#1' }]],
    ])
  })

  it('sends a key only while the client asks', () => {
    const press = (view: ConnectView) => {
      const { container, model } = drawn(view)
      for (const button of container.querySelectorAll('[role=group] button')) fireEvent.click(button)
      const calls = model.reply.mock.calls
      cleanup()
      return calls
    }
    expect([press(running('sending')), press(running('not_taken'))]).toEqual([[], [
      [{ kind: 'key', key: 'enter' }], [{ kind: 'key', key: 'up' }], [{ kind: 'key', key: 'down' }],
      [{ kind: 'key', key: 'tab' }], [{ kind: 'key', key: 'eof' }],
    ]])
  })

  it('cancels a running login', () => {
    const { container, model } = drawn(running('not_asked'))
    const buttons = [...container.querySelectorAll('#connect-steps button')]
    const last = buttons.at(-1)
    if (last === undefined) throw new Error('no buttons')
    fireEvent.click(last)
    expect(model.cancel.mock.calls.length).toBe(1)
  })
})

describe('the focus', () => {
  /** The area over a view the test moves, and a way to move it. */
  function moving(view: ConnectView) {
    const model = counting(view)
    const { container } = render(html`<${ConnectArea} model=${model} integrations=${integrations} />`)
    const to = async (next: ConnectView): Promise<void> => { await act(() => { model.view.value = next }) }
    return { container, to }
  }

  it('goes to the heading of the steps when a step takes the pressed button away', async () => {
    const { container, to } = moving({ kind: 'choosing' })
    the(container, 'button[type=submit]').focus()
    await to({ kind: 'starting', integrationId: 'claude_code' })
    expect(document.activeElement).toBe(container.querySelector('h3'))
  })

  it('goes back to the button that opens the steps once they close under the pressed button', async () => {
    const { container, to } = moving(running('asked'))
    the(container, '#connect-code').focus()
    await to({ kind: 'closed', linked: true })
    expect(document.activeElement).toBe(the(container, 'button[aria-controls=connect-steps]'))
  })

  it('stays where the person put it when it did not fall', async () => {
    const { container, to } = moving(running('asked'))
    const elsewhere = document.body.appendChild(document.createElement('button'))
    try {
      elsewhere.focus()
      await to({ kind: 'closed', linked: true })
      const stayed = document.activeElement === elsewhere
      const toggle = the(container, 'button[aria-controls=connect-steps]')
      toggle.focus()
      await to({ kind: 'choosing' })
      expect([stayed, document.activeElement === toggle]).toEqual([true, true])
    } finally {
      elsewhere.remove()
    }
  })

  it('stays on the field while a reply is sent and the client asks again', async () => {
    const { container, to } = moving(running('asked'))
    const field = the(container, '#connect-code')
    field.focus()
    await to(running('sending'))
    await to(running('not_asked'))
    await to(running('asked'))
    expect(document.activeElement).toBe(field)
  })
})

describe('what a client printed', () => {
  it('stays text: no element comes of it but a link to an https address', () => {
    const text = [
      '<img src=x onerror="window.hacked = 1"><script>window.hacked = 1</script>',
      'javascript:alert(1) http://plain.example data:text/html,x',
      '\x1b]8;;https://elsewhere.example\x07a link a terminal would follow\x1b]8;;\x07',
      'Open https://claude.ai/oauth/authorize?code=true&state=x',
    ].join('\n')
    const { container } = drawn({ kind: 'cancelling', integrationId: 'claude_code', loginId, transcript: text })
    const transcript = the(container, 'pre.transcript')
    const links = [...transcript.querySelectorAll('a')].map((one) => [one.getAttribute('href'), one.getAttribute('rel'), one.getAttribute('target')])
    expect([transcript.querySelectorAll('img, script').length, links]).toEqual([
      0, [['https://claude.ai/oauth/authorize?code=true&state=x', 'noopener noreferrer', '_blank']],
    ])
  })

  it('loses what a terminal would act on, and keeps tabs and new lines', () => {
    expect(printable('\x1b[1;32mgreen\x1b[0m\tcode\r\n\x07\x1b]0;title\x07done\x7f')).toBe('green\tcode\ndone')
  })
})
