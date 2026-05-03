// CopyableCode — single-line shell snippet rendered as <code> with a copy button.
// Falls back to execCommand('copy') when navigator.clipboard is unavailable
// (e.g. http:// + non-localhost host where the Clipboard API is gated).

import { html } from 'htm/preact'
import { Copy, Check } from 'lucide-preact'
import { useState } from 'preact/hooks'
import { showToast } from './toast'

type CopyableVariant = 'primary' | 'secondary'

interface CopyableCodeProps {
  command: string
  label?: string
  ariaLabel?: string
  /** Visual weight. `primary` = accented border + brighter label,
      used for the main CTA command in a sequence (e.g. the Start cmd
      in a sidecar onboarding block). `secondary` (default) = muted,
      used for diagnostic / follow-up commands grouped below the
      primary. Inspired by Vercel "Deploy your project" and Railway
      deploy-log next-steps hierarchy. */
  variant?: CopyableVariant
}

export async function copyToClipboard(text: string): Promise<boolean> {
  if (typeof navigator !== 'undefined' && navigator.clipboard?.writeText) {
    try {
      await navigator.clipboard.writeText(text)
      return true
    } catch {
      // fall through to execCommand fallback
    }
  }
  if (typeof document === 'undefined') return false
  const ta = document.createElement('textarea')
  ta.value = text
  ta.setAttribute('readonly', '')
  ta.style.position = 'absolute'
  ta.style.left = '-9999px'
  document.body.appendChild(ta)
  ta.select()
  let ok = false
  try {
    ok = document.execCommand('copy')
  } catch {
    ok = false
  }
  document.body.removeChild(ta)
  return ok
}

/** Pure: classes for the outer wrapper per variant. Exposed so callers
    that want to group several secondary commands in a shared container
    can align their own styling with the primitive's tone. */
export function copyableWrapperClasses(variant: CopyableVariant): string {
  switch (variant) {
    case 'primary':
      // Accented border, stronger bg, tighter padding to read like a
      // "hero command". Matches Vercel "Deploy your project" primary CTA.
      return 'border-[var(--accent-30)] bg-[var(--accent-12)] px-2.5 py-2'
    case 'secondary':
    default:
      return 'border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2 py-1.5'
  }
}

/** Pure: classes for the label chip per variant. Primary gets the accent
    text + slightly bolder weight so the label stops being a silent chip
    at the left edge and starts leading the reader's eye into the command. */
export function copyableLabelClasses(variant: CopyableVariant): string {
  return variant === 'primary'
    ? 'shrink-0 text-3xs font-semibold uppercase tracking-4 text-[var(--color-accent-fg)]'
    : 'shrink-0 text-3xs uppercase tracking-4 text-[var(--color-fg-disabled)]'
}

export function CopyableCode({
  command,
  label,
  ariaLabel,
  variant = 'secondary',
}: CopyableCodeProps) {
  const [justCopied, setJustCopied] = useState(false)
  const onCopy = async () => {
    const ok = await copyToClipboard(command)
    if (ok) {
      setJustCopied(true)
      showToast(label ? `복사됨: ${label}` : '클립보드에 복사됨', 'success', 1800)
      setTimeout(() => setJustCopied(false), 1400)
    } else {
      showToast('복사 실패 — 텍스트를 직접 선택하세요', 'error')
    }
  }

  // Inline "Copied" confirmation — GitHub / VSCode gist pattern: the
  // icon swap alone is too subtle when the operator's eyes are on the
  // target terminal, so we flash a tiny text pill next to it for ~1.4s.
  // aria-live="polite" makes screen readers announce the success even
  // when they weren't focused on the button.
  const wrapperTone = copyableWrapperClasses(variant)
  const labelTone = copyableLabelClasses(variant)
  return html`
    <div
      class=${`group flex items-center gap-2 rounded-[var(--r-1)] border transition-colors hover:border-[var(--color-border-default)] hover:bg-[var(--color-bg-elevated)] ${wrapperTone}`}
      data-copyable-code
      data-copyable-variant=${variant}
      data-copied=${justCopied ? 'true' : 'false'}
    >
      ${label
        ? html`<span class=${labelTone}>${label}</span>`
        : null}
      <code class="min-w-0 flex-1 overflow-x-auto whitespace-nowrap font-mono text-2xs text-[var(--color-fg-primary)]">${command}</code>
      ${justCopied
        ? html`<span class="shrink-0 text-3xs font-semibold text-[var(--color-status-ok)]" data-copied-badge aria-live="polite">✓ Copied</span>`
        : null}
      <button
        type="button"
        class="shrink-0 cursor-pointer rounded-[var(--r-1)] border border-transparent p-1 text-[var(--color-fg-disabled)] opacity-60 transition-opacity hover:bg-[var(--color-bg-hover)] hover:text-[var(--color-fg-primary)] focus-visible:opacity-100 group-hover:opacity-100"
        aria-label=${ariaLabel || (label ? `${label} 복사` : '명령 복사')}
        data-copy-button
        onClick=${onCopy}
      >
        ${justCopied ? html`<${Check} size=${14} />` : html`<${Copy} size=${14} />`}
      </button>
    </div>
  `
}
