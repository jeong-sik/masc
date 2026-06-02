// Keeper runtime-model editor — a prominent, one-expand-away card that lets an
// operator change which provider-model a keeper dispatches on.
//
// RFC-0207: a keeper's runtime selection lives in a SINGLE surface — the persona
// TOML `runtime_id = "provider.model"` field (parsed into both `runtime_id` and
// `model`). The detailed view of that field is buried under
// 설정 → Keeper 설정 → 소스. This card surfaces the same field at the top of the
// keeper detail's 진단/운영 section so it is discoverable without digging.
//
// State is SHARED with keeper-config-panel via [configState]/[loadKeeperConfig]
// (read) and [applyKeeperConfigUpdate] (write) so the two surfaces never show
// divergent values for the same keeper. No second fetch, no drift.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { patchKeeperConfig } from '../api/dashboard'
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
 * Editable only when the selection is backed by a writable keeper TOML.
 * persona-only / generated keepers have no manifest to patch. Mirrors the
 * `runtimeCanEdit` gate in keeper-config-panel so the two surfaces agree.
 */
export function canEditRuntime(c: KeeperConfig): boolean {
  return c.sources.default_source_kind === 'toml' && Boolean(c.sources.default_manifest_path)
}

function EditorHeader() {
  return html`
    <div class="flex flex-wrap items-center gap-x-2 gap-y-0.5">
      <span class="text-2xs font-bold uppercase tracking-[var(--track-caps)] text-accent-fg">런타임 model</span>
      <span class="text-3xs text-[var(--color-fg-muted)]">keeper가 다음 턴에 호출할 provider.model</span>
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
      : html`<${LoadingState}>런타임 model 불러오는 중...<//>`
  }

  const current = config.execution.selected_runtime_id.trim()
  const canonical = config.execution.selected_runtime_canonical.trim()
  const effective = (modelDraft.value ?? current).trim()
  const hasChange = modelDraft.value !== null && effective !== current
  const isSaving = modelSaving.value

  if (!canEditRuntime(config)) {
    // Actionable read-only: explain WHY it is locked and HOW to unlock it, so
    // the operator is not left at the same dead-end the card exists to fix.
    const kind = config.sources.default_source_kind ?? 'unknown'
    return html`
      <div class="flex flex-col gap-2 rounded-[var(--r-4)] border border-card-border/60 bg-card/35 px-4 py-3 shadow-[var(--shadow-1)]">
        <${EditorHeader} />
        <div class="text-sm font-semibold text-text-strong">${current || MISSING_DATA_DASH}</div>
        ${canonical && canonical !== current
          ? html`<div class="text-2xs text-[var(--color-fg-muted)]">정규화: ${canonical}</div>`
          : null}
        <div class="rounded-[var(--r-1)] border border-[var(--warn-20)] bg-[var(--warn-10)] px-3 py-2 text-2xs leading-relaxed text-[var(--color-status-warn)]">
          이 keeper는 편집 가능한 TOML 소스가 아니라(소스: ${kind}) 여기서 model을 바꿀 수 없습니다.
          편집하려면 <code>.masc/config/keepers/${keeperName}.toml</code> 에
          <code>runtime_id = "provider.model"</code> 을 추가하고 서버를 재시작하세요.
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
      modelDraft.value = null
      showToast('런타임 model 저장 완료', 'success')
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
    <div class="flex flex-col gap-2 rounded-[var(--r-4)] border border-[var(--accent-20)] bg-[var(--accent-10)] px-4 py-3 shadow-[var(--shadow-1)]">
      <${EditorHeader} />
      <div class="text-2xs text-[var(--color-fg-muted)]">현재 <span class="font-semibold text-text-strong">${current || MISSING_DATA_DASH}</span></div>
      <${InlineSelectRow}
        label="model"
        value=${effective}
        options=${options}
        onChange=${(value: string) => { modelDraft.value = value }}
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
          ? html`<span class="text-2xs text-[var(--color-fg-muted)]">저장 시 즉시 적용(live override)</span>`
          : null}
      </div>
    </div>
  `
}
