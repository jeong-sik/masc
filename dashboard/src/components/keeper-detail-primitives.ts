import { html } from 'htm/preact'

export function StrongSecondary({ children }: { children: unknown }) {
  return html`<strong class="text-[var(--color-fg-secondary)]">${children}</strong>`
}

export function RuntimeBadge({ tone, children }: { tone: 'warn' | 'bad'; children: unknown }) {
  const toneCls = tone === 'warn'
    ? 'bg-[var(--warn-14)] text-[var(--color-status-warn)]'
    : 'bg-[var(--bad-soft)] text-[var(--color-status-err)]'
  return html`<span class="inline-flex items-center rounded-[var(--r-0)] px-2 py-0.5 text-2xs font-semibold ${toneCls}">${children}</span>`
}
