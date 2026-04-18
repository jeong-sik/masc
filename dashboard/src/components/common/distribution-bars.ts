import { html } from 'htm/preact'

type DistributionTone = 'accent' | 'ok' | 'warn' | 'bad' | 'muted'

export interface DistributionItem {
  label: string
  value: number
  detail?: string | null
  tone?: DistributionTone
}

interface TonePalette {
  fill: string
  text: string
  chipBg: string
  chipBorder: string
}

const TONE_PALETTES: Record<DistributionTone, TonePalette> = {
  accent: {
    fill: 'var(--accent)',
    text: 'var(--accent)',
    chipBg: 'rgba(71,184,255,0.12)',
    chipBorder: 'rgba(71,184,255,0.24)',
  },
  ok: {
    fill: 'var(--ok)',
    text: 'var(--ok)',
    chipBg: 'rgba(34,197,94,0.12)',
    chipBorder: 'rgba(34,197,94,0.24)',
  },
  warn: {
    fill: 'var(--warn)',
    text: 'var(--warn)',
    chipBg: 'rgba(250,204,21,0.12)',
    chipBorder: 'rgba(250,204,21,0.24)',
  },
  bad: {
    fill: 'var(--bad)',
    text: 'var(--bad)',
    chipBg: 'rgba(248,113,113,0.12)',
    chipBorder: 'rgba(248,113,113,0.24)',
  },
  muted: {
    fill: 'rgba(148,163,184,0.85)',
    text: 'var(--text-muted)',
    chipBg: 'rgba(148,163,184,0.12)',
    chipBorder: 'rgba(148,163,184,0.24)',
  },
}

export function paletteFor(tone?: DistributionTone): TonePalette {
  return TONE_PALETTES[tone ?? 'accent']
}

export function DistributionBars({
  title,
  subtitle,
  items,
  emptyLabel = '표시할 데이터가 없습니다.',
  valueFormatter = value => String(value),
  limit = 6,
}: {
  title?: string
  subtitle?: string | null
  items: DistributionItem[]
  emptyLabel?: string
  valueFormatter?: (value: number) => string
  limit?: number
}) {
  const visibleItems = items
    .filter(item => Number.isFinite(item.value) && item.value > 0)
    .slice(0, Math.max(1, limit))
  const maxValue = Math.max(...visibleItems.map(item => item.value), 1)

  return html`
    <div class="rounded border border-card-border/35 bg-[var(--white-5)]/10 px-3 py-3">
      ${title
        ? html`
            <div class="text-[10px] font-semibold uppercase tracking-[0.16em] text-[var(--text-muted)]">${title}</div>
            ${subtitle ? html`<div class="mt-1 text-[11px] text-[var(--text-muted)]">${subtitle}</div>` : null}
          `
        : null}
      ${visibleItems.length === 0
        ? html`<div class="${title ? 'mt-3 ' : ''}text-[11px] italic text-[var(--text-muted)]">${emptyLabel}</div>`
        : html`
            <div class="${title ? 'mt-3 ' : ''}flex flex-col gap-2.5">
              ${visibleItems.map(item => {
                const palette = paletteFor(item.tone)
                const width = Math.max((item.value / maxValue) * 100, item.value > 0 ? 8 : 0)
                return html`
                  <div class="flex flex-col gap-1">
                    <div class="flex items-center justify-between gap-2">
                      <div class="min-w-0">
                        <div class="truncate text-[12px] font-semibold text-[var(--text-strong)]">${item.label}</div>
                        ${item.detail ? html`<div class="truncate text-[10px] text-[var(--text-muted)]">${item.detail}</div>` : null}
                      </div>
                      <span
                        class="shrink-0 rounded-full border px-2 py-0.5 text-[10px] font-semibold"
                        style=${`color:${palette.text};background:${palette.chipBg};border-color:${palette.chipBorder};`}
                      >
                        ${valueFormatter(item.value)}
                      </span>
                    </div>
                    <div class="h-2 overflow-hidden rounded-full bg-[var(--white-5)]">
                      <div
                        class="h-full rounded-full transition-[width] duration-300"
                        style=${`width:${Math.min(width, 100)}%;background:${palette.fill};opacity:0.8;`}
                      ></div>
                    </div>
                  </div>
                `
              })}
            </div>
          `}
    </div>
  `
}

export function SegmentedBar({
  title,
  subtitle,
  items,
  valueFormatter = value => String(value),
}: {
  title?: string
  subtitle?: string | null
  items: DistributionItem[]
  valueFormatter?: (value: number) => string
}) {
  const visibleItems = items.filter(item => Number.isFinite(item.value) && item.value > 0)
  const total = visibleItems.reduce((sum, item) => sum + item.value, 0)

  return html`
    <div class="rounded border border-card-border/35 bg-[var(--white-5)]/10 px-3 py-3">
      ${title
        ? html`
            <div class="text-[10px] font-semibold uppercase tracking-[0.16em] text-[var(--text-muted)]">${title}</div>
            ${subtitle ? html`<div class="mt-1 text-[11px] text-[var(--text-muted)]">${subtitle}</div>` : null}
          `
        : null}
      ${total === 0
        ? html`<div class="${title ? 'mt-3 ' : ''}text-[11px] italic text-[var(--text-muted)]">표시할 데이터가 없습니다.</div>`
        : html`
            <div class="${title ? 'mt-3 ' : ''}flex flex-col gap-2.5">
              <div class="flex h-3 overflow-hidden rounded-full bg-[var(--white-5)]">
                ${visibleItems.map(item => {
                  const palette = paletteFor(item.tone)
                  const width = (item.value / total) * 100
                  const formattedValue = valueFormatter(item.value)
                  return html`
                    <div
                      aria-label=${`${item.label}: ${formattedValue}`}
                      title=${`${item.label}: ${formattedValue}`}
                      style=${`width:${width}%;background:${palette.fill};opacity:0.82;`}
                    ></div>
                  `
                })}
              </div>
              <div class="flex flex-wrap gap-2">
                ${visibleItems.map(item => {
                  const palette = paletteFor(item.tone)
                  const formattedValue = valueFormatter(item.value)
                  return html`
                    <span
                      aria-label=${`${item.label}: ${formattedValue}`}
                      title=${`${item.label}: ${formattedValue}`}
                      class="inline-flex items-center gap-1.5 rounded-full border px-2 py-0.5 text-[10px] font-medium"
                      style=${`color:${palette.text};background:${palette.chipBg};border-color:${palette.chipBorder};`}
                    >
                      <span class="inline-block h-1.5 w-1.5 rounded-full" style=${`background:${palette.fill};`}></span>
                      <span>${item.label}</span>
                      <span aria-hidden="true">:</span>
                      <span class="font-semibold">${formattedValue}</span>
                    </span>
                  `
                })}
              </div>
            </div>
          `}
    </div>
  `
}
