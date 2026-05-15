import { html } from 'htm/preact'

export interface DashboardFeedSourceMetadata {
  dashboard_surface?: string
  source?: string
  retention?: Record<string, unknown>
  generated_at_iso?: string
}

function nonEmptyString(value: unknown): string | null {
  return typeof value === 'string' && value.trim() !== '' ? value : null
}

function retentionValue(meta: DashboardFeedSourceMetadata): string | null {
  const direct = nonEmptyString(meta.retention?.durable_store)
  if (direct) return direct

  const stores = meta.retention?.durable_stores
  if (!Array.isArray(stores)) return null

  const names = stores.filter((store): store is string => typeof store === 'string' && store.trim() !== '')
  if (names.length === 0) return null
  const visible = names.slice(0, 2).join(', ')
  return names.length > 2 ? `${visible} +${names.length - 2}` : visible
}

export function DashboardFeedSourceStrip({
  meta,
  className = '',
}: {
  meta: DashboardFeedSourceMetadata | null | undefined
  className?: string
}) {
  if (!meta) return null
  const store = retentionValue(meta)
  const items = [
    meta.source ? `source ${meta.source}` : '',
    meta.dashboard_surface ? `surface ${meta.dashboard_surface}` : '',
    store ? `store ${store}` : '',
    meta.generated_at_iso ? `generated ${meta.generated_at_iso}` : '',
  ].filter(Boolean)
  if (items.length === 0) return null
  const cls = [
    'rounded-[var(--r-1)] border border-card-border/60 bg-[var(--backdrop-deep)] px-2.5 py-1.5 font-mono text-3xs text-[var(--color-fg-muted)]',
    className,
  ].filter(Boolean).join(' ')
  return html`<div class=${cls}>${items.join(' | ')}</div>`
}
