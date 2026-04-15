import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { html } from 'htm/preact'
import { render } from 'preact'
import { act } from 'preact/test-utils'

import { useGlobalShortcut } from './use-global-shortcut'

async function mount(node: HTMLDivElement, vnode: ReturnType<typeof html>): Promise<void> {
  await act(async () => {
    render(vnode, node)
    await Promise.resolve()
  })
}

function Probe({
  match,
  handler,
}: {
  match: (ev: KeyboardEvent) => boolean
  handler: (ev: KeyboardEvent) => void
}) {
  useGlobalShortcut(match, handler)
  return html`<div data-probe />`
}

function dispatchKey(
  key: string,
  init: KeyboardEventInit & { target?: HTMLElement } = {},
): KeyboardEvent {
  const { target, ...evInit } = init
  const ev = new KeyboardEvent('keydown', { key, cancelable: true, bubbles: true, ...evInit })
  ;(target ?? window).dispatchEvent(ev)
  return ev
}

describe('useGlobalShortcut', () => {
  let host: HTMLDivElement

  beforeEach(() => {
    host = document.createElement('div')
    document.body.appendChild(host)
  })

  afterEach(async () => {
    await act(async () => {
      render(null, host)
      await Promise.resolve()
    })
    host.remove()
  })

  it('fires handler and preventDefault when match returns true', async () => {
    const handler = vi.fn()
    await mount(host, html`<${Probe} match=${(ev: KeyboardEvent) => ev.key === 'r'} handler=${handler} />`)
    const ev = dispatchKey('r')
    expect(handler).toHaveBeenCalledOnce()
    expect(ev.defaultPrevented).toBe(true)
  })

  it('skips handler while user is typing in INPUT', async () => {
    const handler = vi.fn()
    await mount(host, html`<${Probe} match=${(ev: KeyboardEvent) => ev.key === 'r'} handler=${handler} />`)
    const input = document.createElement('input')
    document.body.appendChild(input)
    dispatchKey('r', { target: input })
    expect(handler).not.toHaveBeenCalled()
    input.remove()
  })

  it('skips handler when modifier keys are held', async () => {
    const handler = vi.fn()
    await mount(host, html`<${Probe} match=${(ev: KeyboardEvent) => ev.key === 'r'} handler=${handler} />`)
    dispatchKey('r', { metaKey: true })
    dispatchKey('r', { ctrlKey: true })
    dispatchKey('r', { altKey: true })
    expect(handler).not.toHaveBeenCalled()
  })

  it('ignores keys that fail the match predicate', async () => {
    const handler = vi.fn()
    await mount(host, html`<${Probe} match=${(ev: KeyboardEvent) => ev.key === 'r'} handler=${handler} />`)
    const ev = dispatchKey('q')
    expect(handler).not.toHaveBeenCalled()
    expect(ev.defaultPrevented).toBe(false)
  })

  it('removes listener on unmount', async () => {
    const handler = vi.fn()
    await mount(host, html`<${Probe} match=${(ev: KeyboardEvent) => ev.key === 'r'} handler=${handler} />`)
    await act(async () => {
      render(null, host)
      await Promise.resolve()
    })
    dispatchKey('r')
    expect(handler).not.toHaveBeenCalled()
  })

  it('skips handler in contenteditable elements', async () => {
    const handler = vi.fn()
    await mount(host, html`<${Probe} match=${(ev: KeyboardEvent) => ev.key === 'r'} handler=${handler} />`)
    const editable = document.createElement('div')
    editable.contentEditable = 'true'
    document.body.appendChild(editable)
    dispatchKey('r', { target: editable })
    expect(handler).not.toHaveBeenCalled()
    editable.remove()
  })
})
