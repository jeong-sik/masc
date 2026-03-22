// CmdStatCard — command plane stat box (label/value/detail).
// Replaces 21x inline bg-[var(--white-4)] border ... cmd-stat-card patterns.
// Typography (span/strong/small sizing) is handled by the cmd-stat-card @utility in global.css.

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'

interface CmdStatCardProps {
  label: string
  value: ComponentChildren
  detail?: ComponentChildren
  tone?: string
  highlight?: boolean
}

export function CmdStatCard({ label, value, detail, tone, highlight }: CmdStatCardProps) {
  return html`
    <div class="bg-[var(--white-4)] border border-[var(--white-8)] rounded-xl p-4 flex flex-col gap-2 cmd-stat-card ${tone ?? ''} ${highlight ? 'highlight' : ''}">
      <span>${label}</span>
      <strong>${value}</strong>
      ${detail != null ? html`<small>${detail}</small>` : null}
    </div>
  `
}
