import { html } from 'htm/preact'

export function InfoCard({ children }: { children: unknown }) {
  return html`<div class="rounded border border-[var(--white-8)] bg-[var(--white-4)] p-3">${children}</div>`
}
