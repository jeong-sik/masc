import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'

export function KeeperDetailSectionCard({
  title,
  children,
}: {
  title: string
  children: ComponentChildren
}) {
  return html`
    <div class="p-5 rounded border border-card-border bg-card/40 backdrop-blur-sm shadow-sm transition-[border-color,box-shadow] duration-200 hover:border-accent/30 hover:shadow-sm" role="region" aria-label=${title}>
      <div class="text-2xs font-semibold uppercase tracking-widest text-text-muted mb-4 flex items-center gap-2">
        <span class="w-1.5 h-1.5 rounded-full bg-accent/50"></span>
        ${title}
      </div>
      ${children}
    </div>
  `
}
