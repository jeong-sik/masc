// Keeper runtime editor — a prominent, one-expand-away card that lets an
// operator change which runtime lane a keeper dispatches on.
//
// RFC-0207: a keeper's runtime selection lives in a SINGLE surface —
// runtime.toml [runtime.assignments]. The detailed view of that assignment is
// buried under 설정 → Keeper 설정 → 소스. This card surfaces the same assignment
// at the top of the keeper detail's 진단/운영 section so it is discoverable
// without digging.
//
// State is SHARED with keeper-config-panel via [configState]/[loadKeeperConfig]
// (read) and [applyKeeperConfigUpdate] (write) so the two surfaces never show
// divergent values for the same keeper. No second fetch, no drift.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { patchKeeperConfig, type DashboardRuntimeProviderSnapshot } from '../api/dashboard'
import type { KeeperConfig } from '../types'
import {
  InlineSelectRow,
  applyKeeperConfigUpdate,
  loadKeeperConfig,
  peekKeeperConfigLoadStatus,
  peekLoadedKeeperConfig,
} from './keeper-config-panel'
import { showToast } from './common/toast'
import { ErrorState, LoadingState } from './common/feedback-state'
import { BTN_FILLED_BASE } from './common/button-filled-base'
import { MISSING_DATA_DASH } from '../lib/format-string'
import { formatContextTokens } from '../lib/format-number'
import {
  findRuntimeCatalogEntry,
  loadRuntimeCatalog,
  runtimeCatalogState,
} from '../lib/runtime-catalog-resource'
import {
  runtimeCatalogDeclaredSpec,
  runtimeCatalogEffectiveCapabilities,
  runtimeCatalogParameterPolicy,
  runtimeCatalogRequestConfig,
  runtimeCatalogSnapshotFacts,
} from '../lib/runtime-provider-summary'
import { refreshKeeperRuntimeStatus } from '../store'

// Pending dropdown selection before save. `null` = no pending change (show the
// server's current value). Module-level singleton: at most one editor renders at
// a time (one keeper detail page), mirroring keeper-config-panel's draft signals.
const modelDraft = signal<string | null>(null)
// Which keeper [modelDraft] belongs to. Guards against a stale pending selection
// leaking across keeper navigation (A's dropdown choice showing up on B).
const modelDraftKeeper = signal<string>('')
const modelSaving = signal(false)

/** Dedupe + drop empty, preserving first-seen order. */
export function uniqueNonEmpty(values: readonly string[]): string[] {
  const out: string[] = []
  const seen = new Set<string>()
  for (const raw of values) {
    const v = raw.trim()
    if (v === '' || seen.has(v)) continue
    seen.add(v)
    out.push(v)
  }
  return out
}

/**
 * Editable only when the keeper has a writable TOML-backed config source.
 * persona-only / generated keepers have no manifest to patch. Mirrors the
 * `runtimeCanEdit` gate in keeper-config-panel so the two surfaces agree.
 */
export function canEditRuntime(c: KeeperConfig): boolean {
  return c.sources.default_source_kind === 'toml' && Boolean(c.sources.default_manifest_path)
}

function RuntimeCapabilityPill({ label, value }: { label: string; value: boolean | undefined }) {
  const enabled = value === true
  const tone = enabled
    ? 'border-[var(--ok-20)] bg-[var(--ok-10)] text-[var(--color-status-ok)]'
    : 'border-[var(--color-border-subtle)] bg-[var(--color-bg-surface)] text-[var(--color-fg-muted)]'
  return html`
    <span class="rounded-[var(--r-1)] border px-2 py-0.5 text-3xs font-semibold uppercase tracking-[var(--track-caps)] ${tone}">
      ${label} ${enabled ? 'on' : 'off'}
    </span>
  `
}

function RuntimeCatalogDetailRow({ label, value }: { label: string; value: string }) {
  return html`
    <div class="min-w-0 rounded-[var(--r-1)] border border-[var(--color-border-subtle)]/70 bg-[var(--color-bg-surface)]/45 px-2 py-1">
      <div class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">${label}</div>
      <div class="break-words font-mono text-3xs leading-relaxed text-[var(--color-fg-secondary)]" title=${value}>${value}</div>
    </div>
  `
}

function RuntimeCatalogSummary({
  runtimeId,
  entry,
  status,
}: {
  runtimeId: string
  entry: DashboardRuntimeProviderSnapshot | null
  status: 'idle' | 'loading' | 'loaded' | 'error'
}) {
  if (status === 'loading' || status === 'idle') {
    return html`
      <div class="border-t border-[var(--accent-20)] pt-2 text-2xs text-[var(--color-fg-muted)]">
        runtime catalog 로딩 중...
      </div>
    `
  }
  if (status === 'error') {
    return html`
      <div class="border-t border-[var(--warn-20)] pt-2 text-2xs text-[var(--color-status-warn)]">
        runtime catalog 정보를 불러오지 못했습니다.
      </div>
    `
  }
  if (!entry) {
    return html`
      <div class="border-t border-[var(--warn-20)] pt-2 text-2xs text-[var(--color-status-warn)]">
        catalog 미등록 runtime: <code>${runtimeId || MISSING_DATA_DASH}</code>
      </div>
    `
  }
  const provider = entry.provider_display_name ?? entry.provider_id ?? MISSING_DATA_DASH
  const model = entry.model_api_name ?? entry.model_id ?? MISSING_DATA_DASH
  const endpoint = entry.endpoint_url ?? entry.transport ?? MISSING_DATA_DASH
  const snapshotFacts = runtimeCatalogSnapshotFacts(entry)
  const effectiveCapabilities = runtimeCatalogEffectiveCapabilities(entry)
  const declaredSpec = runtimeCatalogDeclaredSpec(entry)
  const parameterPolicy = runtimeCatalogParameterPolicy(entry)
  const requestConfig = runtimeCatalogRequestConfig(entry)
  return html`
    <div class="border-t border-[var(--accent-20)] pt-2">
      <div class="grid gap-2 md:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]">
        <div class="min-w-0">
          <div class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">provider</div>
          <div class="truncate text-sm font-semibold text-[var(--color-fg-primary)]">${provider}</div>
          <div class="truncate font-mono text-3xs text-[var(--color-fg-muted)]">${entry.protocol ?? MISSING_DATA_DASH} · ${entry.auth_kind ?? 'auth unknown'}</div>
        </div>
        <div class="min-w-0">
          <div class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">model</div>
          <div class="truncate text-sm font-semibold text-[var(--color-fg-primary)]">${model}</div>
          <div class="truncate font-mono text-3xs text-[var(--color-fg-muted)]">${formatContextTokens(entry.max_context) ?? MISSING_DATA_DASH}</div>
        </div>
      </div>
      <div class="mt-2 flex flex-wrap gap-1.5">
        <${RuntimeCapabilityPill} label="tools" value=${entry.tools_support} />
        <${RuntimeCapabilityPill} label="thinking" value=${entry.thinking_support} />
        <${RuntimeCapabilityPill} label="stream" value=${entry.streaming} />
        <${RuntimeCapabilityPill} label="json" value=${entry.supports_response_format_json} />
        <${RuntimeCapabilityPill} label="schema" value=${entry.supports_structured_output} />
        <${RuntimeCapabilityPill} label="multimodal" value=${entry.supports_multimodal_inputs} />
        <${RuntimeCapabilityPill} label="reasoning-budget" value=${entry.supports_reasoning_budget} />
      </div>
      ${snapshotFacts || effectiveCapabilities || declaredSpec || parameterPolicy || requestConfig
        ? html`
            <div class="mt-2 grid gap-1.5">
              ${snapshotFacts ? html`<${RuntimeCatalogDetailRow} label="snapshot" value=${snapshotFacts} />` : null}
              ${effectiveCapabilities ? html`<${RuntimeCatalogDetailRow} label="effective" value=${effectiveCapabilities} />` : null}
              ${declaredSpec ? html`<${RuntimeCatalogDetailRow} label="declared" value=${declaredSpec} />` : null}
              ${parameterPolicy ? html`<${RuntimeCatalogDetailRow} label="policy" value=${parameterPolicy} />` : null}
              ${requestConfig ? html`<${RuntimeCatalogDetailRow} label="request" value=${requestConfig} />` : null}
            </div>
          `
        : null}
      <div class="mt-2 truncate font-mono text-3xs text-[var(--color-fg-disabled)]">${endpoint}</div>
    </div>
  `
}

function EditorHeader() {
  return html`
    <div class="flex flex-wrap items-center gap-x-2 gap-y-0.5">
      <span class="text-2xs font-bold uppercase tracking-[var(--track-caps)] text-[var(--color-accent-fg)]">런타임</span>
      <span class="text-3xs text-[var(--color-fg-muted)]">keeper가 다음 턴에 호출할 runtime lane</span>
    </div>
  `
}

export function KeeperRuntimeModelEditor({ keeperName }: { keeperName: string }) {
  // Reset the pending selection whenever the viewed keeper changes.
  if (modelDraftKeeper.value !== keeperName) {
    if (modelDraft.value !== null) modelDraft.value = null
    modelDraftKeeper.value = keeperName
  }

  // Lazy-load the shared config. This card only mounts when the 진단/운영
  // section is expanded; loadKeeperConfig dedupes by name internally.
  const status = peekKeeperConfigLoadStatus(keeperName)
  if (status === 'idle' || status === 'other') {
    void loadKeeperConfig(keeperName)
  }

  const config = peekLoadedKeeperConfig(keeperName)
  if (config === null) {
    return status === 'error'
      ? html`<${ErrorState} message="런타임 설정을 불러오지 못했습니다." />`
      : html`<${LoadingState}>런타임 불러오는 중...<//>`
  }

  const current = config.execution.selected_runtime_id.trim()
  const canonical = config.execution.selected_runtime_canonical.trim()
  const effective = (modelDraft.value ?? current).trim()
  const hasChange = modelDraft.value !== null && effective !== current
  const isSaving = modelSaving.value
  loadRuntimeCatalog()
  const catalogState = runtimeCatalogState.value
  const catalog = catalogState.status === 'loaded' ? catalogState.data : []
  const runtimeEntry = findRuntimeCatalogEntry(catalog, effective || current)

  if (!canEditRuntime(config)) {
    // Actionable read-only: explain WHY it is locked and HOW to unlock it, so
    // the operator is not left at the same dead-end the card exists to fix.
    const kind = config.sources.default_source_kind ?? 'unknown'
    return html`
      <div class="v2-monitoring-card flex flex-col gap-2 rounded-[var(--r-4)] border border-[var(--color-border-default)]/60 bg-[var(--color-bg-surface)]/35 px-4 py-3">
        <${EditorHeader} />
        <div class="text-sm font-semibold text-[var(--color-fg-primary)]">${current || MISSING_DATA_DASH}</div>
        ${canonical && canonical !== current
          ? html`<div class="text-2xs text-[var(--color-fg-muted)]">정규화: ${canonical}</div>`
          : null}
        <${RuntimeCatalogSummary}
          runtimeId=${current}
          entry=${findRuntimeCatalogEntry(catalog, current)}
          status=${catalogState.status}
        />
        <div class="rounded-[var(--r-1)] border border-[var(--warn-20)] bg-[var(--warn-10)] px-3 py-2 text-2xs leading-relaxed text-[var(--color-status-warn)]">
          이 keeper는 편집 가능한 TOML 소스가 아니라(소스: ${kind}) 여기서 model을 바꿀 수 없습니다.
          편집하려면 <code>.masc/config/runtime.toml</code> 의
          <code>[runtime.assignments]</code> 에 keeper 배정을 추가하고 서버를 재시작하세요.
        </div>
      </div>
    `
  }

  const options = uniqueNonEmpty([
    effective,
    current,
    canonical,
    ...config.execution.runtime_options,
  ])

  async function save() {
    const next = (modelDraft.value ?? '').trim()
    if (next === '' || next === current) return
    modelSaving.value = true
    try {
      const updated = await patchKeeperConfig(keeperName, { runtime_id: next })
      applyKeeperConfigUpdate(keeperName, updated)
      void refreshKeeperRuntimeStatus().catch(err => {
        const message = err instanceof Error ? err.message : '런타임 상태 새로고침 실패'
        showToast(message, 'warning')
      })
      modelDraft.value = null
      showToast('런타임 저장 완료', 'success')
    } catch (err) {
      showToast(err instanceof Error ? err.message : '저장 실패', 'error')
    } finally {
      modelSaving.value = false
    }
  }

  function reset() {
    modelDraft.value = null
  }

  return html`
    <div class="v2-monitoring-card flex flex-col gap-2 rounded-[var(--r-4)] border border-[var(--accent-20)] bg-[var(--accent-10)] px-4 py-3">
      <${EditorHeader} />
      <div class="text-2xs text-[var(--color-fg-muted)]">현재 <span class="font-semibold text-[var(--color-fg-primary)]">${current || MISSING_DATA_DASH}</span></div>
      <${InlineSelectRow}
        label="runtime"
        value=${effective}
        options=${options}
        onChange=${(value: string) => { modelDraft.value = value }}
      />
      <${RuntimeCatalogSummary}
        runtimeId=${effective}
        entry=${runtimeEntry}
        status=${catalogState.status}
      />
      <div class="flex flex-wrap items-center gap-2">
        <button
          type="button"
          class="${BTN_FILLED_BASE} bg-[var(--color-status-ok)] text-[var(--color-fg-on-ok)]"
          onClick=${save}
          disabled=${!hasChange || isSaving}
        >${isSaving ? '저장 중...' : '저장'}</button>
        <button
          type="button"
          class="${BTN_FILLED_BASE} bg-[var(--color-bg-hover)] text-[var(--color-fg-secondary)]"
          onClick=${reset}
          disabled=${!hasChange || isSaving}
        >되돌리기</button>
        ${hasChange
          ? html`<span class="text-2xs text-[var(--color-fg-muted)]">저장 시 runtime.toml assignment 갱신</span>`
          : null}
      </div>
    </div>
  `
}
