import { html } from 'htm/preact'

type ProvenanceItem = {
  kind?: string | null
  label?: string | null
}

function normalizeProvenance(value?: string | null): string {
  return (value ?? '').trim().toLowerCase()
}

function provenanceTone(value?: string | null): string {
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

function provenanceDetail(value?: string | null): string {
  switch (normalizeProvenance(value)) {
    case 'truth':
      return '직접 수집한 source of truth'
    case 'derived':
      return 'truth를 바탕으로 계산한 read-model'
    case 'fallback':
      return '직접 truth가 비어 있을 때 쓰는 대체 경로'
    case 'recorded':
      return '이미 기록된 결정 또는 증거'
    case 'narrative':
      return 'MODEL 해석 레이어'
    case 'judgment':
      return '판단 레이어'
    default:
      return '근거 계층'
  }
}

function provenanceLabel(item: ProvenanceItem): string {
  const explicit = (item.label ?? '').trim()
  if (explicit) return explicit
  return normalizeProvenance(item.kind) || 'unknown'
}

export function ProvenanceChip({ item }: { item: ProvenanceItem }) {
  const label = provenanceLabel(item)
  const tone = provenanceTone(item.kind)
  return html`
    <span class="command-chip ${tone}" title=${provenanceDetail(item.kind)}>
      ${label}
    </span>
  `
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
