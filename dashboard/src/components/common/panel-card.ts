import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'

interface PanelCardProps {
  title: string
  children?: ComponentChildren
}

export function PanelCard({ title, children }: PanelCardProps) {
  return html`
    <div class="p-5 rounded border border-card-border bg-card/40 backdrop-blur-sm shadow-sm transition-[border-color,box-shadow] duration-[var(--t-med)] hover:border-accent/30 hover:shadow-sm">
      <div class="text-2xs font-semibold uppercase tracking-widest text-text-muted mb-4 flex items-center gap-2">
        <span class="w-1.5 h-1.5 rounded-full bg-accent/50" aria-hidden="true"></span>
        ${title}
      </div>
      ${children}
    </div>
  `
}
