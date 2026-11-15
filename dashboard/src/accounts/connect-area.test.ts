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
import type { ConnectModel, ConnectView, Input, Known } from './connect'
import type { LoginEnd } from './login'
import type { Integration } from './wire'

const integrations: readonly Integration[] = [
  { id: 'claude_code', displayName: 'Claude Code', models: ['claude-sonnet-5'], calls: { kind: 'allowed' } },
  { id: 'codex', displayName: '', models: ['gpt-5.5'], calls: { kind: 'refused', refusal: 'native_tools_reach_other_homes' } },
]
const loginId = 'a'.repeat(64)
const printed = 'Open https://claude.ai/oauth/authorize?code=true&state=x to sign in.\nPaste code here: '
const running = (input: Input, cancelNotTaken = false): ConnectView =>
  ({ kind: 'running', integrationId: 'claude_code', loginId, transcript: printed, input, cancelNotTaken })
const cancelling: ConnectView = { kind: 'cancelling', integrationId: 'claude_code', loginId, transcript: printed, input: 'ready' }
const ended = (end: LoginEnd): ConnectView => ({ kind: 'ended', integrationId: 'claude_code', ended: end })
const detached = (known: Known): ConnectView => ({ kind: 'detached', integrationId: 'claude_code', loginId, known })
const unreachable = { problem: { kind: 'unreachable' }, attempts: 2 } as const

const views: ReadonlyArray<readonly [string, ConnectView]> = [
  ['closed', { kind: 'closed', linked: false }],
  ['closed after a link', { kind: 'closed', linked: true }],
  ['choosing', { kind: 'choosing' }],
  ['starting', { kind: 'starting', integrationId: 'claude_code' }],
  ['running, ready', running('ready')],
  ['running, sending', running('sending')],
  ['running, a reply pending', running('pending')],
  ['running, a reply not taken', running('not_taken')],
  ['running, a cancel not taken', running('ready', true)],
  ['cancelling', cancelling],
  ['checking', { kind: 'checking', integrationId: 'claude_code', loginId }],
  ['detached', detached({ kind: 'runs' })],
  ['detached, its receipt unread', detached({ kind: 'unread', failure: unreachable })],
  ['detached, a cancel taken', detached({ kind: 'cancel_taken' })],
  ['detached, a cancel not taken', detached({ kind: 'cancel_not_taken', problem: { kind: 'unreachable' } })],
  ['ended: failed', ended('failed')],
  ['ended: cancelled', ended('cancelled')],
  ['ended: interrupted', ended('interrupted')],
  ['ended: unrecorded', ended('unrecorded')],
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
    reply: vi.fn((_input: unknown) => Promise.resolve(true)),
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
      'detached, its receipt unread', 'detached, a cancel not taken', 'ended: failed', 'ended: interrupted', 'ended: unrecorded', 'failed',
    ))
  })

  it('has a heading once the steps are open', () => {
    expect(count('h3')).toEqual(except('closed', 'closed after a link'))
    expect(count('button[aria-expanded=true]')).toEqual(except('closed', 'closed after a link'))
  })

  it('lets the steps close only where nothing runs', () => {
    expect(count('button[aria-controls=connect-steps][aria-disabled=true]')).toEqual(except(
      'closed', 'closed after a link', 'choosing', 'ended: failed', 'ended: cancelled', 'ended: interrupted', 'ended: unrecorded', 'failed',
      'detached', 'detached, its receipt unread', 'detached, a cancel taken', 'detached, a cancel not taken',
    ))
  })

  it('offers the subscriptions to pick from when a login can start', () => {
    expect(count('input[type=radio]').map(([name, radios]) => [name, radios === integrations.length ? 1 : 0])).toEqual(named(
      'choosing', 'ended: failed', 'ended: cancelled', 'ended: interrupted', 'ended: unrecorded', 'failed',
    ))
  })

  it('shows what the client printed while a login runs', () => {
    expect(count('pre.transcript')).toEqual(named(
      'running, ready', 'running, sending', 'running, a reply pending', 'running, a reply not taken', 'running, a cancel not taken', 'cancelling',
    ))
  })

  it('marks the reply buttons while the server holds a reply or a cancel is on its way', () => {
    const marked = views.map(([name, view]) => [name, drawn(view).container.querySelectorAll('form.reply button[aria-disabled=true], [role=group] button[aria-disabled=true]').length])
    expect(marked).toEqual(views.map(([name]) => [name, ['running, sending', 'running, a reply pending', 'cancelling'].includes(name) ? 6 : 0]))
  })

  it('offers to check again, to cancel and to close a login the page lost track of', () => {
    for (const name of ['detached', 'detached, its receipt unread', 'detached, a cancel taken', 'detached, a cancel not taken']) {
      const view = views.find(([one]) => one === name)?.[1]
      if (view === undefined) throw new Error(`no step ${name}`)
      const { container, model } = drawn(view)
      const [check, cancel, close] = container.querySelectorAll('#connect-steps button')
      if (check === undefined || cancel === undefined || close === undefined) throw new Error(`no buttons in ${name}`)
      fireEvent.click(check)
      fireEvent.click(cancel)
      fireEvent.click(close)
      expect([name, model.check.mock.calls.length, model.cancel.mock.calls.length, model.close.mock.calls.length]).toEqual([name, 1, 1, 1])
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

  it('sends a code only while the server holds no reply, and empties its field once the server took it', async () => {
    const typed = async (view: ConnectView, taken: boolean) => {
      const { container, model } = drawn(view)
      model.reply.mockImplementation(() => Promise.resolve(taken))
      const field = the<HTMLInputElement>(container, '#connect-code')
      field.value = 'code#1'
      fireEvent.submit(the(container, 'form.reply'))
      await act(() => Promise.resolve())
      const result = [field.value, model.reply.mock.calls]
      cleanup()
      return result
    }
    expect([await typed(running('pending'), true), await typed(running('ready'), false), await typed(running('ready'), true)]).toEqual([
      ['code#1', []], ['code#1', [[{ kind: 'text', text: 'code#1' }]]], ['', [[{ kind: 'text', text: 'code#1' }]]],
    ])
  })

  it('sends a key only while the server holds no reply', () => {
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

  it('cancels a running login, and not again while the cancel is on its way', () => {
    const press = (view: ConnectView): readonly [string | null, number] => {
      const { container, model } = drawn(view)
      const last = [...container.querySelectorAll('#connect-steps button')].at(-1)
      if (last === undefined) throw new Error('no buttons')
      fireEvent.click(last)
      const result = [last.getAttribute('aria-disabled'), model.cancel.mock.calls.length] as const
      cleanup()
      return result
    }
    expect([press(running('ready')), press(cancelling)]).toEqual([['false', 1], ['true', 0]])
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
    const { container, to } = moving(running('ready'))
    the(container, '#connect-code').focus()
    await to({ kind: 'closed', linked: true })
    expect(document.activeElement).toBe(the(container, 'button[aria-controls=connect-steps]'))
  })

  it('stays where the person put it when it did not fall', async () => {
    const { container, to } = moving(running('ready'))
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

  it('stays on the field while a reply is sent and the client takes it', async () => {
    const { container, to } = moving(running('ready'))
    const field = the(container, '#connect-code')
    field.focus()
    await to(running('sending'))
    await to(running('pending'))
    await to(running('ready'))
    expect(document.activeElement).toBe(field)
  })

  it('stays on the cancel button while the cancel is on its way, and goes to the heading once the login stopped', async () => {
    const { container, to } = moving(running('ready'))
    const cancel = [...container.querySelectorAll<HTMLElement>('#connect-steps button')].at(-1)
    if (cancel === undefined) throw new Error('no buttons')
    cancel.focus()
    await to(cancelling)
    const stayed = document.activeElement === cancel
    await to(ended('cancelled'))
    expect([stayed, document.activeElement === container.querySelector('h3')]).toEqual([true, true])
  })

  it('goes to the heading when a reading of a detached login takes its buttons away', async () => {
    const { container, to } = moving(detached({ kind: 'runs' }))
    the(container, '#connect-steps button.primary').focus()
    await to({ kind: 'checking', integrationId: 'claude_code', loginId })
    expect(document.activeElement).toBe(container.querySelector('h3'))
  })
})

describe('the line a screen reader reads out', () => {
  it('stays one element as the steps change, so each new step is read out', async () => {
    const model = counting({ kind: 'closed', linked: false })
    const { container } = render(html`<${ConnectArea} model=${model} integrations=${integrations} />`)
    const line = the(container, '[role=status]')
    const said: string[] = []
    for (const next of [{ kind: 'choosing' }, { kind: 'starting', integrationId: 'claude_code' }, running('ready'), cancelling, ended('cancelled')] as const) {
      await act(() => { model.view.value = next })
      said.push(the(container, '[role=status]') === line ? line.textContent ?? '' : 'another element')
    }
    expect([said.includes('another element'), new Set(said.filter((one) => one !== '')).size]).toEqual([false, 4])
  })
})

describe('the transcript', () => {
  it('keeps its end in view as it grows, and stays where the person scrolled back to', async () => {
    const model = counting(running('ready'))
    const { container } = render(html`<${ConnectArea} model=${model} integrations=${integrations} />`)
    const box = the<HTMLPreElement>(container, 'pre.transcript')
    const size = { height: 500 }
    Object.defineProperty(box, 'scrollHeight', { configurable: true, get: () => size.height })
    Object.defineProperty(box, 'clientHeight', { configurable: true, get: () => 100 })
    await act(() => { model.view.value = { ...running('ready'), transcript: `${printed}more\n` } as ConnectView })
    const followed = box.scrollTop
    box.scrollTop = 0
    fireEvent.scroll(box)
    size.height = 800
    await act(() => { model.view.value = { ...running('ready'), transcript: `${printed}more\nmore\n` } as ConnectView })
    expect([followed, box.scrollTop]).toEqual([500, 0])
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
    const { container } = drawn({ ...cancelling, transcript: text } as ConnectView)
    const transcript = the(container, 'pre.transcript')
    const links = [...transcript.querySelectorAll('a')].map((one) => [one.getAttribute('href'), one.getAttribute('rel'), one.getAttribute('target')])
    expect([transcript.querySelectorAll('img, script').length, links]).toEqual([
      0, [['https://claude.ai/oauth/authorize?code=true&state=x', 'noopener noreferrer', '_blank']],
    ])
  })

  it('loses what a terminal would act on, and keeps tabs and new lines', () => {
    expect(printable('\x1b[1;32mgreen\x1b[0m\tcode\r\n\x07\x1b]0;title\x07done\x7f')).toBe('green\tcode\ndone')
  })

  it('keeps the text between two links a terminal would follow, whichever way they end', () => {
    const linked = (end: string) => `\x1b]8;;https://a.example${end}Open https://claude.ai/x\x1b]8;;${end} to sign in`
    expect([printable(linked('\x1b\\')), printable(linked('\x07'))]).toEqual(['Open https://claude.ai/x to sign in', 'Open https://claude.ai/x to sign in'])
  })

  it('loses the marks that turn the direction of text', () => {
    expect(printable('\u202ecode\u202c \u2066x\u2069')).toBe('code x')
  })
})
