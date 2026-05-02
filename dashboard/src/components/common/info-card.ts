import { html } from 'htm/preact'

export function InfoCard({ children }: { children: unknown }) {
  return html`<div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--white-4)] p-3">${children}</div>`
}
