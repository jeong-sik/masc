import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { get } from '../api/core'
import { createAsyncResource, type AsyncResource } from '../lib/async-state'
import { formatTimeAgoEn } from '../lib/format-time'
import { AsyncContainer } from './common/async-container'
import { SectionCard } from './common/card'
import { FilterChips } from './common/filter-chips'
import { EmptyState } from './common/feedback-state'
import { StatusChip, type StatusChipTone } from './common/status-chip'
import { KpiStripView, type KpiStripViewData } from './kpi-strip-view'
import { asBoolean, asRecordArray, asString, isRecord } from './common/normalize'

type SurfaceFilter = 'all' | 'main' | 'lab' | 'diagnostic' | 'gaps'

interface SurfaceVerificationRef {
  kind: string
  label: string
  value: string
}

export interface SurfaceReadinessEntry {
  id: string
  label: string
  exposure_status: string
  hidden_from_nav: boolean
  meets_main_gate: boolean
  verification_ref_bar: string
  rationale: string
  route_hash: string | null
  verification_refs: SurfaceVerificationRef[]
}

export interface SurfaceReadinessData {
  generated_at: string
  verification_ref_bar: string
  surfaces: SurfaceReadinessEntry[]
}

interface SurfaceReadinessSummary {
  total: number
  main: number
  lab: number
  diagnostic: number
  hidden: number
  gaps: number
}

const surfaceReadiness: AsyncResource<SurfaceReadinessData> = createAsyncResource()
const activeFilter = signal<SurfaceFilter>('all')

const FILTERS: Array<{ key: SurfaceFilter; label: string }> = [
  { key: 'all', label: 'All' },
  { key: 'main', label: 'Main' },
  { key: 'lab', label: 'Lab' },
  { key: 'diagnostic', label: 'Diagnostic' },
  { key: 'gaps', label: 'Gaps' },
]

function normalizeRef(value: unknown): SurfaceVerificationRef {
  const ref = isRecord(value) ? value : {}
  return {
    kind: asString(ref.kind, 'ref'),
    label: asString(ref.label, 'ref'),
    value: asString(ref.value, ''),
  }
}

function normalizeSurface(value: unknown): SurfaceReadinessEntry {
  const item = isRecord(value) ? value : {}
  return {
    id: asString(item.id, 'surface'),
    label: asString(item.label, 'Surface'),
    exposure_status: asString(item.exposure_status, 'unknown'),
    hidden_from_nav: asBoolean(item.hidden_from_nav, false),
    meets_main_gate: asBoolean(item.meets_main_gate, false),
    verification_ref_bar: asString(item.verification_ref_bar, ''),
    rationale: asString(item.rationale, ''),
    route_hash: asString(item.route_hash) ?? null,
    verification_refs: asRecordArray(item.verification_refs).map(normalizeRef),
  }
}

export function normalizeSurfaceReadinessPayload(raw: unknown): SurfaceReadinessData {
  const data = isRecord(raw) ? raw : {}
  return {
    generated_at: asString(data.generated_at, ''),
    verification_ref_bar: asString(data.verification_ref_bar, ''),
    surfaces: asRecordArray(data.surfaces).map(normalizeSurface),
  }
}

function hasRef(surface: SurfaceReadinessEntry, label: string): boolean {
  return surface.verification_refs.some(ref => ref.label === label && ref.value.trim() !== '')
}

export function missingSurfaceVerificationRefs(surface: SurfaceReadinessEntry): string[] {
  return ['live_spotcheck', 'logs'].filter(label => !hasRef(surface, label))
}

function isSurfaceGap(surface: SurfaceReadinessEntry): boolean {
  const mainGateGap = surface.exposure_status === 'main' && !surface.meets_main_gate
  return mainGateGap || missingSurfaceVerificationRefs(surface).length > 0
}

export function summarizeSurfaceReadiness(surfaces: SurfaceReadinessEntry[]): SurfaceReadinessSummary {
  return {
    total: surfaces.length,
    main: surfaces.filter(surface => surface.exposure_status === 'main').length,
    lab: surfaces.filter(surface => surface.exposure_status === 'lab').length,
    diagnostic: surfaces.filter(surface => surface.exposure_status === 'diagnostic').length,
    hidden: surfaces.filter(surface => surface.hidden_from_nav).length,
    gaps: surfaces.filter(isSurfaceGap).length,
  }
}

export function filterSurfaceReadiness(
  surfaces: SurfaceReadinessEntry[],
  filter: SurfaceFilter,
): SurfaceReadinessEntry[] {
  if (filter === 'all') return surfaces
  if (filter === 'gaps') return surfaces.filter(isSurfaceGap)
  return surfaces.filter(surface => surface.exposure_status === filter)
}

function loadSurfaceReadiness(): Promise<void> {
  return surfaceReadiness.load(async () =>
    normalizeSurfaceReadinessPayload(await get<unknown>('/api/v1/dashboard/surface-readiness')))
}

export async function refreshSurfaceReadiness(): Promise<void> {
  await loadSurfaceReadiness()
}

function exposureTone(surface: SurfaceReadinessEntry): StatusChipTone {
  if (isSurfaceGap(surface)) return 'bad'
  if (surface.exposure_status === 'main') return 'ok'
  if (surface.exposure_status === 'lab') return 'neutral'
  if (surface.exposure_status === 'diagnostic') return 'warn'
  return 'neutral'
}

function SurfaceRefList({ refs }: { refs: SurfaceVerificationRef[] }) {
  if (refs.length === 0) {
    return html`<${EmptyState} message="No verification refs." compact />`
  }
  return html`
    <div class="mt-3 grid gap-1.5 text-3xs">
      ${refs.map(ref => html`
        <div class="v2-shell-row flex min-w-0 flex-wrap items-center gap-1.5">
          <span class="rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-hover)] px-1.5 py-0.5 text-[var(--color-fg-muted)]">
            ${ref.label}
          </span>
          <span class="text-[var(--color-fg-disabled)]">${ref.kind}</span>
          <code class="min-w-0 break-all text-[var(--color-fg-secondary)]">${ref.value}</code>
        </div>
      `)}
    </div>
  `
}

function SurfaceCard({ surface }: { surface: SurfaceReadinessEntry }) {
  const missingRefs = missingSurfaceVerificationRefs(surface)
  return html`
    <article class="v2-shell-card rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3">
      <div class="flex flex-col gap-2 md:flex-row md:items-start md:justify-between">
        <div class="min-w-0">
          <div class="flex flex-wrap items-center gap-2">
            <div class="text-sm font-medium text-[var(--color-fg-primary)]">${surface.label}</div>
            <${StatusChip} tone=${exposureTone(surface)}>${surface.exposure_status}<//>
            ${surface.hidden_from_nav
              ? html`<${StatusChip} tone="warn">hidden<//>`
              : html`<${StatusChip} tone="ok">nav<//>`}
            ${surface.meets_main_gate
              ? html`<${StatusChip} tone="ok">gate<//>`
              : html`<${StatusChip} tone="neutral">no gate<//>`}
          </div>
          <div class="mt-1 flex flex-wrap items-center gap-1.5 text-3xs text-[var(--color-fg-muted)]">
            <code>${surface.id}</code>
            ${surface.route_hash ? html`<span>${surface.route_hash}</span>` : null}
            ${surface.verification_ref_bar ? html`<span>${surface.verification_ref_bar}</span>` : null}
          </div>
          ${surface.rationale
            ? html`<div class="mt-2 text-2xs leading-relaxed text-[var(--color-fg-secondary)]">${surface.rationale}</div>`
            : null}
        </div>
        ${missingRefs.length > 0
          ? html`
            <div class="v2-shell-detail rounded-[var(--r-1)] border border-[var(--bad-20)] bg-[var(--bad-10)] px-2 py-1 text-3xs text-[var(--bad-light)]">
              missing ${missingRefs.join(', ')}
            </div>
          `
          : null}
      </div>
      <${SurfaceRefList} refs=${surface.verification_refs} />
    </article>
  `
}

function SurfaceReadinessBody({ data }: { data: SurfaceReadinessData }) {
  const summary = summarizeSurfaceReadiness(data.surfaces)
  const filtered = filterSurfaceReadiness(data.surfaces, activeFilter.value)
  return html`
    <div class="space-y-4">
      <div class="v2-shell-panel rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] p-4">
        <div class="flex flex-col gap-3 xl:flex-row xl:items-start xl:justify-between">
          <div class="min-w-0">
            <div class="text-2xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">
              Surface Readiness
            </div>
            <div class="mt-2 text-2xl font-semibold text-[var(--color-fg-primary)]">
              ${summary.main} main / ${summary.total} total
            </div>
            <div class="mt-1 text-3xs text-[var(--color-fg-muted)]">
              generated ${data.generated_at ? formatTimeAgoEn(data.generated_at) : 'unknown'}
            </div>
          </div>
          <${KpiStripView}
            ariaLabel="Surface readiness summary"
            cols=${3}
            cells=${[
              { variant: 'stacked', label: 'lab', value: summary.lab },
              { variant: 'stacked', label: 'diagnostic', value: summary.diagnostic },
              { variant: 'stacked', label: 'hidden', value: summary.hidden },
              { variant: 'stacked', label: 'gaps', value: summary.gaps },
              { variant: 'stacked', label: 'refs', value: data.verification_ref_bar || 'n/a' },
              { variant: 'stacked', label: 'filter', value: activeFilter.value },
            ] satisfies KpiStripViewData['cells']}
          />
        </div>
      </div>

      <${FilterChips}
        chips=${FILTERS.map(filter => ({
          ...filter,
          count: filter.key === 'all'
            ? summary.total
            : filter.key === 'gaps'
              ? summary.gaps
              : summary[filter.key],
        }))}
        active=${activeFilter}
        tone="accent"
      />

      <div class="grid grid-cols-1 gap-3 xl:grid-cols-2">
        ${filtered.length === 0
          ? html`<${EmptyState} message="No surfaces match the filter." compact />`
          : filtered.map(surface => html`<${SurfaceCard} key=${surface.id} surface=${surface} />`)}
      </div>
    </div>
  `
}

export function SurfaceReadinessPanel() {
  useEffect(() => {
    void loadSurfaceReadiness()
  }, [])

  return html`
    <${SectionCard} label="Surface Readiness" class="section">
      <${AsyncContainer}
        state=${surfaceReadiness.state}
        loadingMessage="Loading surface readiness..."
        emptyWhen=${(data: SurfaceReadinessData) => data.surfaces.length === 0}
        emptyMessage="No dashboard surfaces are registered."
        render=${(data: SurfaceReadinessData) => html`<${SurfaceReadinessBody} data=${data} />`}
      />
    <//>
  `
}
