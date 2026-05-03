// KeyboardShortcut — shortcut conflict detection and context binding sheet
// Kimi design system sec02 2.4.2: shortcut conflict detection, context binding.
// Zero-dependency fallback (no fuzzysort).

import { html } from 'htm/preact'
import { Kbd } from './kbd'

export interface ShortcutItem {
  id: string
  keys: string[]
  description: string
  context?: string
  conflict?: boolean
}

interface KeyboardShortcutProps {
  shortcuts: ShortcutItem[]
  testId?: string
}

export function KeyboardShortcut({ shortcuts, testId }: KeyboardShortcutProps) {
  if (shortcuts.length === 0) {
    return html`
      <div
        data-testid=${testId}
        class="text-xs text-[var(--color-fg-muted)]"
        role="region"
        aria-label="키보드 단축키"
      >
        등록된 단축키가 없습니다.
      </div>
    `
  }

  return html`
    <div
      data-testid=${testId}
      class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] overflow-hidden"
      role="list"
      aria-label="키보드 단축키"
    >
      ${shortcuts.map((s) => {
        const rowCls =
          'flex items-center justify-between gap-3 px-3 py-2 text-sm border-b border-[var(--color-border-default)] last:border-b-0' +
          (s.conflict
            ? ' bg-[var(--error-10)]/10 border-l-2 border-l-[var(--error-10)]'
            : '')
        return html`
          <div key=${s.id} class=${rowCls} role="listitem" aria-label="${s.description}">
            <span class="text-[var(--color-fg-primary)]">${s.description}</span>
            <span class="flex items-center gap-1">
              ${s.keys.map(
                (k, i) => html`
                  <span class="flex items-center gap-1">
                    <${Kbd} size="sm">${k}</${Kbd}>
                    ${i < s.keys.length - 1
                      ? html`<span class="text-[var(--color-fg-muted)]">+</span>`
                      : null}
                  </span>
                `,
              )}
              ${s.context
                ? html`<span class="text-2xs text-[var(--color-fg-muted)] ml-1">${s.context}</span>`
                : null}
            </span>
          </div>
        `
      })}
    </div>
  `
}
