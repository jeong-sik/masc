// CopyIdButton — compact icon-only copy button for UUIDs / session_ids
// next to an existing <code>/mono text display. No container styling —
// the caller controls layout. Reuses copyToClipboard from copyable-code.

import { html } from 'htm/preact'
import { Copy, Check } from 'lucide-preact'
import { useState } from 'preact/hooks'
import { ringFocusClasses } from './ring'
import { showToast } from './toast'
import { copyToClipboard } from './copyable-code'

export type CopyIdButtonState = 'idle' | 'copied'

export interface CopyIdButtonSummary {
  state: CopyIdButtonState
  hasLabel: boolean
  hasExplicitAriaLabel: boolean
  size: number
  valueLength: number
  ariaLabel: string
}

export interface CopyIdButtonProps {
  value: string
  label?: string
  ariaLabel?: string
  size?: number
}

export function copyIdButtonAriaLabel(label?: string, ariaLabel?: string): string {
  return ariaLabel || (label ? `${label} 복사` : '복사')
}

export function summarizeCopyIdButton({
  value,
  label,
  ariaLabel,
  size,
  copied,
}: {
  value: string
  label?: string
  ariaLabel?: string
  size: number
  copied: boolean
}): CopyIdButtonSummary {
  return {
    state: copied ? 'copied' : 'idle',
    hasLabel: label !== undefined && label !== '',
    hasExplicitAriaLabel: ariaLabel !== undefined && ariaLabel !== '',
    size,
    valueLength: value.length,
    ariaLabel: copyIdButtonAriaLabel(label, ariaLabel),
  }
}

export function CopyIdButton({ value, label, ariaLabel, size = 13 }: CopyIdButtonProps) {
  const [justCopied, setJustCopied] = useState(false)
  const summary = summarizeCopyIdButton({ value, label, ariaLabel, size, copied: justCopied })

  const onCopy = async (e: MouseEvent) => {
    e.stopPropagation()
    const ok = await copyToClipboard(value)
    if (ok) {
      setJustCopied(true)
      showToast(label ? `복사됨: ${label}` : '복사됨', 'success', 1400)
      setTimeout(() => setJustCopied(false), 1200)
    } else {
      showToast('복사 실패', 'error')
    }
  }

  return html`
    <button
      type="button"
      class=${`inline-flex size-6 shrink-0 cursor-pointer items-center justify-center rounded-[var(--r-0)] border border-transparent text-[var(--color-fg-muted)] opacity-75 transition-[background-color,border-color,color,opacity] hover:border-[var(--color-border-subtle)] hover:bg-[var(--color-bg-hover)] hover:text-[var(--color-fg-primary)] hover:opacity-100 focus-visible:opacity-100 ${ringFocusClasses({ tone: 'accent-subtle', width: 1 })}`}
      aria-label=${summary.ariaLabel}
      title=${summary.ariaLabel}
      onClick=${onCopy}
      data-copy-id-button
      data-copy-id-state=${summary.state}
      data-copy-id-has-label=${summary.hasLabel}
      data-copy-id-has-explicit-aria-label=${summary.hasExplicitAriaLabel}
      data-copy-id-size=${summary.size}
      data-copy-id-value-length=${summary.valueLength}
      data-copied=${justCopied ? 'true' : 'false'}
    >
      ${justCopied
        ? html`<${Check} size=${size} strokeWidth=${2.25} aria-hidden="true" data-copy-id-icon />`
        : html`<${Copy} size=${size} strokeWidth=${2.25} aria-hidden="true" data-copy-id-icon />`}
    </button>
  `
}
