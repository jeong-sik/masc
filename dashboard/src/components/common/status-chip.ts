// StatusChip -- read-only badge for status, model, tags
// Replaces 90+ inline `<span class="cmd-chip rounded-full ${tone}">` patterns.

import { html } from 'htm/preact'

interface StatusChipProps {
  label: string
  tone?: string
  class?: string
}

export function StatusChip({ label, tone = '', class: extraClass = '' }: StatusChipProps) {
  const cls = `cmd-chip rounded-full ${tone} ${extraClass}`.replace(/\s+/g, ' ').trim()
  return html`<span class="${cls}">${label}</span>`
}
