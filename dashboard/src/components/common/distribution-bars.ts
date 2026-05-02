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
    fill: 'var(--color-accent-fg)',
    text: 'var(--color-accent-fg)',
    chipBg: 'var(--accent-12)',
    chipBorder: 'var(--info-border)',
  },
  ok: {
    fill: 'var(--color-status-ok)',
    text: 'var(--color-status-ok)',
    chipBg: 'var(--emerald-12)',
    chipBorder: 'var(--ok-border)',
  },
  warn: {
    fill: 'var(--color-status-warn)',
    text: 'var(--color-status-warn)',
    chipBg: 'var(--warn-soft)',
    chipBorder: 'var(--warn-border)',
  },
  bad: {
    fill: 'var(--color-status-err)',
    text: 'var(--color-status-err)',
    chipBg: 'var(--bad-10)',
    chipBorder: 'var(--err-border)',
  },
  muted: {
    fill: 'var(--color-fg-muted)',
    text: 'var(--color-fg-muted)',
    chipBg: 'var(--color-border-default)',
    chipBorder: 'var(--color-border-default)',
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
    <div class="rounded-[var(--r-1)] border border-card-border/35 bg-[var(--white-5)]/10 px-3 py-3">
      ${title
        ? html`
            <div class="text-3xs font-semibold uppercase tracking-5 text-[var(--color-fg-muted)]">${title}</div>
            ${subtitle ? html`<div class="mt-1 text-2xs text-[var(--color-fg-muted)]">${subtitle}</div>` : null}
          `
        : null}
      ${visibleItems.length === 0
        ? html`<div class="${title ? 'mt-3 ' : ''}text-2xs italic text-[var(--color-fg-muted)]">${emptyLabel}</div>`
        : html`
            <div class="${title ? 'mt-3 ' : ''}flex flex-col gap-2.5">
              ${visibleItems.map(item => {
                const palette = paletteFor(item.tone)
                const width = Math.max((item.value / maxValue) * 100, item.value > 0 ? 8 : 0)
                return html`
                  <div class="flex flex-col gap-1">
                    <div class="flex items-center justify-between gap-2">
                      <div class="min-w-0">
                        <div class="truncate text-xs font-semibold text-[var(--color-fg-secondary)]">${item.label}</div>
                        ${item.detail ? html`<div class="truncate text-3xs text-[var(--color-fg-muted)]">${item.detail}</div>` : null}
                      </div>
                      <span
                        class="shrink-0 rounded-[var(--r-0)] border px-2 py-0.5 text-3xs font-semibold"
                        style=${`color:${palette.text};background:${palette.chipBg};border-color:${palette.chipBorder};`}
                      >
                        ${valueFormatter(item.value)}
                      </span>
                    </div>
                    <div class="h-2 overflow-hidden rounded-[var(--r-0)] bg-[var(--white-5)]">
                      <div
                        class="h-full rounded-[var(--r-0)] transition-[width] duration-[var(--t-slow)]"
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
    <div class="rounded-[var(--r-1)] border border-card-border/35 bg-[var(--white-5)]/10 px-3 py-3">
      ${title
        ? html`
            <div class="text-3xs font-semibold uppercase tracking-5 text-[var(--color-fg-muted)]">${title}</div>
            ${subtitle ? html`<div class="mt-1 text-2xs text-[var(--color-fg-muted)]">${subtitle}</div>` : null}
          `
        : null}
      ${total === 0
        ? html`<div class="${title ? 'mt-3 ' : ''}text-2xs italic text-[var(--color-fg-muted)]">표시할 데이터가 없습니다.</div>`
        : html`
            <div class="${title ? 'mt-3 ' : ''}flex flex-col gap-2.5">
              <div class="flex h-3 overflow-hidden rounded-[var(--r-0)] bg-[var(--white-5)]">
                ${visibleItems.map(item => {
                  const palette = paletteFor(item.tone)
                  const width = (item.value / total) * 100
                  const formattedValue = valueFormatter(item.value)
                  // Bar segment is purely decorative — the same data is
                  // exposed accessibly via the chip pills below. Mark
                  // aria-hidden so axe's `aria-prohibited-attr` doesn't
                  // flag the missing role and screen readers skip the
                  // visual-only fill. `title` stays for sighted hover.
                  return html`
                    <div
                      aria-hidden="true"
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
                  // Chip pill carries the visible label + value as
                  // children — duplicate aria-label was an
                  // aria-prohibited-attr violation (no role on the span).
                  // Drop aria-label; the visible text content is the
                  // accessible name. `title` stays for sighted hover.
                  return html`
                    <span
                      title=${`${item.label}: ${formattedValue}`}
                      class="inline-flex items-center gap-1.5 rounded-[var(--r-0)] border px-2 py-0.5 text-3xs font-medium"
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
