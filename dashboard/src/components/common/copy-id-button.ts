// CopyIdButton — compact icon-only copy button for UUIDs / session_ids
// next to an existing <code>/mono text display. No container styling —
// the caller controls layout. Reuses copyToClipboard from copyable-code.

import { html } from 'htm/preact'
import { Copy, Check } from 'lucide-preact'
import { useState } from 'preact/hooks'
import { showToast } from './toast'
import { copyToClipboard } from './copyable-code'

interface CopyIdButtonProps {
  value: string
  label?: string
  ariaLabel?: string
  size?: number
}

export function CopyIdButton({ value, label, ariaLabel, size = 12 }: CopyIdButtonProps) {
  const [justCopied, setJustCopied] = useState(false)

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
      class="inline-flex shrink-0 cursor-pointer items-center justify-center rounded p-0.5 text-[var(--color-fg-disabled)] opacity-60 transition-all hover:bg-[var(--white-8)] hover:text-[var(--color-fg-primary)] hover:opacity-100 focus-visible:opacity-100 focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-[var(--accent-30)]"
      aria-label=${ariaLabel || (label ? `${label} 복사` : '복사')}
      title=${ariaLabel || (label ? `${label} 복사` : '복사')}
      onClick=${onCopy}
    >
      ${justCopied ? html`<${Check} size=${size} />` : html`<${Copy} size=${size} />`}
    </button>
  `
}
