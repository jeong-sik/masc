// ConnectorKeyboardShortcuts — lightweight keyboard navigation for the
// all-connectors view. Pressing `1`–`4` smooth-scrolls to the matching
// connector card (in the same KNOWN_CONNECTOR_IDS order as the tiles:
// 1=discord, 2=imessage, 3=slack, 4=telegram). Pressing `?` toggles a
// small floating cheatsheet.
//
// Reference pattern — Linear `cmd+K` / Gmail `?` / GitHub's single-key
// shortcuts (`g` + `p` etc.): low-friction keyboard navigation that
// operator power-users can reach for without learning a whole palette.
// We keep it deliberately tiny — 4 tiles only, so no fuzzy search is
// needed; the numeric row is immediate and teachable.
//
// Safety: all handlers bail when the focused element is an editable
// surface (input / textarea / contenteditable / open select) so typing
// a "1" into the log viewer's keyword field never scrolls the page.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useLayoutEffect } from 'preact/hooks'
import { KNOWN_CONNECTOR_IDS, type KnownConnectorId } from './connector-status'
import { Kbd } from './common/kbd'

const cheatsheetOpen = signal(false)

/** Pure: map a keyboard key to a known connector id using the tile
    ordering. Returns null for anything that isn't "1".."N" where N is
    the number of known connectors. Exported for unit tests so we can
    pin the digit-to-id mapping without a real keydown event. */
export function mapKeyToConnectorId(key: string): KnownConnectorId | null {
  if (key.length !== 1) return null
  const digit = Number.parseInt(key, 10)
  if (Number.isNaN(digit)) return null
  if (digit < 1 || digit > KNOWN_CONNECTOR_IDS.length) return null
  return KNOWN_CONNECTOR_IDS[digit - 1] ?? null
}

/** Pure: should this keydown be ignored because the operator is typing
    into a form field? Split out so tests can pin the branches without
    creating real DOM. */
export function shouldSkipShortcut(target: EventTarget | null): boolean {
  if (target === null) return false
  if (!(target instanceof Element)) return false
  const tag = target.tagName
  if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') return true
  const editable = (target as HTMLElement).isContentEditable
  return editable === true
}

function scrollToCard(id: string) {
  const el = document.getElementById(`connector-card-${id}`)
  if (el) el.scrollIntoView({ behavior: 'smooth', block: 'start' })
}

export function ConnectorKeyboardShortcuts() {
  // Register on window so shortcuts work regardless of focus target
  // (except editable surfaces — see shouldSkipShortcut). Syncing to an
  // external system (window's keydown stream) is a legitimate useEffect
  // use-case; useLayoutEffect here makes the listener available the
  // moment the section paints, which keeps our test assertions sync.
  useLayoutEffect(() => {
    const handler = (ev: KeyboardEvent) => {
      if (shouldSkipShortcut(ev.target)) return
      if (ev.metaKey || ev.ctrlKey || ev.altKey) return
      if (ev.key === '?') {
        cheatsheetOpen.value = !cheatsheetOpen.value
        ev.preventDefault()
        return
      }
      if (ev.key === 'Escape' && cheatsheetOpen.value) {
        cheatsheetOpen.value = false
        ev.preventDefault()
        return
      }
      const id = mapKeyToConnectorId(ev.key)
      if (id !== null) {
        scrollToCard(id)
        ev.preventDefault()
      }
    }
    window.addEventListener('keydown', handler)
    return () => window.removeEventListener('keydown', handler)
  }, [])

  // Reading the signal here binds re-renders of this component to the
  // toggle — keeps cheatsheet open/close purely reactive, no manual
  // state plumbing needed.
  if (!cheatsheetOpen.value) return null
  return html`
    <div
      class="fixed bottom-4 right-4 z-50 rounded border border-[var(--white-10)] bg-[var(--bg-1)] p-3 text-2xs text-[var(--text-body)] shadow-sm"
      data-connector-shortcut-cheatsheet
      role="dialog"
      aria-label="커넥터 단축키"
    >
      <div class="mb-1.5 text-3xs font-semibold uppercase tracking-4 text-[var(--text-dim)]">Shortcuts</div>
      ${KNOWN_CONNECTOR_IDS.map((id, i) => html`
        <div class="flex items-center justify-between gap-4">
          <${Kbd}>${i + 1}<//>
          <span class="text-[var(--text-dim)]">→ ${id}</span>
        </div>
      `)}
      <div class="mt-1.5 flex items-center justify-between gap-4 border-t border-[var(--white-8)] pt-1.5">
        <${Kbd}>?<//>
        <span class="text-[var(--text-dim)]">toggle</span>
      </div>
    </div>
  `
}

export function _testResetShortcutState() {
  cheatsheetOpen.value = false
}

export function _testIsCheatsheetOpen(): boolean {
  return cheatsheetOpen.value
}
