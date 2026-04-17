// CopyableCode — single-line shell snippet rendered as <code> with a copy button.
// Falls back to execCommand('copy') when navigator.clipboard is unavailable
// (e.g. http:// + non-localhost host where the Clipboard API is gated).

import { html } from 'htm/preact'
import { Copy, Check } from 'lucide-preact'
import { useState } from 'preact/hooks'
import { showToast } from './toast'

export interface CopyableCodeProps {
  command: string
  label?: string
  ariaLabel?: string
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

export function CopyableCode({ command, label, ariaLabel }: CopyableCodeProps) {
  const [justCopied, setJustCopied] = useState(false)
  const onCopy = async () => {
    const ok = await copyToClipboard(command)
    if (ok) {
      setJustCopied(true)
      showToast(label ? `Copied: ${label}` : 'Copied to clipboard', 'success', 1800)
      setTimeout(() => setJustCopied(false), 1400)
    } else {
      showToast('Copy failed — select the text manually', 'error')
    }
  }

  // Inline "Copied" confirmation — GitHub / VSCode gist pattern: the
  // icon swap alone is too subtle when the operator's eyes are on the
  // target terminal, so we flash a tiny text pill next to it for ~1.4s.
  // aria-live="polite" makes screen readers announce the success even
  // when they weren't focused on the button.
  return html`
    <div
      class="group flex items-center gap-2 rounded-md border border-[var(--white-8)] bg-[var(--white-2)] px-2 py-1.5 transition-colors hover:border-[var(--white-10)] hover:bg-[var(--white-4)]"
      data-copyable-code
      data-copied=${justCopied ? 'true' : 'false'}
    >
      ${label
        ? html`<span class="shrink-0 text-[10px] uppercase tracking-[0.14em] text-[var(--text-dim)]">${label}</span>`
        : null}
      <code class="min-w-0 flex-1 overflow-x-auto whitespace-nowrap font-mono text-[11px] text-[var(--text-body)]">${command}</code>
      ${justCopied
        ? html`<span class="shrink-0 text-[10px] font-semibold text-emerald-300" data-copied-badge aria-live="polite">✓ Copied</span>`
        : null}
      <button
        type="button"
        class="shrink-0 cursor-pointer rounded border border-transparent p-1 text-[var(--text-dim)] opacity-60 transition-opacity hover:bg-[var(--white-8)] hover:text-[var(--text-body)] focus-visible:opacity-100 group-hover:opacity-100"
        aria-label=${ariaLabel || (label ? `Copy ${label}` : 'Copy command')}
        data-copy-button
        onClick=${onCopy}
      >
        ${justCopied ? html`<${Check} size=${14} />` : html`<${Copy} size=${14} />`}
      </button>
    </div>
  `
}
