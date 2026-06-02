import { h } from 'preact'
import { cleanup, fireEvent, render, screen } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import '@testing-library/jest-dom'
import { useKeyboardShortcutHost } from '../../design-system/headless-preact/use-keyboard-shortcut'
import { globalShortcutManager } from '../lib/global-shortcut-manager'
import { DashboardFocusModeToggle, dashboardFocusMode } from './focus-mode-toggle'

function FocusModeShortcutHarness() {
  useKeyboardShortcutHost(globalShortcutManager)
  return h(DashboardFocusModeToggle, {})
}

describe('DashboardFocusModeToggle', () => {
  beforeEach(() => {
    dashboardFocusMode.value = false
    globalShortcutManager.unregisterAll('dashboard.focus-mode.')
  })

  afterEach(() => {
    cleanup()
    dashboardFocusMode.value = false
    globalShortcutManager.unregisterAll('dashboard.focus-mode.')
    vi.clearAllMocks()
  })

  it('toggles focus mode from the button', () => {
    render(h(DashboardFocusModeToggle, {}))

    const button = screen.getByTestId('dashboard-focus-mode-toggle')
    expect(button).toHaveTextContent('Focus')
    expect(button).toHaveAttribute('aria-pressed', 'false')
    expect(button.getAttribute('title')).toContain('F11')
    expect(button.getAttribute('title')).toContain('\\')
    expect(button.getAttribute('aria-keyshortcuts')).toContain('F11')

    fireEvent.click(button)

    expect(dashboardFocusMode.value).toBe(true)
    expect(button).toHaveTextContent('Exit')
    expect(button).toHaveAttribute('aria-pressed', 'true')
  })

  it('registers focus shortcuts on the global shortcut manager', () => {
    render(h(DashboardFocusModeToggle, {}))

    expect(globalShortcutManager.getById('dashboard.focus-mode.f11')).not.toBeUndefined()
    expect(globalShortcutManager.getById('dashboard.focus-mode.mod-backslash')).not.toBeUndefined()
  })

  it('toggles focus mode through the global shortcut host and ignores editable targets', () => {
    render(h(FocusModeShortcutHarness, {}))

    fireEvent.keyDown(document, { key: 'F11' })
    expect(dashboardFocusMode.value).toBe(true)

    const input = document.createElement('input')
    document.body.appendChild(input)
    fireEvent.keyDown(input, { key: 'F11' })
    expect(dashboardFocusMode.value).toBe(true)
    input.remove()
  })

  it('toggles focus mode with the modifier-backslash chord', () => {
    render(h(FocusModeShortcutHarness, {}))

    fireEvent.keyDown(document, { key: '\\', metaKey: true, ctrlKey: true })

    expect(dashboardFocusMode.value).toBe(true)
  })
})
