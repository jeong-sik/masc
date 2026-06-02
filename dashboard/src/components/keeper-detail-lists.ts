import { html } from 'htm/preact'
import { StatusChip } from './common/status-chip'

// ── Equipment List ───────────────────────────────────────

export function EquipmentList({ items }: { items: string[] }) {
  if (items.length === 0) return html`<div class="py-2 px-3 text-xs text-[var(--color-fg-muted)] italic">장비 없음</div>`

  return html`
    <div class="flex flex-col gap-1.5">
      ${items.map((item, i) => html`
        <div class="flex items-center justify-between py-2 px-3 rounded-[var(--r-1)] bg-[var(--color-bg-surface)]">
          <span class="text-xs text-[var(--color-fg-primary)]">${item}</span>
          <span class="text-3xs text-[var(--cyan)] font-mono">#${i + 1}</span>
        </div>
      `)}
    </div>
  `
}

// ── Relationship List ────────────────────────────────────

export function RelationshipList({ rels }: { rels: Record<string, string> }) {
  const entries = Object.entries(rels)
  if (entries.length === 0) return html`<div class="py-2 px-3 text-xs text-[var(--color-fg-muted)] italic">관계 없음</div>`

  return html`
    <div class="max-h-55 overflow-y-auto flex flex-col gap-1.5">
      ${entries.map(([name, relation]) => html`
        <div class="flex items-center gap-2 py-2 px-3 bg-[var(--color-bg-surface)] rounded-[var(--r-1)]">
          <${StatusChip} tone="info" uppercase=${false} class="text-2xs font-medium">${name}<//>
          <span class="text-2xs text-[var(--color-fg-muted)] font-mono">${relation}</span>
        </div>
      `)}
    </div>
  `
}

// ── Traits List ──────────────────────────────────────────

export function TraitsList({ traits, label }: { traits: string[]; label: string }) {
  if (traits.length === 0) return null

  return html`
    <div class="mb-3">
      <div class="text-3xs text-[var(--color-fg-muted)] uppercase tracking-wider font-semibold mb-2">${label}</div>
      <div class="flex flex-wrap gap-1.5">
        ${traits.map(t => html`<${StatusChip} tone="info" uppercase=${false} class="text-2xs font-medium">${t}<//>`)}
      </div>
    </div>
  `
}
