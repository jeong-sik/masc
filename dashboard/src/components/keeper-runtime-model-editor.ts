// Keeper runtime model card — a prominent, one-expand-away card that shows which
// runtime lane a keeper dispatches on, at the top of the keeper detail's 진단/운영
// section so it is discoverable without digging.
//
// RFC-0207: a keeper's runtime selection lives in a SINGLE surface —
// runtime.toml [runtime.assignments], edited through the 설정(.kcf) config modal's
// 런타임 tab. This card is READ-ONLY: it surfaces the current assignment + catalog
// facts and deep-links to the config modal for changes. It does NOT write.
//
// History: runtime_id used to be editable here AND in the config modal — two
// write paths for one field (both PATCH /config {runtime_id}) with two mirrored
// edit gates kept in sync by hand. The write now lives only in the config modal,
// so there is one SSOT, one edit gate (keeperRuntimeConfigCanWrite), and no drift.
//
// State is SHARED with keeper-config-panel via [loadKeeperConfig] /
// [peekLoadedKeeperConfig] so the two surfaces never show divergent values for the
// same keeper. No second fetch, no drift.

import { html } from 'htm/preact'
import type { DashboardRuntimeProviderSnapshot } from '../api/dashboard'
import {
  focusKeeperConfigTab,
  keeperRuntimeConfigCanWrite,
  loadKeeperConfig,
  peekKeeperConfigLoadStatus,
  peekLoadedKeeperConfig,
} from './keeper-config-panel'
import { ErrorState, LoadingState } from './common/feedback-state'
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

function RuntimeCapabilityPill({ label, value }: { label: string; value: boolean | null | undefined }) {
  const state = value === true ? 'on' : value === false ? 'off' : 'unknown'
  const tone = state === 'on'
    ? 'border-[var(--ok-20)] bg-[var(--ok-10)] text-[var(--color-status-ok)]'
    : state === 'off'
      ? 'border-[var(--color-border-subtle)] bg-[var(--color-bg-surface)] text-[var(--color-fg-muted)]'
      : 'border-[var(--warn-20)] bg-[var(--warn-10)] text-[var(--color-status-warn)]'
  return html`
    <span
      class="rounded-[var(--r-1)] border px-2 py-0.5 text-3xs font-semibold uppercase tracking-[var(--track-caps)] ${tone}"
      data-capability-state=${state}
      title=${state === 'unknown' ? 'capability 값 미수신' : null}
    >
      ${label} ${state}
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
        ${/* reasoning-budget reads effective_capabilities (OAS-catalog derived),
             not entry.supports_reasoning_budget — that top-level field mirrors
             runtime.toml's hand-maintained [models.<id>.capabilities] block,
             which OAS request-building never reads (masc #21521). */ ''}
        <${RuntimeCapabilityPill} label="reasoning-budget" value=${entry.effective_capabilities?.supports_reasoning_budget} />
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

export function KeeperRuntimeModelEditor({
  keeperName,
  onOpenRuntimeConfig,
}: {
  keeperName: string
  // Opens the 설정(.kcf) config modal for this keeper (the card pre-focuses the
  // 런타임 tab, which owns the single write path for runtime_id). Optional so the
  // card degrades to read-only display when no host wires it (e.g. isolated
  // renders/tests); the deep-link button then hides.
  onOpenRuntimeConfig?: () => void
}) {
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
  loadRuntimeCatalog()
  const catalogState = runtimeCatalogState.value
  const catalog = catalogState.status === 'loaded' ? catalogState.data : []
  const runtimeEntry = findRuntimeCatalogEntry(catalog, current)

  const canonicalRow =
    canonical && canonical !== current
      ? html`<div class="text-2xs text-[var(--color-fg-muted)]">정규화: ${canonical}</div>`
      : null
  const summary = html`
    <${RuntimeCatalogSummary} runtimeId=${current} entry=${runtimeEntry} status=${catalogState.status} />
  `

  if (!keeperRuntimeConfigCanWrite(config)) {
    // Non-TOML source: the config modal cannot write this either, so there is no
    // deep-link — explain WHY it is locked and HOW to unlock it via runtime.toml.
    const kind = config.sources.default_source_kind ?? 'unknown'
    return html`
      <div class="v2-monitoring-card flex flex-col gap-2 rounded-[var(--r-4)] border border-[var(--color-border-default)]/60 bg-[var(--color-bg-surface)]/35 px-4 py-3">
        <${EditorHeader} />
        <div class="text-sm font-semibold text-[var(--color-fg-primary)]">${current || MISSING_DATA_DASH}</div>
        ${canonicalRow}
        ${summary}
        <div class="rounded-[var(--r-1)] border border-[var(--warn-20)] bg-[var(--warn-10)] px-3 py-2 text-2xs leading-relaxed text-[var(--color-status-warn)]">
          이 keeper는 편집 가능한 TOML 소스가 아니라(소스: ${kind}) model을 바꿀 수 없습니다.
          편집하려면 <code>.masc/config/runtime.toml</code> 의
          <code>[runtime.assignments]</code> 에 keeper 배정을 추가하고 서버를 재시작하세요.
        </div>
      </div>
    `
  }

  // TOML-backed: read-only display + deep-link to the 설정(.kcf) 런타임 tab, which
  // owns the single write path for runtime_id.
  return html`
    <div class="v2-monitoring-card flex flex-col gap-2 rounded-[var(--r-4)] border border-[var(--accent-20)] bg-[var(--accent-10)] px-4 py-3">
      <${EditorHeader} />
      <div class="text-2xs text-[var(--color-fg-muted)]">현재 <span class="font-semibold text-[var(--color-fg-primary)]">${current || MISSING_DATA_DASH}</span></div>
      ${canonicalRow}
      ${summary}
      ${onOpenRuntimeConfig
        ? html`
            <div class="flex flex-wrap items-center gap-2">
              <button
                type="button"
                class="inline-flex items-center gap-1 rounded-[var(--r-1)] border border-[var(--accent-20)] bg-[var(--color-bg-surface)] px-3 py-1 text-2xs font-semibold text-[var(--color-accent-fg)] transition-colors hover:bg-[var(--color-bg-hover)] cursor-pointer v2-monitoring-action"
                onClick=${() => {
                  // Pre-focus the 런타임 tab before the modal opens; kcfTab is not
                  // reset on mount, so this value survives the open.
                  focusKeeperConfigTab('runtime')
                  onOpenRuntimeConfig()
                }}
              >설정에서 변경 ↗</button>
              <span class="text-2xs text-[var(--color-fg-muted)]">런타임 배정은 설정 → 런타임에서 편집합니다</span>
            </div>
          `
        : null}
    </div>
  `
}
