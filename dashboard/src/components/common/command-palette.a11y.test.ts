// @vitest-environment happy-dom
//
// jest-axe coverage for the cmdk palette dialog. The palette is first-party
// markup now (prototype palette.jsx DOM), so the dialog itself — not a web
// component wrapper — is what must axe-clean.
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { signal } from '@preact/signals'

vi.mock('../../router', () => ({
  navigate: () => {},
  navigateToPost: () => {},
  route: signal({ tab: 'overview', params: {}, postId: null }),
}))
vi.mock('../../lib/global-shortcut-manager', () => ({
  globalShortcutManager: { register: () => () => {} },
}))

import { CommandPalette } from './command-palette'

describe('CommandPalette a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  it('closed palette renders nothing', async () => {
    render(html`<${CommandPalette} />`, container)
    expect(container.childNodes.length).toBe(0)
  })

  it('open palette dialog is axe-clean with listbox semantics', async () => {
    render(html`<${CommandPalette} openOnMount=${true} />`, container)

    const dialog = container.querySelector('.cmdk')
    expect(dialog?.getAttribute('role')).toBe('dialog')
    expect(dialog?.getAttribute('aria-modal')).toBe('true')

    const options = container.querySelectorAll('.cmdk-item')
    expect(options.length).toBeGreaterThan(0)
    expect(options[0]?.getAttribute('role')).toBe('option')

    expect(await axe(container)).toHaveNoViolations()
  })
})
