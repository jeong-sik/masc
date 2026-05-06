import { html } from 'htm/preact'
import { Maximize2, Minimize2 } from 'lucide-preact'
import { useKeyboardShortcut } from '../../design-system/headless-preact/use-keyboard-shortcut'
import { globalShortcutManager } from '../lib/global-shortcut-manager'
import { persistentSignal } from '../lib/persistent-signal'
import { ringFocusClasses } from './common/ring'

export const dashboardFocusMode = persistentSignal<boolean>({
  key: 'dashboard:focus-mode',
  defaultValue: false,
})

function toggleFocusMode(): void {
  dashboardFocusMode.value = !dashboardFocusMode.value
}

export function DashboardFocusModeToggle() {
  const focusMode = dashboardFocusMode.value
  const Icon = focusMode ? Minimize2 : Maximize2
  const f11Shortcut = useKeyboardShortcut(
    globalShortcutManager,
    {
      chord: { key: 'F11', modifiers: [] },
      description: 'Toggle dashboard focus mode',
      scope: 'global',
      preserveInInputs: false,
      action: toggleFocusMode,
    },
    'dashboard.focus-mode.f11',
  )
  const modBackslashShortcut = useKeyboardShortcut(
    globalShortcutManager,
    {
      chord: { key: '\\', modifiers: ['Mod'] },
      description: 'Toggle dashboard focus mode',
      scope: 'global',
      preserveInInputs: false,
      action: toggleFocusMode,
    },
    'dashboard.focus-mode.mod-backslash',
  )
  const shortcutHint = `${f11Shortcut.display} or ${modBackslashShortcut.display}`
  const ariaShortcutHint = `${f11Shortcut.aria} ${modBackslashShortcut.aria}`

  return html`
    <button
      type="button"
      class=${`fixed bottom-4 right-4 z-50 inline-flex h-9 items-center gap-2 rounded-[var(--r-1)] border border-solid px-3 text-xs font-semibold shadow-[var(--shadow-panel)] backdrop-blur-xl transition-colors max-[520px]:bottom-3 max-[520px]:right-3 ${focusMode ? 'border-[var(--brass-3)] bg-[var(--accent-22)] text-[var(--brass-1)]' : 'border-[var(--color-border-default)] bg-[var(--shell-header-bg)] text-[var(--color-fg-secondary)] hover:bg-[var(--color-bg-hover)]'} ${ringFocusClasses({ tone: 'accent-medium', width: 2, offset: 2, offsetSurface: 'page' })}`}
      title=${`Toggle focus mode (${shortcutHint})`}
      aria-label=${`${focusMode ? 'Exit' : 'Enter'} dashboard focus mode (${shortcutHint})`}
      aria-keyshortcuts=${ariaShortcutHint}
      aria-pressed=${focusMode}
      data-testid="dashboard-focus-mode-toggle"
      onClick=${toggleFocusMode}
    >
      <${Icon} size=${15} aria-hidden="true" />
      <span class="font-mono text-3xs uppercase leading-none tracking-[var(--track-caps)]">${focusMode ? 'Exit' : 'Focus'}</span>
    </button>
  `
}
