// StatCard — compact label/value/sub stat box used across dashboard sections.

import { html } from 'htm/preact'

export function StatCard({ label, value, sub }: { label: string; value: string | number; sub?: string }) {
  return html`
    <div class="rounded border border-[var(--white-8)] bg-[var(--white-4)] p-3 text-center">
      <div class="text-2xl font-bold text-[var(--color-accent-fg)]">${value}</div>
      <div class="mt-1 text-xs text-[var(--color-fg-muted)]">${label}</div>
      ${sub ? html`<div class="mt-0.5 text-xs text-[var(--color-fg-disabled)]">${sub}</div>` : null}
    </div>
  `
}
