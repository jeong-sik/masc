// CascadeConfigPanel — renders cascade.json profiles + health tracker state
// side-by-side so operators can see *why* a given provider is picked first.
//
// Consumes:
//   GET /api/v1/cascade/config  — profiles + per-candidate weight/health
//   GET /api/v1/cascade/health  — global health tracker snapshot
//
// Pattern mirrors RuntimeMonitor: managed async resource + manual refresh.

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import { fetchGateKeepers, type GateKeeperInfo } from '../api/gate'
import {
  fetchCascadeClientCapacity,
  fetchCascadeClientCapacityHistory,
  fetchCascadeStrategyTrace,
  fetchCascadeSlo,
  fetchCascadeConfig,
  fetchCascadeConfigRaw,
  fetchCascadeHealth,
  updateCascadeConfigRaw,
  updateKeeperCascade,
  type CascadeCandidate,
  type CascadeCapacityEventKind,
  type CascadeClientCapacityEntry,
  type CascadeClientCapacityHistoryEvent,
  type CascadeClientCapacityHistoryResponse,
  type CascadeClientCapacityResponse,
  type CascadeConfigResponse,
  type CascadeHealthProvider,
  type CascadeHealthResponse,
  type CascadeProviderStatus,
  type CascadeInvalidProfile,
  type CascadeKeeperProfile,
  type CascadeProfile,
  type CascadeRawConfigResponse,
  type CascadeStrategyTraceEvent,
  type CascadeStrategyTraceKind,
  type CascadeStrategyTraceResponse,
  type CascadeSloResponse,
  type CascadeSloStatus,
  type CascadeValidationStatus,
} from '../api/dashboard'
import { Card } from './common/card'
import { EmptyState } from './common/empty-state'
import { ErrorState, LoadingState } from './common/feedback-state'
import { TextInput } from './common/input'
import { StatCell } from './common/stat-cell'
import { StatusChip } from './common/status-chip'
import type { ManagedAsyncResource } from '../lib/async-state'
import { useManagedAsyncResource } from '../lib/use-managed-async-resource'

interface CascadeData {
  config: CascadeConfigResponse | null
  rawConfig: CascadeRawConfigResponse | null
  gateKeepers: GateKeeperInfo[]
  health: CascadeHealthResponse | null
  capacity: CascadeClientCapacityResponse | null
  history: CascadeClientCapacityHistoryResponse | null
  trace: CascadeStrategyTraceResponse | null
  slo: CascadeSloResponse | null
}

async function loadCascadeData(resource: ManagedAsyncResource<CascadeData>) {
  await resource.load(async (signal) => {
    const gateKeepersPromise = fetchGateKeepers(signal)
      .then(data => data.keepers)
      .catch((error) => {
        if (signal.aborted) throw error
        return []
      })
    const [config, rawConfig, gateKeepers, health, capacity, history, trace, slo] = await Promise.all([
      fetchCascadeConfig({ signal }),
      fetchCascadeConfigRaw({ signal }),
      gateKeepersPromise,
      fetchCascadeHealth({ signal }),
      fetchCascadeClientCapacity({ signal }),
      fetchCascadeClientCapacityHistory({ limit: 50, signal }),
      fetchCascadeStrategyTrace({ limit: 50, signal }),
      fetchCascadeSlo({ signal }),
    ])
    return { config, rawConfig, gateKeepers, health, capacity, history, trace, slo }
  })
}

export function fmtPct(value: number): string {
  if (Number.isNaN(value)) return '--'
  return `${(value * 100).toFixed(1)}%`
}

export function candidateTone(c: CascadeCandidate): string {
  if (c.in_cooldown) return 'bad'
  if (c.effective_weight === 0) return 'bad'
  if (c.success_rate < 0.5) return 'bad'
  if (c.success_rate < 0.9) return 'warn'
  return 'ok'
}

export function sourceLabel(source: CascadeProfile['source']): string {
  switch (source) {
    case 'named': return 'named'
    case 'default_fallback': return 'default'
    case 'hardcoded_defaults': return 'hardcoded'
  }
}

export function sourceTone(source: CascadeProfile['source']): string {
  switch (source) {
    case 'named': return 'ok'
    case 'default_fallback': return 'warn'
    case 'hardcoded_defaults': return 'warn'
  }
}

export function catalogSourceSummary(config: CascadeConfigResponse): string {
  if (config.source_kind === 'toml') {
    const sourcePath = config.source_path ?? 'cascade.toml'
    const jsonPath = config.config_path ?? 'cascade.json'
    return `SSOT: ${sourcePath} → generated ${jsonPath}`
  }
  const path = config.source_path ?? config.config_path ?? 'config 없음'
  return `SSOT: ${path} (direct runtime edit)`
}

interface RawConfigModeSummary {
  title: string
  primary: string
  secondary: string
  saveLabel: string
  previewTitle: string | null
}

export function rawConfigModeSummary(
  raw: Pick<
    CascadeRawConfigResponse,
    'source_kind' | 'source_path' | 'config_path'
  > | null,
): RawConfigModeSummary {
  const sourcePath = raw?.source_path ?? raw?.config_path ?? 'unresolved'
  const jsonPath = raw?.config_path ?? 'unresolved'
  if (raw?.source_kind !== 'toml') {
    return {
      title: 'Active Cascade Source Editor',
      primary:
        `dashboard에서 직접 ${sourcePath} 를 수정합니다. 저장 경로는 ${jsonPath} 이고, ` +
        '저장 후 current cascade snapshot 을 다시 읽습니다.',
      secondary:
        'semantics invalid profile 도 저장은 허용됩니다. 저장 후 위의 validation banner 에서 invalid/last-known-good 상태를 바로 확인하면 됩니다.',
      saveLabel: 'Save cascade.json',
      previewTitle: null,
    }
  }
  return {
    title: 'Active Cascade Source Editor (TOML SSOT)',
    primary:
      `현재 active source는 ${sourcePath} 이고, 이 editor에서 직접 cascade.toml SSOT 를 수정합니다. ` +
      '저장 시 TOML parse 검증 뒤 generated runtime JSON을 다시 materialize 합니다.',
    secondary:
      `아래 preview는 ${jsonPath} 에 기록되는 generated cascade.json runtime artifact 입니다.`,
    saveLabel: 'Save cascade.toml',
    previewTitle: 'Generated cascade.json Preview',
  }
}

export function profileSummaryText(
  profile: CascadeProfile,
  keepers: readonly KeeperCascadeRow[],
): string {
  const parts = [
    `${profile.candidates.length} candidate${profile.candidates.length === 1 ? '' : 's'}`,
  ]
  if (profile.keeper_assignable || keepers.length > 0) {
    parts.push(`${keepers.length} keeper${keepers.length === 1 ? '' : 's'}`)
  }
  return parts.join(' · ')
}

export function profileKeeperAssignmentNote(
  profile: CascadeProfile,
  keepers: readonly KeeperCascadeRow[],
): string | null {
  if (!profile.keeper_assignable) {
    return keepers.length === 0
      ? 'manual/system-only profile; not assigned to keepers by design'
      : 'manual/system-only profile; current keepers still reference it'
  }
  if (keepers.length === 0) return 'no keepers assigned'
  return null
}

export function availableKeeperAssignments(
  keeperNames: readonly string[],
  keepers: readonly KeeperCascadeRow[],
): string[] {
  const assigned = new Set(keepers.map(keeper => keeper.keeper))
  return Array.from(
    new Set(
      keeperNames
        .map(name => name.trim())
        .filter(Boolean)
        .filter(name => !assigned.has(name)),
    ),
  ).sort((left, right) => left.localeCompare(right))
}

export function validateSourceConfigText(
  raw: Pick<CascadeRawConfigResponse, 'source_kind'> | null,
  sourceText: string,
): string | null {
  if (!raw) return null
  if (raw?.source_kind === 'toml') return null
  return validateJsonText(sourceText)
}

function validationTone(status: CascadeValidationStatus): 'ok' | 'warn' | 'bad' {
  switch (status) {
    case 'validated': return 'ok'
    case 'serving_valid_subset': return 'warn'
    case 'serving_last_known_good': return 'warn'
    case 'invalid': return 'bad'
  }
}

function validationLabel(status: CascadeValidationStatus): string {
  switch (status) {
    case 'validated': return 'validated'
    case 'serving_valid_subset': return 'valid subset'
    case 'serving_last_known_good': return 'last known good'
    case 'invalid': return 'invalid'
  }
}

function validationDescription(status: CascadeValidationStatus): string {
  switch (status) {
    case 'validated':
      return '현재 cascade catalog 이 정상 검증되었습니다.'
    case 'serving_valid_subset':
      return '현재 cascade.json 일부 profile 이 검증에 실패해 invalid profile 은 제외하고 유효한 subset 만 계속 서빙 중입니다.'
    case 'serving_last_known_good':
      return '새 cascade.json 업데이트가 검증에 실패해 마지막 검증 성공 snapshot 을 계속 서빙 중입니다.'
    case 'invalid':
      return '현재 cascade.json 검증에 실패했습니다. 서버와 dashboard 는 degraded 로 계속 동작하지만 유효하지 않은 profile 은 라우팅에서 제외될 수 있습니다.'
  }
}

function runtimeKindLabel(kind: string | null | undefined): string | null {
  switch (kind) {
    case 'cli_agent': return 'CLI(non-interactive)'
    case 'direct_api': return 'Direct API'
    case 'local': return 'Local'
    default: return null
  }
}

function fmtCooldownExpiry(expiresAt: number | null): string {
  if (expiresAt == null) return '—'
  const delta = expiresAt - Date.now() / 1000
  if (delta <= 0) return '만료됨'
  if (delta < 60) return `${Math.ceil(delta)}초 후`
  return `${Math.ceil(delta / 60)}분 후`
}

interface KeeperCascadeRow {
  keeper: string
  /** Declared cascade name from TOML / runtime JSON (pre-canonicalize). */
  raw_cascade_name: string
  /** True when the declared cascade differs from its canonical form. */
  drift: boolean
}

/**
 * Group keeper mapping rows by canonical cascade name.
 *
 * Pure. Returns a Map keyed on canonical name so the caller iterates
 * in stable insertion order.  Input is never mutated.  Keepers whose
 * canonical name does not match any declared profile still get a
 * bucket — callers decide how to surface the orphan case.
 */
export function groupKeepersByCanonicalCascade(
  keepers: readonly CascadeKeeperProfile[],
): Map<string, KeeperCascadeRow[]> {
  const map = new Map<string, KeeperCascadeRow[]>()
  for (const k of keepers) {
    const row: KeeperCascadeRow = {
      keeper: k.keeper,
      raw_cascade_name: k.cascade_name,
      drift: k.cascade_name !== k.canonical,
    }
    const existing = map.get(k.canonical)
    if (existing) existing.push(row)
    else map.set(k.canonical, [row])
  }
  return map
}

/**
 * Keepers whose canonical cascade is not declared in the current
 * profile list.  Should be empty in steady state — if non-empty it
 * indicates the dashboard's {@link CascadeConfigResponse.profiles}
 * and {@link CascadeConfigResponse.keeper_profiles} drifted
 * (e.g. a keeper registered a canonical we do not know about).
 *
 * Pure.  Uses a Set for O(1) membership checks against the (small)
 * declared profile list.
 */
export function keepersWithUnknownCanonical(
  profiles: readonly CascadeProfile[],
  keepers: readonly CascadeKeeperProfile[],
): CascadeKeeperProfile[] {
  const known = new Set(profiles.map(p => p.name))
  return keepers.filter(k => !known.has(k.canonical))
}

function KeeperChip({ row }: { row: KeeperCascadeRow }) {
  const base = 'rounded border px-2 py-0.5 text-xs flex items-center gap-1'
  const borderTone = row.drift
    ? 'border-[var(--warn)] text-[var(--text-strong)]'
    : 'border-[var(--card-border)] text-[var(--text-strong)]'
  return html`
    <span
      class=${`${base} ${borderTone}`}
      title=${row.drift
        ? `declared: ${row.raw_cascade_name} (canonicalized here)`
        : row.keeper}
    >
      <span class="font-semibold">${row.keeper}</span>
      ${row.drift
        ? html`<code class="text-3xs text-[var(--text-muted)]">${row.raw_cascade_name}</code>`
        : null}
    </span>
  `
}

function ProfileCard({
  profile,
  keepers,
  keeperNames,
  onAssignKeeper,
}: {
  profile: CascadeProfile
  keepers: readonly KeeperCascadeRow[]
  keeperNames: readonly string[]
  onAssignKeeper: (keeperName: string, cascadeName: string) => Promise<void>
}) {
  const driftCount = keepers.reduce((n, k) => n + (k.drift ? 1 : 0), 0)
  const assignmentNote = profileKeeperAssignmentNote(profile, keepers)
  const availableKeepers = availableKeeperAssignments(keeperNames, keepers)
  const selectedKeeper = useSignal(availableKeepers[0] ?? '')
  const assignmentMessage = useSignal<string | null>(null)
  const assigning = useSignal(false)

  useEffect(() => {
    if (availableKeepers.includes(selectedKeeper.value)) return
    selectedKeeper.value = availableKeepers[0] ?? ''
  }, [profile.name, availableKeepers.join('\u0000')])

  const handleAssignKeeper = async (event: Event) => {
    event.preventDefault()
    if (!profile.keeper_assignable || !selectedKeeper.value) return
    assigning.value = true
    assignmentMessage.value = null
    try {
      await onAssignKeeper(selectedKeeper.value, profile.name)
      assignmentMessage.value = `${selectedKeeper.value} → ${profile.name}`
    } catch (error) {
      assignmentMessage.value = `Failed to assign: ${errorMessage(error)}`
    } finally {
      assigning.value = false
    }
  }

  return html`
    <article class="rounded border border-[var(--card-border)] bg-[var(--bg-0)] p-3" role="group" aria-label=${`캐스케이드 프로필: ${profile.name}`}>
      <header class="flex items-center gap-2 mb-2 flex-wrap">
        <span class="font-semibold text-[var(--text-strong)]">${profile.name}</span>
        <${StatusChip} tone=${sourceTone(profile.source)}>
          ${sourceLabel(profile.source)}
        <//>
        ${!profile.keeper_assignable
          ? html`<${StatusChip} tone="neutral" uppercase=${false}>manual/system-only<//>`
          : null}
        <span class="text-xs text-[var(--text-muted)]">
          ${profileSummaryText(profile, keepers)}
        </span>
        ${driftCount > 0
          ? html`<${StatusChip} tone="warn">${driftCount} drift<//>`
          : null}
      </header>
      ${assignmentNote
        ? html`<div class="text-xs text-[var(--text-muted)] mb-2">${assignmentNote}</div>`
        : null}
      ${keepers.length > 0
        ? html`
          <div class="flex flex-wrap gap-1 mb-2">
            ${keepers.map(k => html`<${KeeperChip} row=${k} />`)}
          </div>
        `
        : null}
      ${profile.keeper_assignable
        ? html`
          <form
            aria-label="키퍼 할당"
            class="rounded border border-[var(--card-border)] bg-[var(--bg-panel)] p-2 mb-3"
            onSubmit=${handleAssignKeeper}
          >
            <div class="flex items-center gap-2 flex-wrap mb-2">
              <span class="text-xs font-medium text-[var(--text-strong)]">키퍼 할당</span>
              <span class="text-xs text-[var(--text-muted)]">
                current profile로 keeper를 이동합니다.
              </span>
            </div>
            ${availableKeepers.length > 0
              ? html`
                <div class="flex items-center gap-2 flex-wrap">
                  <select
                    aria-label="키퍼 선택"
                    class="min-w-44 rounded border border-[var(--card-border)] bg-[var(--bg-0)] px-2 py-1 text-xs text-[var(--text-strong)]"
                    value=${selectedKeeper.value}
                    disabled=${assigning.value}
                    onChange=${(event: Event) => {
                      selectedKeeper.value = (event.target as HTMLSelectElement).value
                      assignmentMessage.value = null
                    }}
                  >
                    ${availableKeepers.map(name => html`
                      <option value=${name}>${name}</option>
                    `)}
                  </select>
                  <button type="button"
                    type="submit"
                    class="rounded border border-[var(--accent-primary)] bg-[var(--accent-primary)] px-3 py-1 text-xs font-medium text-white hover:opacity-90 disabled:opacity-50"
                    disabled=${assigning.value || selectedKeeper.value === ''}
                  >
                    ${assigning.value ? 'Assigning...' : 'Assign keeper'}
                  </button>
                </div>
              `
              : html`
                <div class="text-xs text-[var(--text-muted)]">
                  currently known keepers are already assigned to this profile.
                </div>
              `}
            ${assignmentMessage.value
              ? html`
                <div
                  class=${`mt-2 text-xs ${
                    assignmentMessage.value.startsWith('Failed')
                      ? 'text-[var(--bad-light)]'
                      : 'text-[var(--text-muted)]'
                  }`}
                  role="status"
                >
                  ${assignmentMessage.value}
                </div>
              `
              : null}
          </form>
        `
        : null}
      ${profile.candidates.length === 0
        ? html`<div class="text-xs text-[var(--text-muted)]">no candidates resolved</div>`
        : html`
          <ol class="flex flex-col gap-1 text-xs" aria-label="캐스케이드 후보 순서">
            ${profile.candidates.map((c, idx) => {
              const expanded = c.expanded_models ?? []
              const displayModel = c.display_model ?? c.model
              const displayProvider = c.display_provider_name ?? c.provider_name ?? null
              const runtimeLabel = runtimeKindLabel(c.runtime_kind)
              return html`
              <li class="flex items-start gap-2 py-1 border-b border-[var(--card-border)] last:border-b-0">
                <span class="tabular-nums text-[var(--text-muted)] w-5">${idx + 1}.</span>
                <${StatusChip} tone=${candidateTone(c)}>
                  ${c.in_cooldown ? 'cooldown' : fmtPct(c.success_rate)}
                <//>
                <div class="flex-1 min-w-0">
                  <div class="flex items-center gap-2 flex-wrap">
                    <code class="text-[var(--text-strong)]">${displayModel}</code>
                    ${displayProvider
                      ? html`<span class="text-[var(--text-muted)]">${displayProvider}</span>`
                      : null}
                    ${runtimeLabel
                      ? html`<span class="text-[var(--text-muted)]">${runtimeLabel}</span>`
                      : null}
                  </div>
                  ${c.model !== displayModel
                    ? html`<div class="text-[11px] text-[var(--text-muted)] mt-0.5">config: <code>${c.model}</code></div>`
                    : null}
                  ${expanded.length > 1
                    ? html`
                      <ol class="mt-1 flex flex-col gap-0.5 text-[11px] text-[var(--text-muted)]" aria-label="확장 모델 목록">
                        ${expanded.map((model, expandedIdx) => html`
                          <li><span class="tabular-nums">${expandedIdx + 1}.</span> <code>${model}</code></li>
                        `)}
                      </ol>
                    `
                    : null}
                </div>
                <span class="tabular-nums text-[var(--text-muted)]">
                  w ${c.config_weight}${c.effective_weight === c.config_weight ? '' : ` → ${c.effective_weight}`}
                </span>
              </li>
            `})}
          </ol>
        `}
    </article>
  `
}

function OrphanKeeperList({ orphans }: { orphans: readonly CascadeKeeperProfile[] }) {
  if (orphans.length === 0) return null
  return html`
    <div class="rounded border border-[var(--warn)] bg-[var(--bg-0)] p-3 text-xs" role="alert">
      <div class="font-semibold text-[var(--text-strong)] mb-1">
        등록된 프로필 없음 (${orphans.length})
      </div>
      <div class="text-[var(--text-muted)] mb-2">
        아래 keeper 는 canonical cascade 가 현재 profile 목록에 없어 해당 cascade 로 라우팅할 수 없습니다.
      </div>
      <ul class="flex flex-col gap-1" aria-label="연결되지 않은 키퍼">
        ${orphans.map(o => html`
          <li class="flex gap-2">
            <span class="font-semibold text-[var(--text-strong)]">${o.keeper}</span>
            <code>${o.cascade_name}</code>
            <span class="text-[var(--text-muted)]">→</span>
            <code class="text-[var(--warn)]">${o.canonical}</code>
          </li>
        `)}
      </ul>
    </div>
  `
}

function InvalidProfileSummary({
  invalidProfile,
}: { invalidProfile: CascadeInvalidProfile }) {
  const firstError = invalidProfile.errors[0] ?? 'validation rejected'
  const extraErrors = Math.max(0, invalidProfile.errors.length - 1)
  return html`
    <li class="flex flex-wrap items-start gap-2">
      <code class="text-[var(--text-strong)]">${invalidProfile.name}</code>
      <span class="text-[var(--text-muted)]">${firstError}</span>
      ${extraErrors > 0
        ? html`<span class="text-[var(--text-muted)]">+${extraErrors} more</span>`
        : null}
    </li>
  `
}

function CascadeValidationBanner({ config }: { config: CascadeConfigResponse }) {
  if (config.validation_status === 'validated') return null
  const tone = validationTone(config.validation_status)
  const boxTone = tone === 'bad'
    ? 'border-[var(--bad)]/40 bg-[var(--bad)]/10'
    : 'border-[var(--warn)]/40 bg-[var(--warn)]/10'
  const visibleErrors = config.validation_errors.slice(0, 3)
  const visibleProfiles = config.invalid_profiles.slice(0, 4)
  return html`
    <div class=${`rounded border ${boxTone} p-3 text-xs mb-3`} role="alert">
      <div class="flex items-center gap-2 flex-wrap mb-2">
        <${StatusChip} tone=${tone}>${validationLabel(config.validation_status)}<//>
        <span class="text-[var(--text-muted)]">
          ${config.invalid_profiles.length} invalid profile${config.invalid_profiles.length === 1 ? '' : 's'}
          · ${config.validation_errors.length} error${config.validation_errors.length === 1 ? '' : 's'}
        </span>
      </div>
      <div class="text-[var(--text-strong)] mb-2">
        ${validationDescription(config.validation_status)}
      </div>
      ${visibleErrors.length > 0
        ? html`
          <ul class="flex flex-col gap-1 mb-2 text-[var(--text-muted)]">
            ${visibleErrors.map(error => html`<li>${error}</li>`)}
          </ul>
        `
        : null}
      ${visibleProfiles.length > 0
        ? html`
          <div class="text-[var(--text-strong)] mb-1">거부된 프로필</div>
          <ul class="flex flex-col gap-1 text-[var(--text-muted)]">
            ${visibleProfiles.map(invalidProfile => html`
              <${InvalidProfileSummary} invalidProfile=${invalidProfile} />
            `)}
          </ul>
        `
        : null}
      ${config.invalid_profiles.length > visibleProfiles.length
        ? html`
          <div class="mt-2 text-[var(--text-muted)]">
            + ${config.invalid_profiles.length - visibleProfiles.length} more invalid profiles
          </div>
        `
        : null}
    </div>
  `
}

export function providerTone(p: CascadeHealthProvider): 'ok' | 'warn' | 'bad' {
  if (p.in_cooldown) return 'bad'
  if (p.success_rate < 0.7) return 'bad'
  if (p.success_rate < 0.9) return 'warn'
  return 'ok'
}

/**
 * Status chip tone for the optional `status` field.
 *
 * - `active`: tracker recorded events in the window (ok).
 * - `cooldown`: actively blocked (bad).
 * - `configured`: declared but untouched — neutral. Rendering this
 *   explicitly answers "why is this provider not being used?" in a way
 *   that the previous "row is absent" encoding could not.
 */
export function providerStatusTone(
  status?: CascadeProviderStatus,
): 'ok' | 'warn' | 'bad' | 'neutral' {
  switch (status) {
    case 'active': return 'ok'
    case 'cooldown': return 'bad'
    case 'configured': return 'neutral'
    default: return 'neutral'
  }
}

/**
 * Format a `number | null | undefined` tok/s value for a table cell.
 *
 * The three empty cases render distinct labels so operators can tell
 * "backend did not report" from "reported zero":
 * - `undefined` (field absent on response, older server) → `—`
 * - `null` (aggregator ran, found nothing) → `no data`
 * - finite number → fixed(1)
 *
 * Zero is rendered as `0.0`, not collapsed to a dash.
 */
export function fmtPerfTokPerSec(
  value: number | null | undefined,
): string {
  if (value === undefined) return '—'
  if (value === null) return 'no data'
  return value.toFixed(1)
}

/**
 * Compact rendering of per-provider p50/p95 latency used in the Health
 * Tracker table.  Same empty-state rules as `fmtPerfTokPerSec`.
 */
export function fmtPerfLatencyPair(
  p50: number | null | undefined,
  p95: number | null | undefined,
): string {
  const fmt = (v: number | null | undefined) => {
    if (v === undefined) return '—'
    if (v === null) return 'ø'
    return Math.round(v).toString()
  }
  return `${fmt(p50)} / ${fmt(p95)} ms`
}

/**
 * Pure filter for Health Tracker provider rows.
 *
 * Case-insensitive substring match on `provider_key`. Also matches the
 * literal keyword `cooldown` when `in_cooldown` is true so operators can
 * isolate all providers currently being blocked.
 *
 * Empty/whitespace query returns the input reference unchanged so the
 * non-filter path preserves referential equality (stable render).
 *
 * Input is never mutated.
 */
export function filterHealthProviders(
  providers: readonly CascadeHealthProvider[],
  query: string,
): readonly CascadeHealthProvider[] {
  const needle = query.trim().toLowerCase()
  if (needle === '') return providers
  return providers.filter(p => {
    if (p.provider_key.toLowerCase().includes(needle)) return true
    if (p.in_cooldown && 'cooldown'.includes(needle)) return true
    return false
  })
}

const TONE_DOT: Record<string, string> = {
  ok: 'bg-[var(--ok)]',
  warn: 'bg-[var(--warn)]',
  bad: 'bg-[var(--bad)]',
}

function HealthTable({
  health,
  searchQuery,
}: { health: CascadeHealthResponse; searchQuery: { value: string } }) {
  if (health.providers.length === 0) {
    return html`<${EmptyState}>아직 기록된 provider 이벤트가 없습니다.<//>`
  }
  const filtered = filterHealthProviders(health.providers, searchQuery.value)
  const isFiltering = searchQuery.value.trim() !== ''
  return html`
    <div class="flex items-center gap-3 mb-2">
      <${TextInput}
        type="search"
        autoComplete="off"
        class="max-w-70"
        placeholder="provider 필터 (key, cooldown...)"
        ariaLabel="health provider 검색"
        value=${searchQuery.value}
        onInput=${(e: Event) => { searchQuery.value = (e.target as HTMLInputElement).value }}
      />
      ${isFiltering
        ? html`<span class="text-xs text-[var(--text-muted)]">${filtered.length}/${health.providers.length}건</span>`
        : null}
    </div>
    ${isFiltering && filtered.length === 0
      ? html`<div class="py-4 text-center text-2xs text-[var(--text-muted)]" role="status">필터 결과 없음 (${health.providers.length} providers)</div>`
      : html`
        <table class="w-full text-xs" aria-label="캐스케이드 공급자 상태">
          <thead>
            <tr class="text-[var(--text-muted)] border-b border-[var(--card-border)]">
              <th scope="col" class="text-left py-1 w-4"></th>
              <th scope="col" class="text-left py-1">공급자</th>
              <th
                scope="col"
                class="text-left py-1"
                title="운영 상태: active (최근 이벤트 있음), cooldown (차단됨), configured (선언됨, 미사용)"
              >상태</th>
              <th scope="col" class="text-right py-1">성공</th>
              <th scope="col" class="text-right py-1">연속 실패</th>
              <th scope="col" class="text-right py-1">이벤트</th>
              <th
                scope="col"
                class="text-right py-1"
                title="응답은 왔지만 accept 게이트에서 거부된 이벤트 수"
              >거부</th>
              <th
                scope="col"
                class="text-right py-1"
                title="프롬프트 프리필 처리량 (이 공급자 모델의 항목 가중 평균)"
              >프리필 tok/s</th>
              <th
                scope="col"
                class="text-right py-1"
                title="디코드 처리량 (예측 토큰/초, 항목 가중)"
              >디코드 tok/s</th>
              <th
                scope="col"
                class="text-right py-1"
                title="지연 p50 / p95 밀리초 (근사치: 모델별 백분위수의 가중 평균)"
              >지연 p50/p95</th>
              <th scope="col" class="text-right py-1">쿨다운</th>
            </tr>
          </thead>
          <tbody>
            ${filtered.map((p: CascadeHealthProvider) => {
              const tone = providerTone(p)
              const rejected = p.rejected_in_window ?? 0
              const status: CascadeProviderStatus | undefined = p.status
              // `declared = false` on a tracker-only row signals config
              // drift (provider was tracked but is no longer referenced
              // by cascade.json). Surface it next to the provider key so
              // operators can prune it. `undefined` means the server is
              // too old to carry the field — don't decorate in that case.
              const orphaned = p.declared === false
              return html`
              <tr class="border-b border-[var(--card-border)] last:border-b-0 even:bg-[var(--white-3)]">
                <td class="py-1"><span class=${`inline-block w-2 h-2 rounded-full ${TONE_DOT[tone]}`} aria-hidden="true"></span></td>
                <td class="py-1">
                  <code class="text-[var(--text-strong)]">${p.provider_key}</code>
                  ${orphaned
                    ? html`<span class="ml-1 text-2xs text-[var(--warn)]" title="공급자가 추적되었으나 cascade.json에 더 이상 선언되지 않음">orphan</span>`
                    : null}
                </td>
                <td class="py-1">
                  ${status
                    ? html`<${StatusChip} tone=${providerStatusTone(status)} uppercase=${false}>${status}<//>`
                    : html`<span class="text-[var(--text-muted)]">—</span>`}
                </td>
                <td class="py-1 text-right tabular-nums">${fmtPct(p.success_rate)}</td>
                <td class="py-1 text-right tabular-nums">${p.consecutive_failures}</td>
                <td class="py-1 text-right tabular-nums">${p.events_in_window}</td>
                <td class="py-1 text-right tabular-nums">
                  ${rejected > 0
                    ? html`<span class="text-[var(--warn)]">${rejected}</span>`
                    : html`<span class="text-[var(--text-muted)]">—</span>`}
                </td>
                <td class="py-1 text-right tabular-nums">${fmtPerfTokPerSec(p.avg_prompt_tok_per_sec)}</td>
                <td class="py-1 text-right tabular-nums">${fmtPerfTokPerSec(p.avg_decode_tok_per_sec)}</td>
                <td class="py-1 text-right tabular-nums">${fmtPerfLatencyPair(p.p50_latency_ms, p.p95_latency_ms)}</td>
                <td class="py-1 text-right">
                  ${p.in_cooldown
                    ? html`<${StatusChip} tone="bad">${fmtCooldownExpiry(p.cooldown_expires_at)}<//>`
                    : html`<span class="text-[var(--text-muted)]">—</span>`}
                </td>
              </tr>
            `})}
          </tbody>
        </table>
      `}
  `
}

export function capacityTone(entry: CascadeClientCapacityEntry): 'ok' | 'warn' | 'bad' {
  if (entry.total === 0) return 'bad'
  if (entry.available === 0) return 'warn'
  return 'ok'
}

function fmtRelativeTime(tsSec: number): string {
  const deltaSec = Date.now() / 1000 - tsSec
  if (!Number.isFinite(deltaSec) || deltaSec < 0) return '방금'
  if (deltaSec < 1) return '방금'
  if (deltaSec < 60) return `${Math.floor(deltaSec)}초 전`
  if (deltaSec < 3600) return `${Math.floor(deltaSec / 60)}분 전`
  if (deltaSec < 86400) return `${Math.floor(deltaSec / 3600)}시간 전`
  return `${Math.floor(deltaSec / 86400)}일 전`
}

export function eventKindTone(kind: CascadeCapacityEventKind): 'ok' | 'neutral' | 'bad' {
  switch (kind) {
    case 'acquired': return 'ok'
    case 'released': return 'neutral'
    case 'rejected_full': return 'bad'
  }
}

export function eventKindLabel(kind: CascadeCapacityEventKind): string {
  switch (kind) {
    case 'acquired': return 'acquired'
    case 'released': return 'released'
    case 'rejected_full': return 'rejected'
  }
}

export function capacityKindLabel(kind: CascadeClientCapacityEntry['kind']): string {
  switch (kind) {
    case 'cli': return 'CLI'
    case 'ollama': return 'Ollama'
    case 'other': return 'Other'
  }
}

export function traceKindTone(k: CascadeStrategyTraceKind): 'ok' | 'warn' | 'bad' {
  switch (k) {
    case 'ordered': return 'ok'
    case 'filtered_empty': return 'warn'
    case 'exhausted': return 'bad'
  }
}

export function traceKindLabel(k: CascadeStrategyTraceKind): string {
  switch (k) {
    case 'ordered': return '정렬'
    case 'filtered_empty': return '전부 차단'
    case 'exhausted': return '소진'
  }
}

export function traceEventMatchesSearch(
  e: CascadeStrategyTraceEvent,
  query: string,
): boolean {
  const q = query.toLowerCase()
  if (e.cascade_name.toLowerCase().includes(q)) return true
  if (e.strategy.toLowerCase().includes(q)) return true
  if (e.kind.toLowerCase().includes(q)) return true
  if (traceKindLabel(e.kind).toLowerCase().includes(q)) return true
  if (String(e.cycle).includes(q)) return true
  if (String(e.candidates_in).includes(q)) return true
  if (String(e.candidates_out).includes(q)) return true
  return false
}

function sloStatusTone(status: CascadeSloStatus): 'ok' | 'warn' | 'bad' {
  switch (status) {
    case 'ok': return 'ok'
    case 'warn': return 'warn'
    case 'violated': return 'bad'
  }
}

function sloStatusLabel(status: CascadeSloStatus): string {
  switch (status) {
    case 'ok': return '정상'
    case 'warn': return '경고'
    case 'violated': return '위반'
  }
}

function SloCard({ slo }: { slo: CascadeSloResponse }) {
  const tone = sloStatusTone(slo.status)
  const ratioPct = (slo.current.ordered_ratio * 100).toFixed(2)
  const targetPct = (slo.targets.ordered_ratio_min * 100).toFixed(0)
  const burn = slo.current.burn_rate.toFixed(2)
  const exh = slo.current.exhaustion_count
  const exhTarget = slo.targets.exhaustion_count_max
  const totalEvents = slo.current.total_events
  return html`
    <div class="flex flex-col gap-3">
      <div class="flex items-center gap-2 flex-wrap">
        <${StatusChip} tone=${tone}>${sloStatusLabel(slo.status)}<//>
        <span class="text-xs text-[var(--text-muted)]">sample ${totalEvents}/${slo.window_sample_size}</span>
        ${slo.violations.length > 0
          ? html`<span class="text-xs text-[var(--bad-light)]">violating: ${slo.violations.join(', ')}</span>`
          : null}
      </div>
      <div class="grid grid-cols-3 gap-3">
        <${StatCell}
          label="정렬 비율"
          value=${`${ratioPct}%`}
          detail=${`≥ ${targetPct}% 목표`}
        />
        <${StatCell}
          label="소진 (표본)"
          value=${String(exh)}
          detail=${`≤ ${exhTarget} 목표`}
        />
        <${StatCell}
          label="소진율"
          value=${burn}
          detail=${`≤ ${slo.targets.burn_rate_max.toFixed(1)} 목표`}
        />
      </div>
    </div>
  `
}

function StrategyTraceTable({
  trace,
  searchQuery,
}: { trace: CascadeStrategyTraceResponse; searchQuery: { value: string } }) {
  if (trace.events.length === 0) {
    return html`<${EmptyState}>최근 strategy decision 이 없습니다. (cascade 호출이 아직 발생하지 않음)<//>`
  }
  const query = searchQuery.value.trim().toLowerCase()
  const filtered = query
    ? trace.events.filter(e => traceEventMatchesSearch(e, query))
    : trace.events
  return html`
    ${query ? html`<div class="text-xs text-[var(--text-muted)] mb-2">${filtered.length}/${trace.events.length}건</div>` : null}
    <table class="w-full text-xs" aria-label="캐스케이드 전략 추적 이벤트">
      <thead>
        <tr class="text-[var(--text-muted)] border-b border-[var(--card-border)]">
          <th scope="col" class="text-left py-1 w-20">시간</th>
          <th scope="col" class="text-left py-1">캐스케이드</th>
          <th scope="col" class="text-left py-1">전략</th>
          <th scope="col" class="text-right py-1">사이클</th>
          <th scope="col" class="text-right py-1">입/출력</th>
          <th scope="col" class="text-right py-1">백오프(ms)</th>
          <th scope="col" class="text-left py-1">결과</th>
        </tr>
      </thead>
      <tbody>
        ${filtered.map((e: CascadeStrategyTraceEvent) => {
          const tone = traceKindTone(e.kind)
          return html`
          <tr class="border-b border-[var(--card-border)] last:border-b-0 even:bg-[var(--white-3)]">
            <td class="py-1 text-[var(--text-muted)] tabular-nums">${fmtRelativeTime(e.ts)}</td>
            <td class="py-1"><code class="text-[var(--text-strong)]">${e.cascade_name}</code></td>
            <td class="py-1 text-[var(--text-muted)]">${e.strategy}</td>
            <td class="py-1 text-right tabular-nums">${e.cycle}</td>
            <td class="py-1 text-right tabular-nums">${e.candidates_in}/${e.candidates_out}</td>
            <td class="py-1 text-right tabular-nums">${e.backoff_ms > 0 ? e.backoff_ms : '–'}</td>
            <td class="py-1"><${StatusChip} tone=${tone}>${traceKindLabel(e.kind)}<//></td>
          </tr>
        `})}
      </tbody>
    </table>
  `
}

function ClientCapacityHistoryTable({
  history,
}: { history: CascadeClientCapacityHistoryResponse }) {
  if (history.events.length === 0) {
    return html`<${EmptyState}>최근 capacity 이벤트가 없습니다. (acquire/release가 아직 발생하지 않음)<//>`
  }
  return html`
    <table class="w-full text-xs" aria-label="클라이언트 용량 이력">
      <thead>
        <tr class="text-[var(--text-muted)] border-b border-[var(--card-border)]">
          <th scope="col" class="text-left py-1 w-20">시간</th>
          <th scope="col" class="text-left py-1">종류</th>
          <th scope="col" class="text-left py-1">키</th>
          <th scope="col" class="text-right py-1">활성</th>
        </tr>
      </thead>
      <tbody>
        ${history.events.map((e: CascadeClientCapacityHistoryEvent) => {
          const tone = eventKindTone(e.kind)
          return html`
          <tr class="border-b border-[var(--card-border)] last:border-b-0 even:bg-[var(--white-3)]">
            <td class="py-1 text-[var(--text-muted)] tabular-nums">${fmtRelativeTime(e.ts)}</td>
            <td class="py-1"><${StatusChip} tone=${tone}>${eventKindLabel(e.kind)}<//></td>
            <td class="py-1"><code class="text-[var(--text-strong)]">${e.key}</code></td>
            <td class="py-1 text-right tabular-nums">${e.active_after}</td>
          </tr>
        `})}
      </tbody>
    </table>
  `
}

function ClientCapacityTable({ capacity }: { capacity: CascadeClientCapacityResponse }) {
  if (capacity.entries.length === 0) {
    return html`<${EmptyState}>등록된 client-capacity 슬롯이 없습니다. (cascade가 한 번도 호출되지 않았거나 CLI/ollama provider 미사용)<//>`
  }
  return html`
    <table class="w-full text-xs" aria-label="클라이언트 용량 슬롯">
      <thead>
        <tr class="text-[var(--text-muted)] border-b border-[var(--card-border)]">
          <th scope="col" class="text-left py-1 w-4"></th>
          <th scope="col" class="text-left py-1">종류</th>
          <th scope="col" class="text-left py-1">키</th>
          <th scope="col" class="text-right py-1">활성</th>
          <th scope="col" class="text-right py-1">가용</th>
          <th scope="col" class="text-right py-1">전체</th>
        </tr>
      </thead>
      <tbody>
        ${capacity.entries.map((e: CascadeClientCapacityEntry) => {
          const tone = capacityTone(e)
          return html`
          <tr class="border-b border-[var(--card-border)] last:border-b-0 even:bg-[var(--white-3)]">
            <td class="py-1"><span class=${`inline-block w-2 h-2 rounded-full ${TONE_DOT[tone]}`} aria-hidden="true"></span></td>
            <td class="py-1"><${StatusChip} tone=${tone === 'ok' ? 'neutral' : tone}>${capacityKindLabel(e.kind)}<//></td>
            <td class="py-1"><code class="text-[var(--text-strong)]">${e.key}</code></td>
            <td class="py-1 text-right tabular-nums">${e.active}</td>
            <td class="py-1 text-right tabular-nums">${e.available}</td>
            <td class="py-1 text-right tabular-nums">${e.total}</td>
          </tr>
        `})}
      </tbody>
    </table>
  `
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

function validateJsonText(raw: string): string | null {
  try {
    JSON.parse(raw)
    return null
  } catch (error) {
    return errorMessage(error)
  }
}

function CascadeRawConfigEditor({
  raw,
  onRefresh,
}: {
  raw: CascadeRawConfigResponse | null
  onRefresh: () => Promise<void>
}) {
  const editorText = useSignal(raw?.source_text ?? raw?.raw_json ?? '')
  const editorDirty = useSignal(false)
  const saving = useSignal(false)
  const saveMessage = useSignal<string | null>(null)
  const mode = rawConfigModeSummary(raw)
  const sourceEditable = raw?.source_editable !== false

  useEffect(() => {
    if (!raw || editorDirty.value) return
    editorText.value = raw.source_text
  }, [raw?.config_path, raw?.updated_at, raw?.source_path, raw?.source_text])

  const syntaxError = validateSourceConfigText(raw, editorText.value)
  const saveDisabled = saving.value
    || !editorDirty.value
    || !sourceEditable
    || raw?.config_path == null
    || syntaxError != null

  const handleReset = () => {
    editorText.value = raw?.source_text ?? raw?.raw_json ?? ''
    editorDirty.value = false
    saveMessage.value = 'Latest source snapshot restored in the editor.'
  }

  const handleSave = async (event: Event) => {
    event.preventDefault()
    const currentSyntaxError = validateSourceConfigText(raw, editorText.value)
    if (currentSyntaxError) {
      saveMessage.value = `Invalid JSON: ${currentSyntaxError}`
      return
    }
    if (raw?.config_path == null) {
      saveMessage.value = 'Resolved cascade config path is unavailable.'
      return
    }
    if (!sourceEditable) {
      saveMessage.value = `Active source is not editable: ${raw?.source_path ?? raw?.config_path ?? 'unresolved'}`
      return
    }
    saving.value = true
    saveMessage.value = null
    try {
      await updateCascadeConfigRaw(editorText.value)
      editorDirty.value = false
      saveMessage.value = 'Saved. Refreshing cascade snapshot...'
      try {
        await onRefresh()
        saveMessage.value = 'Saved successfully.'
      } catch (error) {
        saveMessage.value = `Saved, but refresh failed: ${errorMessage(error)}`
      }
    } catch (error) {
      saveMessage.value = `Failed to save: ${errorMessage(error)}`
    } finally {
      saving.value = false
    }
  }

  return html`
    <${Card} title=${mode.title}>
      <div class="flex flex-col gap-3 p-4">
        <p class="text-sm text-[var(--text-muted)]">${mode.primary}</p>
        <p class="text-xs text-[var(--text-muted)]">
          ${mode.secondary}
        </p>

        <form aria-label="설정 소스 편집" class="flex flex-col gap-3" onSubmit=${handleSave}>
          <textarea
            aria-label="설정 소스 편집"
            class="h-96 w-full rounded border border-[var(--card-border)] bg-[var(--bg-0)] px-3 py-2 font-mono text-xs text-[var(--text-strong)]"
            spellcheck="false"
            readonly=${!sourceEditable}
            value=${editorText.value}
            onInput=${(event: Event) => {
              editorText.value = (event.target as HTMLTextAreaElement).value
              editorDirty.value = true
              saveMessage.value = null
            }}
          />

          <div class="flex items-center gap-3 flex-wrap text-xs">
            <span class=${editorDirty.value ? 'text-[var(--warn)]' : 'text-[var(--text-muted)]'}>
              ${editorDirty.value ? 'unsaved changes' : 'in sync with disk'}
            </span>
            ${syntaxError
              ? html`<span class="text-[var(--bad-light)]" role="alert">syntax: ${syntaxError}</span>`
              : html`
                <span class="text-[var(--ok)]">
                  ${raw?.source_kind === 'toml' ? 'syntax: validated on save (TOML)' : 'syntax: valid JSON'}
                </span>
              `}
            ${saveMessage.value
              ? html`
                <span class=${saveMessage.value.startsWith('Failed') || saveMessage.value.startsWith('Invalid')
                  ? 'text-[var(--bad-light)]'
                  : 'text-[var(--text-muted)]'}
                  role="status"
                >
                  ${saveMessage.value}
                </span>
              `
              : null}
          </div>

          <div class="flex items-center gap-3 flex-wrap">
            <button type="button"
              type="submit"
              class="rounded border border-[var(--accent-primary)] bg-[var(--accent-primary)] px-3 py-1 text-xs font-medium text-white hover:opacity-90 disabled:opacity-50"
              disabled=${saveDisabled}
            >
              ${saving.value ? 'Saving...' : mode.saveLabel}
            </button>
            <button type="button"
              class="rounded border border-[var(--card-border)] bg-[var(--bg-0)] px-3 py-1 text-xs text-[var(--text-strong)] hover:bg-[var(--bg-panel-hover)] disabled:opacity-50"
              onClick=${handleReset}
              disabled=${saving.value || !editorDirty.value}
            >
              Reset to disk
            </button>
            <button type="button"
              class="rounded border border-[var(--card-border)] bg-[var(--bg-0)] px-3 py-1 text-xs text-[var(--text-strong)] hover:bg-[var(--bg-panel-hover)] disabled:opacity-50"
              onClick=${() => void onRefresh()}
              disabled=${saving.value}
            >
              Reload snapshot
            </button>
          </div>
        </form>
        ${mode.previewTitle
          ? html`
            <div class="flex flex-col gap-2">
              <div class="text-xs font-medium text-[var(--text-strong)]">
                ${mode.previewTitle}
              </div>
              <div class="text-xs text-[var(--text-muted)]">
                ${raw?.config_path ?? 'unresolved'}
              </div>
              <textarea
                aria-label="원본 JSON"
                class="h-72 w-full rounded border border-[var(--card-border)] bg-[var(--bg-0)] px-3 py-2 font-mono text-xs text-[var(--text-strong)]"
                spellcheck="false"
                readonly
                value=${raw?.raw_json ?? ''}
              />
            </div>
          `
          : null}
      </div>
    <//>
  `
}

export function CascadeConfigPanel() {
  const traceSearch = useSignal('')
  const healthSearch = useSignal('')
  const resource = useManagedAsyncResource<CascadeData>()

  useEffect(() => {
    void loadCascadeData(resource)
    const id = setInterval(() => void loadCascadeData(resource), 30_000)
    return () => { clearInterval(id); resource.cancel() }
  }, [resource])

  const current = resource.state.value
  const config = current.data?.config ?? null
  const rawConfig = current.data?.rawConfig ?? null
  const gateKeepers = current.data?.gateKeepers ?? []
  const health = current.data?.health ?? null
  const capacity = current.data?.capacity ?? null
  const history = current.data?.history ?? null
  const trace = current.data?.trace ?? null
  const slo = current.data?.slo ?? null

  return html`
    <div class="flex flex-col gap-4">
      <div class="flex items-center gap-3 flex-wrap">
        <button type="button"
          class="rounded border border-[var(--card-border)] bg-[var(--bg-0)] px-3 py-1 text-xs text-[var(--text-strong)] hover:bg-[var(--bg-panel-hover)]"
          aria-label="캐스케이드 데이터 새로고침"
          onClick=${() => void loadCascadeData(resource)}
        >
          새로고침
        </button>
        ${current.loading ? html`<span class="text-xs text-[var(--text-muted)]" role="status">로딩 중...</span>` : null}
        ${config?.updated_at
          ? html`<span class="text-xs text-[var(--text-muted)]">config · ${config.updated_at}</span>`
          : null}
      </div>

      ${current.error ? html`<${ErrorState} message=${current.error} />` : null}

      ${current.loading && !config && !rawConfig && !health
        ? html`<${LoadingState}>cascade snapshot 불러오는 중...<//>`
        : null}

      <${Card} title="캐스케이드 라우팅">
        ${config
          ? (() => {
              const keeperGroups = groupKeepersByCanonicalCascade(config.keeper_profiles)
              const orphans = keepersWithUnknownCanonical(config.profiles, config.keeper_profiles)
              const keeperNames = Array.from(new Set([
                ...gateKeepers.map(keeper => keeper.name),
                ...config.keeper_profiles.map(keeper => keeper.keeper),
              ])).sort((left, right) => left.localeCompare(right))
              const driftTotal = config.keeper_profiles.reduce(
                (n, k) => n + (k.cascade_name !== k.canonical ? 1 : 0),
                0,
              )
              return html`
                <${CascadeValidationBanner} config=${config} />
                <div class="grid grid-cols-3 gap-3 mb-3">
                  <${StatCell}
                    label="프로필"
                    value=${config.profiles.length}
                    detail=${catalogSourceSummary(config)}
                  />
                  <${StatCell}
                    label="키퍼"
                    value=${config.keeper_profiles.length}
                    detail="cascade_name 등록됨"
                  />
                  <${StatCell}
                    label="드리프트"
                    value=${driftTotal}
                    detail="raw ≠ canonical"
                  />
                </div>
                ${config.profiles.length === 0
                  ? html`<${EmptyState}>표시할 유효 cascade profile 이 없습니다.<//>`
                  : html`
                    <div class="grid gap-3 md:grid-cols-2 mb-3">
                      ${config.profiles.map(p => html`
                        <${ProfileCard}
                          profile=${p}
                          keepers=${keeperGroups.get(p.name) ?? []}
                          keeperNames=${keeperNames}
                          onAssignKeeper=${async (keeperName: string, cascadeName: string) => {
                            await updateKeeperCascade(keeperName, cascadeName)
                            await loadCascadeData(resource)
                          }}
                        />
                      `)}
                    </div>
                  `}
                <${OrphanKeeperList} orphans=${orphans} />
              `
            })()
          : null}
      <//>

      <${CascadeRawConfigEditor}
        raw=${rawConfig}
        onRefresh=${() => loadCascadeData(resource)}
      />

      <${Card} title="상태 추적기">
        ${health
          ? html`
            <div class="grid grid-cols-3 gap-3 mb-3">
              <${StatCell}
                label="윈도우"
                value=${`${health.window_sec}s`}
                detail=${`${health.providers.length} 추적`}
              />
              <${StatCell}
                label="쿨다운 임계값"
                value=${health.cooldown_threshold}
                detail="연속 실패"
              />
              <${StatCell}
                label="Cooldown"
                value=${`${health.cooldown_sec}s`}
                detail="활성 시 차단 시간"
              />
            </div>
            <${HealthTable} health=${health} searchQuery=${healthSearch} />
          `
          : null}
      <//>

      <${Card} title="클라이언트 용량">
        ${capacity
          ? html`<${ClientCapacityTable} capacity=${capacity} />`
          : null}
      <//>

      <${Card} title="클라이언트 용량 · 최근 이벤트">
        ${history
          ? html`<${ClientCapacityHistoryTable} history=${history} />`
          : null}
      <//>

      <${Card} title="SLO 상태">
        ${slo
          ? html`<${SloCard} slo=${slo} />`
          : html`<${EmptyState}>SLO 데이터를 불러오는 중입니다.<//>`}
      <//>

      <${Card} title="전략 결정 · 사이클 추적">
        ${trace
          ? html`
            <div class="flex items-center gap-3 mb-3">
              <${TextInput}
                class="max-w-70"
                placeholder="검색 (cascade, strategy, 결과...)"
                ariaLabel="strategy trace 검색"
                value=${traceSearch.value}
                onInput=${(e: Event) => { traceSearch.value = (e.target as HTMLInputElement).value }}
              />
            </div>
            <${StrategyTraceTable} trace=${trace} searchQuery=${traceSearch} />
          `
          : null}
      <//>
    </div>
  `
}
