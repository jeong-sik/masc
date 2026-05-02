import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'

interface PanelCardProps {
  title: string
  children?: ComponentChildren
}

export function PanelCard({ title, children }: PanelCardProps) {
  return html`
    <div class="p-5 rounded-[var(--r-1)] border border-card-border bg-card/40 backdrop-blur-sm shadow-[var(--shadow-1)] transition-[border-color,box-shadow] duration-[var(--t-med)] hover:border-accent/30">
      <div class="text-2xs font-semibold uppercase tracking-[var(--track-caps)] text-text-muted mb-4 flex items-center gap-2">
        <span class="w-1.5 h-1.5 rounded-full bg-accent/50" aria-hidden="true"></span>
        ${title}
      </div>
      ${children}
    </div>
  `
}
