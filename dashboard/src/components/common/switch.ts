// Switch — accessible toggle switch atom.
//
// Kimi design system sec06 reference: ARIA switch pattern with Space activation.
// Uses role="switch" and aria-checked for screen-reader contract.

import { html } from 'htm/preact'

interface SwitchProps {
  checked: boolean
  onChange: (checked: boolean) => void
  label?: string
  disabled?: boolean
  testId?: string
}

export function Switch({
  checked,
  onChange,
  label,
  disabled = false,
  testId,
}: SwitchProps) {
  const toggle = () => {
    if (disabled) return
    onChange(!checked)
  }

  const onKeyDown = (e: KeyboardEvent) => {
    if (disabled) return
    if (e.key === ' ' || e.key === 'Enter') {
      e.preventDefault()
      toggle()
    }
  }

  const trackClass = checked
    ? 'bg-[var(--ok-20)] border-[var(--ok-20)]'
    : 'bg-[var(--color-bg-elevated)] border-[var(--color-border-default)]'

  const thumbClass = checked
    ? 'translate-x-[14px] bg-[var(--color-fg-primary)]'
    : 'translate-x-[2px] bg-[var(--color-fg-muted)]'

  return html`
    <div class="inline-flex items-center gap-2">
      <div
        role="switch"
        aria-checked=${checked}
        aria-label=${label}
        aria-disabled=${disabled}
        tabindex=${disabled ? -1 : 0}
        data-testid=${testId}
        class=${`relative h-5 w-9 cursor-pointer rounded-full border transition-colors duration-[var(--t-med)] ${trackClass} ${disabled ? 'cursor-not-allowed opacity-50' : ''}`}
        onClick=${toggle}
        onKeyDown=${onKeyDown}
      >
        <span
          class=${`absolute top-[2px] h-3.5 w-3.5 rounded-full transition-transform duration-[var(--t-med)] ${thumbClass}`}
        />
      </div>
      ${label
        ? html`<span class="text-xs text-[var(--color-fg-muted)] select-none">${label}</span>`
        : null}
    </div>
  `
}
