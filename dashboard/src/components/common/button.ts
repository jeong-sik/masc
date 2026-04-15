// ActionButton — reusable button with variant styles
// Replaces repeated inline button patterns across dashboard

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'

type ButtonVariant = 'primary' | 'ghost' | 'danger' | 'subtle'
type ButtonSize = 'sm' | 'md' | 'lg'

const SIZE_CLASSES: Record<ButtonSize, string> = {
  sm: 'py-1 px-2 text-[10px]',
  md: 'py-1.5 px-2.5 text-[11px]',
  lg: 'py-2 px-4 text-sm',
}

const VARIANT_CLASSES: Record<ButtonVariant, string> = {
  primary: 'border border-solid border-[var(--accent-30)] bg-[var(--accent-12)] text-[var(--text-strong)] hover:bg-[var(--accent-20)]',
  ghost: 'border border-solid border-[var(--card-border)] bg-[var(--white-4)] text-[var(--text-body)] hover:bg-[var(--white-8)]',
  danger: 'border border-solid border-[var(--bad-30)] bg-[var(--bad-10)] text-[var(--bad-light)] hover:bg-[var(--bad-20)]',
  subtle: 'border-none bg-transparent text-[var(--text-muted)] hover:text-[var(--text-body)] hover:bg-[var(--white-6)]',
}

const BASE = 'rounded-lg cursor-pointer transition-all duration-200 font-medium focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[rgba(71,184,255,0.45)] focus-visible:ring-offset-2 focus-visible:ring-offset-[var(--bg-1)] active:scale-[0.97] active:opacity-90'

interface ActionButtonProps {
  variant?: ButtonVariant
  size?: ButtonSize
  class?: string
  disabled?: boolean
  /** Full width */
  block?: boolean
  ariaLabel?: string
  onClick?: (e: Event) => void
  children: ComponentChildren
}

export function ActionButton({
  variant = 'primary',
  size = 'md',
  class: cx,
  disabled,
  block,
  ariaLabel,
  onClick,
  children,
}: ActionButtonProps) {
  const cls = [
    BASE,
    SIZE_CLASSES[size],
    VARIANT_CLASSES[variant],
    block ? 'w-full' : '',
    disabled ? 'opacity-50 pointer-events-none' : '',
    cx,
  ].filter(Boolean).join(' ')

  return html`
    <button type="button" class=${cls} onClick=${onClick} disabled=${disabled} aria-label=${ariaLabel}>${children}</button>
  `
}
