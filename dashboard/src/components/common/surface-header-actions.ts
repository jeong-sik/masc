import { html } from 'htm/preact'
import type { VNode } from 'preact'
import { CopyIdButton } from './copy-id-button'

function currentShareUrl(): string {
  if (typeof window === 'undefined' || window.location === undefined) {
    return ''
  }
  return window.location.href
}

export function SurfaceHeaderActions({ label }: { label: string }): VNode {
  const shareUrl = currentShareUrl()
  return html`
    <div class="v2-surface-header-actions inline-flex items-center gap-2">
      ${shareUrl !== ''
        ? html`<${CopyIdButton}
            value=${shareUrl}
            label=${`Section link (${label})`}
            ariaLabel="Copy current section URL"
            size=${14}
          />`
        : null}
    </div>
  `
}
