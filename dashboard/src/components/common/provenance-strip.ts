import { html } from 'htm/preact'
import { StatusChip } from './status-chip'

type ProvenanceItem = {
  kind?: string | null
  label?: string | null
}

function normalizeProvenance(value?: string | null): string {
  return (value ?? '').trim().toLowerCase()
}

export function provenanceTone(value?: string | null): string {
  switch (normalizeProvenance(value)) {
    case 'truth':
      return 'ok'
    case 'recorded':
      return ''
    case 'derived':
    case 'fallback':
    case 'narrative':
    case 'judgment':
      return 'warn'
    default:
      return ''
  }
}

const PROVENANCE_LABELS: Record<string, string> = {
  truth: '검증됨',
  derived: '파생',
  fallback: '대체값',
  narrative: '서술',
  judgment: '판단',
  recorded: '기록됨',
}

export function provenanceLabel(item: ProvenanceItem): string {
  const explicit = (item.label ?? '').trim()
  if (explicit) return explicit
  const kind = normalizeProvenance(item.kind)
  return PROVENANCE_LABELS[kind] ?? (kind || 'unknown')
}

export function ProvenanceChip({ item }: { item: ProvenanceItem }) {
  const label = provenanceLabel(item)
  const tone = provenanceTone(item.kind)
  return html`<${StatusChip} label=${label} tone=${tone} />`
}

export function ProvenanceStrip({
  items,
  className = 'mission-briefing-meta',
  testId,
}: {
  items: ProvenanceItem[]
  className?: string
  testId?: string
}) {
  const normalized = items.filter(item => provenanceLabel(item).trim().length > 0)
  if (normalized.length === 0) return null

  return html`
    <div class=${className} data-testid=${testId}>
      ${normalized.map((item, index) => html`<${ProvenanceChip} key=${`${provenanceLabel(item)}-${index}`} item=${item} />`)}
    </div>
  `
}
