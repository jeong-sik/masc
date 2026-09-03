// Keeper Workspace — context rail (right). Ported to the keeper-v2 prototype DOM
// (rails.jsx ContextRail): `.ctx` → `.ctx-scroll` → `.ctx-sec` sections (주의 /
// 드레인 `.drain-card` while Draining / 런타임 `.rtc-card` with the
// design's collapsed-by-default `.rtc-head`→`.rtc-detail` disclosure and
// `.rail-hb` heartbeat line / 컨텍스트 `.ctx-card` with `.ctx-usage` +
// `.ctx-notobs` / 소유 태스크 `.ctx-list`), styled by the vendored SSOT CSS.
// Live wiring (Keeper object + tasks store + waiting inventory) is
// unchanged; only the DOM/classes changed. Documented
// local divergences: the 처리량 `.tps-card` section was removed as low-signal
// (#22681), and the last-turn meter stays (design deleted the gauge;
// #22681 explicitly kept it). Data gaps (runtime capability flags, effort
// segments, memory inspector, live ctx occupancy) are MARKED, never faked.

import { html } from 'htm/preact'
import { lazy, Suspense } from 'preact/compat'
import { useEffect, useState } from 'preact/hooks'
import type { VNode } from 'preact'
import { tasks } from '../../store'
import type { Keeper, Task } from '../../types'
import type { KeeperRuntimeLensConfigDriftAxis } from '../../api/keeper-runtime-trace'
import {
  keeperBucket,
  keeperRuntimeLabel,
} from './keeper-workspace-shared'
import {
  loadRuntimeCatalog,
  resolveRuntimeCatalogEntry,
  runtimeCatalogState,
  type RuntimeCatalogEntryResolution,
} from '../../lib/runtime-catalog-resource'
import {
  runtimeCatalogDeclaredSpec,
  runtimeCatalogEffectiveCapabilities,
  runtimeCatalogParameterPolicy,
  runtimeCatalogRequestConfig,
} from '../../lib/runtime-provider-summary'
import { formatContextTokens } from '../../lib/format-number'
import { formatTimeAgo } from '../../lib/format-time'
import { keeperWaitingInventoryState } from '../../keeper-waiting-inventory-store'
import { persistentSignal } from '../../lib/persistent-signal'
import type { MemoryKeeper } from '../memory-inspector'
import { keepers } from '../../store'
import { KeeperLaneSection } from './keeper-lane-strip'
import { KeeperWaitQueueRail } from '../lanes/lane-queue-panel'
import { openTaskDetail } from '../goals/task-detail-state'

const LazyMemoryInspector = lazy(async () => ({
  default: (await import('../memory-inspector')).MemoryInspector,
}))

function contextRatio(keeper: Keeper): number | null {
  const ratio = keeper.context_ratio ?? keeper.context?.context_ratio
  if (typeof ratio !== 'number' || !Number.isFinite(ratio)) return null
  return Math.max(0, Math.min(1, ratio))
}

function contextPercent(keeper: Keeper): number | null {
  const ratio = contextRatio(keeper)
  if (ratio === null) return null
  return Math.max(0, Math.min(100, Math.round(ratio * 100)))
}

function contextMax(keeper: Keeper): number | null {
  const max = keeper.context_max ?? keeper.context?.context_max ?? null
  if (typeof max !== 'number' || !Number.isFinite(max) || max <= 0) return null
  return max
}

function formatK(n: number | null | undefined): string | null {
  if (typeof n !== 'number') return null
  return n >= 1000 ? `${(n / 1000).toFixed(1)}k` : `${n}`
}

// Design formats the window size as a round k figure (`(ctxWindow / 1000).toFixed(0)k`,
// rails.jsx ctx-usage) — 200k, not 200.0k.
function formatWindowK(n: number | null | undefined): string | null {
  if (typeof n !== 'number') return null
  return `${(n / 1000).toFixed(0)}k`
}

// Design rtc-spec formatting (rails.jsx RailRuntime): round k figures from the
// catalog's declared max_context / max_output_tokens, '—' when the catalog has
// no entry — never the mock's hardcoded `max_tokens 4,096`.
function formatSpecK(n: number | null | undefined): string {
  return typeof n === 'number' && Number.isFinite(n) && n > 0
    ? `${(n / 1000).toFixed(0)}k`
    : '—'
}

function samplingSpec(entry: { temperature?: number | null, top_p?: number | null } | null): string | null {
  if (!entry) return null
  const parts: string[] = []
  if (typeof entry.temperature === 'number') parts.push(`temp ${entry.temperature}`)
  if (typeof entry.top_p === 'number') parts.push(`top_p ${entry.top_p}`)
  return parts.length > 0 ? `샘플링 ${parts.join(' · ')}` : null
}

// Design heartbeat line (rails.jsx `.rail-hb`): `heartbeat {interval}s · 다음
// wake ~{eta}s` + a `poll` note. The ETA derives from the keepalive interval
// and the ledger's last heartbeat; when the ledger could not be read
// (heartbeat_observation_error) the line marks the observation error instead
// of substituting a stale ETA.
function heartbeatEtaSeconds(keeper: Keeper): number | null {
  const interval = keeper.keeper_keepalive_interval_s
  if (typeof interval !== 'number' || !Number.isFinite(interval) || interval <= 0) return null
  if (keeper.heartbeat_observation_error) return null
  if (!keeper.last_heartbeat) return null
  const lastMs = Date.parse(keeper.last_heartbeat)
  if (!Number.isFinite(lastMs)) return null
  const elapsed = (Date.now() - lastMs) / 1000
  return Math.max(0, Math.round(interval - elapsed))
}

function ownedTasks(keeper: Keeper): Task[] {
  return tasks.value.filter(t => t.assignee === keeper.name)
}

function taskStateClass(status: Task['status']): string {
  if (status === 'awaiting_verification') return 'review'
  return ''
}

function nonEmpty(value: string | null | undefined): string | null {
  const trimmed = value?.trim()
  return trimmed ? trimmed : null
}

function attentionFallback(keeper: Keeper): string | null {
  if (keeper.needs_attention !== true) return null
  const summary = nonEmpty(keeper.runtime_blocker_summary)
  if (summary) return summary
  const reason = nonEmpty(keeper.attention_reason)
  const action = nonEmpty(keeper.next_human_action)
  if (reason && action) return `${reason} · ${action}`
  if (reason) return `주의 원인: ${reason}`
  if (action) return `다음 조치: ${action}`
  return 'runtime_attention.needs_attention=true · 원인/조치 미수신'
}

type AttentionItem = { sev: 'bad' | 'warn'; text: string }

function attentionItems(keeper: Keeper): AttentionItem[] {
  const items: AttentionItem[] = []
  const blocked = keeper.blocked_task_count ?? 0
  if (blocked > 0) items.push({ sev: 'bad', text: `차단된 태스크 ${blocked}건` })
  const fallback = items.length === 0 ? attentionFallback(keeper) : null
  if (fallback) items.push({ sev: 'warn', text: fallback })
  return items
}

function AttentionSection({ keeper }: { keeper: Keeper }): VNode | null {
  const items = attentionItems(keeper)
  if (items.length === 0) return null
  return html`
    <div class="ctx-sec">
      <h4>주의</h4>
      <div class="att-list">
        ${items.map((it, i) => html`
          <div class=${`att-item ${it.sev}`} key=${`${it.text}-${i}`}>
            <span class="att-dot" aria-hidden="true"></span>
            <span class="att-text" title=${it.text}>${it.text}</span>
          </div>
        `)}
      </div>
    </div>
  `
}

// Design drain card (rails.jsx ContextRail `.drain-card`): visible only while
// the keeper FSM is Draining. Counts and rows come from the
// live owned-task list; the 대기 자극 flush sub-list reads the keeper waiting
// inventory's event_queue_pending rows (the same store the lane strip uses) —
// nothing is synthesized when the inventory has not reported.
function drainPhase(keeper: Keeper): 'Draining' | null {
  const phase = keeper.lifecycle_phase ?? keeper.phase ?? null
  return phase === 'Draining' ? phase : null
}

function DrainSection({ keeper }: { keeper: Keeper }): VNode | null {
  const phase = drainPhase(keeper)
  if (!phase) return null
  const owned = ownedTasks(keeper)
  const inventory = keeperWaitingInventoryState(keeper.name).inventory
  const entry = inventory?.keepers.find(k => k.keeper_name === keeper.name) ?? null
  const stimuli = (entry?.waiting_on ?? []).filter(row => row.source === 'event_queue_pending')
  return html`
    <div class="ctx-sec">
      <h4>드레인 큐</h4>
      <div class="drain-card" data-phase=${phase}>
        <div class="drain-head">
          <span class="drain-badge">${phase}</span>
          <span class="drain-gloss">작업을 비우고 정상 종료 중</span>
        </div>
        <div class="drain-count"><span class="mono">${owned.length}</span>건 비우는 중</div>
        ${owned.length > 0
          ? html`
              <div class="drain-list">
                ${owned.map(t => html`
                  <div class="drain-item" key=${t.id}>
                    <span class="drain-spin" aria-hidden="true"></span>
                    <span class="drain-t-id mono">${t.id}</span>
                    <span class="drain-t-title">${t.title}</span>
                    <span class="drain-t-state mono">${t.status}</span>
                  </div>
                `)}
              </div>
            `
          : null}
        ${stimuli.length > 0
          ? html`
              <div class="drain-eventq">
                <div class="drain-eventq-h">대기 자극 flush</div>
                ${stimuli.map((row, i) => html`
                  <div class="drain-ev" key=${`${row.source}:${row.waiting_on}:${i}`}>
                    <span class="drain-ev-gl mono" aria-hidden="true">·</span>
                    <span class="drain-ev-kind mono">${row.waiting_on}</span>
                    <span class="drain-ev-from">${row.wake_producer ?? '—'}</span>
                    <span class="drain-ev-at mono">${row.since_iso ? formatTimeAgo(row.since_iso) : '—'}</span>
                  </div>
                `)}
              </div>
            `
          : null}
      </div>
    </div>
  `
}

// Raw catalog projection rows (params/request/declared/caps) are an
// operator-debug surface, not day-to-day reading material: each row flattens
// 20-40 catalog fields into one token string. Collapsed by default; the
// choice persists across reloads like every other layout preference.
// Exported so tests can pin the collapsed-default contract.
export const runtimeRawSpecOpen = persistentSignal<boolean>({
  key: 'dashboard:keeper-rail:runtime-raw-open-v1',
  defaultValue: false,
})

type RuntimeEffortState =
  | { readonly status: 'loading' }
  | { readonly status: 'error'; readonly message: string }
  | { readonly status: 'missing' }
  | { readonly status: 'unknown'; readonly reason: string }
  | {
      readonly status: 'ready'
      readonly mode: string
      readonly adjustable: boolean
      readonly acceptedEfforts: readonly string[]
    }

function resolveRuntimeEffortState(
  catalogEntry: RuntimeCatalogEntryResolution,
): RuntimeEffortState {
  switch (catalogEntry.status) {
    case 'loading':
      return { status: 'loading' }
    case 'error':
      return { status: 'error', message: catalogEntry.message }
    case 'missing':
      return { status: 'missing' }
    case 'ready': {
      const capabilities = catalogEntry.entry.effective_capabilities
      if (!capabilities) {
        return { status: 'unknown', reason: '유효 capability 미수신' }
      }
      const mode = capabilities.thinking_control_format
      if (!mode) {
        return { status: 'unknown', reason: 'thinking control 형식 미수신' }
      }
      const acceptedEfforts = capabilities.accepted_reasoning_efforts ?? []
      return {
        status: 'ready',
        mode,
        adjustable:
          capabilities.supports_reasoning_budget === true
          || acceptedEfforts.length > 0,
        acceptedEfforts,
      }
    }
  }
}

function RuntimeEffortValue({ state }: { state: RuntimeEffortState }): VNode {
  switch (state.status) {
    case 'loading':
      return html`<span class="rtc-eff-na" data-effort-status="loading">카탈로그 로딩 중</span>`
    case 'error':
      return html`<span class="rtc-eff-na" data-effort-status="error" title=${state.message}>카탈로그 조회 실패</span>`
    case 'missing':
      return html`<span class="rtc-eff-na" data-effort-status="missing" data-missing="runtime-effort">카탈로그 미등재</span>`
    case 'unknown':
      return html`<span class="rtc-eff-na" data-effort-status="unknown">${state.reason}</span>`
    case 'ready':
      return html`<span class="rtc-eff-na" data-effort-status="ready" data-effort-mode=${state.mode}>${state.mode} · ${state.adjustable ? '조정 가능' : '고정'}${state.acceptedEfforts.length > 0 ? ` (${state.acceptedEfforts.join(', ')})` : ''}</span>`
  }
}

function RuntimeCapabilitiesUnavailable({
  resolution,
}: {
  resolution: Exclude<RuntimeCatalogEntryResolution, { status: 'ready' }>
}): VNode {
  switch (resolution.status) {
    case 'loading':
      return html`<div class="rtc-na" data-runtime-catalog-status="loading">능력 정보 로딩 중</div>`
    case 'error':
      return html`<div class="rtc-na" data-runtime-catalog-status="error" title=${resolution.message}>능력 정보 조회 실패</div>`
    case 'missing':
      return html`<div class="rtc-na" data-runtime-catalog-status="missing" data-missing="runtime-capabilities">능력 정보 미수신</div>`
  }
}

function RuntimeSection({
  keeper,
  drift,
}: {
  keeper: Keeper
  drift: KeeperRuntimeLensConfigDriftAxis | null
}): VNode {
  useEffect(() => {
    loadRuntimeCatalog()
  }, [])

  // Design RailRuntime disclosure (rails.jsx): the card is collapsed to just
  // the runtime name by default; `.rtc-head` toggles `.rtc-detail` open.
  const [detailOpen, setDetailOpen] = useState(false)

  const runtime = keeperRuntimeLabel(keeper)
  // The card's runtime id is the *live* runtime the keeper is running (from its
  // meta, via the execution snapshot). Saving a new runtime in the config
  // editor changes the *assigned* runtime (runtime.toml); the running keeper
  // keeps its current runtime until its next turn-up. Surface that pending
  // assignment here so a save that "does nothing" visibly is instead shown as
  // "assigned X, still running Y". The drift axis is the config-domain read
  // model — the rail does not reach into the config editor's write signal.
  const pendingRuntime =
    drift && drift.runtime_override ? drift.default_runtime_id : null
  const catalogEntry = resolveRuntimeCatalogEntry(runtimeCatalogState.value, runtime)
  const entry = catalogEntry.status === 'ready' ? catalogEntry.entry : null
  const ctxK = formatContextTokens(entry?.max_context ?? contextMax(keeper))
  const capabilitiesDeclared = entry?.capabilities_declared !== false
  // Read-only capability readout (audit P7-4). multimodal = accepts non-text
  // input, gated on the runtime.toml declared-capabilities flag — no
  // per-keeper mutation here (deferred).
  const multimodal = capabilitiesDeclared
    ? Boolean(
        entry?.supports_multimodal_inputs
        || entry?.supports_image_input
        || entry?.supports_audio_input
        || entry?.supports_video_input,
      )
    : null
  // Effort reads Agent Core-catalog effective_capabilities, the same source request
  // building uses. Catalog transport state, a missing runtime entry, and an
  // entry whose effective capabilities were not projected are distinct facts.
  const effortState = resolveRuntimeEffortState(catalogEntry)
  // The raw rows are only materialized while the disclosure is open — closed
  // state renders the curated block alone.
  const rawOpen = runtimeRawSpecOpen.value
  const rawSpecAvailable = Boolean(
    entry
    && (entry.parameter_policy || entry.request_config || entry.declared_spec || entry.effective_capabilities),
  )
  const parameterPolicy = rawOpen && entry ? runtimeCatalogParameterPolicy(entry) : null
  const requestConfig = rawOpen && entry ? runtimeCatalogRequestConfig(entry) : null
  const declaredSpec = rawOpen && entry ? runtimeCatalogDeclaredSpec(entry) : null
  const effectiveCapabilities = rawOpen && entry ? runtimeCatalogEffectiveCapabilities(entry) : null
  const sampling = samplingSpec(entry)
  const heartbeatInterval = keeper.keeper_keepalive_interval_s
  const heartbeatError = keeper.heartbeat_observation_error ?? null
  const heartbeatEta = heartbeatEtaSeconds(keeper)

  return html`
    <div class="ctx-sec">
      <h4>런타임</h4>
      <div class=${`rtc-card${detailOpen ? ' open' : ''}`}>
        <button
          type="button"
          class="rtc-head"
          aria-expanded=${detailOpen ? 'true' : 'false'}
          title=${detailOpen ? '접기' : '런타임 상세 펼치기'}
          onClick=${() => setDetailOpen(open => !open)}
        >
          <span class="rtc-id mono">${runtime ?? '런타임 미수신'}</span>
          <span class="rtc-chev" aria-hidden="true">▸</span>
        </button>
        ${pendingRuntime
          ? html`<div
              class="rtc-drift"
              data-testid="runtime-drift"
              title="지정은 다음 turn-up에 적용 · 표시는 현재 실행 중인 런타임"
            >
              지정됨 <span class="mono">${pendingRuntime}</span> · 재시작 시 적용
            </div>`
          : null}
        ${detailOpen
          ? html`
              <div class="rtc-detail">
                <div class="rtc-model mono">
                  ${entry?.model_api_name ?? '—'}${ctxK ? html` · ${ctxK}` : null}
                </div>
                <div class="rtc-spec mono">최대 컨텍스트 ${formatSpecK(entry?.max_context)} · 최대 출력 ${formatSpecK(entry?.max_output_tokens)}</div>
                ${sampling ? html`<div class="rtc-spec mono">${sampling}</div>` : null}
                ${catalogEntry.status === 'ready'
                  ? html`
                      <div class="rtc-flags">
                        <span class=${`rtc-flag ${catalogEntry.entry.tools_support ? 'on' : 'off'}`}>
                          ${catalogEntry.entry.tools_support ? '✓' : '✕'} tools
                        </span>
                        <span class=${`rtc-flag ${catalogEntry.entry.thinking_support ? 'on' : 'off'}`}>
                          ${catalogEntry.entry.thinking_support ? '✓' : '✕'} thinking
                        </span>
                        <span class=${`rtc-flag ${catalogEntry.entry.streaming ? 'on' : 'off'}`}>
                          ${catalogEntry.entry.streaming ? '✓' : '✕'} streaming
                        </span>
                        <span
                          class=${`rtc-flag ${multimodal === true ? 'on' : multimodal === false ? 'off' : 'na'}`}
                          title=${multimodal === null ? '능력 미선언 — 지원 여부 판별 불가' : null}
                        >
                          ${multimodal === null ? '—' : multimodal ? '✓' : '✕'} multimodal
                        </span>
                      </div>
                    `
                  : html`<${RuntimeCapabilitiesUnavailable} resolution=${catalogEntry} />`}
                <div class="rtc-effort">
                  <span class="rtc-effort-k">effort</span>
                  <${RuntimeEffortValue} state=${effortState} />
                </div>
                ${rawSpecAvailable
                  ? html`
                      <button
                        type="button"
                        class="rtc-raw-toggle"
                        data-testid="runtime-raw-toggle"
                        aria-expanded=${rawOpen ? 'true' : 'false'}
                        title="카탈로그 원시 스펙(params/request/declared/caps) 표시 전환"
                        onClick=${() => {
                          runtimeRawSpecOpen.value = !runtimeRawSpecOpen.value
                        }}
                      >
                        원시 스펙 ${rawOpen ? '접기' : '보기'}
                      </button>
                    `
                  : null}
                ${parameterPolicy
                  ? html`
                      <div class="rtc-effort">
                        <span class="rtc-effort-k">params</span>
                        <span class="rtc-eff-na" title=${parameterPolicy}>${parameterPolicy}</span>
                      </div>
                    `
                  : null}
                ${requestConfig
                  ? html`
                      <div class="rtc-effort">
                        <span class="rtc-effort-k">request</span>
                        <span class="rtc-eff-na" title=${requestConfig}>${requestConfig}</span>
                      </div>
                    `
                  : null}
                ${declaredSpec
                  ? html`
                      <div class="rtc-effort">
                        <span class="rtc-effort-k">declared</span>
                        <span class="rtc-eff-na" title=${declaredSpec}>${declaredSpec}</span>
                      </div>
                    `
                  : null}
                ${effectiveCapabilities
                  ? html`
                      <div class="rtc-effort">
                        <span class="rtc-effort-k">caps</span>
                        <span class="rtc-eff-na" title=${effectiveCapabilities}>${effectiveCapabilities}</span>
                      </div>
                    `
                  : null}
              </div>
            `
          : null}
      </div>
      ${typeof heartbeatInterval === 'number' && Number.isFinite(heartbeatInterval) && heartbeatInterval > 0
        ? html`<div class="rail-hb" title=${heartbeatError ?? null}>
            <span class="rail-hb-dot" aria-hidden="true"></span>heartbeat ${heartbeatInterval}s <span class="rail-hb-sep">·</span> 다음 wake ~${heartbeatEta === null ? '—' : `${heartbeatEta}s`}<span class="rail-hb-note mono">${heartbeatError ? '관측 오류' : 'poll'}</span>
          </div>`
        : null}
    </div>
  `
}

function ContextSection({
  keeper,
  onOpenMemory,
}: {
  keeper: Keeper
  onOpenMemory: () => void
}): VNode {
  const pct = contextPercent(keeper)
  const max = contextMax(keeper)
  const baseTokens = keeper.context_tokens ?? keeper.context?.context_tokens ?? null
  const tokens = formatK(baseTokens)
  const maxLabel = formatWindowK(max)
  const hasMeterData = pct !== null && (pct > 0 || max !== null)
  // The server projects these values from the newest completed TurnRecord.
  // Keep only turn identity and age here; serialized request bytes are
  // transport diagnostics, not a second context metric.
  const ctxSource = keeper.context_source ?? keeper.context?.source ?? null
  const ctxAbsoluteTurn = keeper.context?.absolute_turn ?? null
  const ctxObservedAt = keeper.context?.observed_at ?? null
  const ctxTurnRef = keeper.context?.turn_ref ?? null
  const ctxUnavailableReason =
    keeper.context_metrics_unavailable?.kind === 'not_observed'
      ? keeper.context_metrics_unavailable.reason
      : null
  // The "윈도우 사용량" label was redundant under the section's "컨텍스트"
  // heading — the percentage and the 사용/전체 line below are self-explanatory.
  const usageHeader = html`
    <div class="ctx-meter-head">
      <span class="ctx-meter-pct mono">${pct ?? 0}%</span>
    </div>
  `

  return html`
    <div class="ctx-sec">
      <h4>컨텍스트</h4>
      <div class="ctx-card">
        ${hasMeterData
          ? html`
              ${usageHeader}
              <div class="meter-wrap">
                <div
                  class="meter"
                  role="meter"
                  aria-label="마지막 완료 요청의 컨텍스트 윈도우 사용률"
                  aria-valuenow=${pct ?? 0}
                  aria-valuemin="0"
                  aria-valuemax="100"
                ><span style=${{ width: `${pct ?? 0}%` }}></span></div>
              </div>
            `
          : html`<div class="ctx-empty" data-missing="context-window"><strong>윈도우 사용률 미측정</strong><span>${ctxUnavailableReason
                ? html`턴 레코드 기준 측정 불가: <span class="mono">${ctxUnavailableReason}</span>`
                : '측정된 턴 레코드가 아직 없음'}</span></div>`}
        <div class="ctx-usage">
          <span class="ctx-usage-k">마지막 턴 input</span>
          <span class="mono ctx-usage-v">${tokens ?? '—'}</span>
          <span class="ctx-tok-sep">/</span>
          <span class="mono ctx-tok-full">${maxLabel ?? '—'}</span>
          <span class="ctx-tok-lbl">마지막 턴 · 창 크기</span>
        </div>
        ${ctxSource === 'turn_record'
          ? html`<div class="ctx-src" data-testid="ctx-provenance" title=${ctxTurnRef ?? undefined}>
              마지막 완료 요청: <span class="mono">T${ctxAbsoluteTurn ?? '—'}</span>
              ${ctxObservedAt ? html` · ${formatTimeAgo(ctxObservedAt)}` : null}
            </div>`
          : null}
        ${hasMeterData
          // Design's typed not_observed line (rails.jsx): the meter above is
          // the LAST turn's ratio; the live in-flight occupancy is never
          // observed, and the design says so instead of implying it.
          ? html`<div class="ctx-notobs mono">지금 쓰는 양 <b>알 수 없음</b><span class="ctx-notobs-g">마지막 턴 기준 · 재시작하면 초기화</span></div>`
          : null}
        <button type="button" class="cmp-open" data-testid="open-memory-inspector" onClick=${onOpenMemory}>
          ◈ 메모리 보기 <span class="cmp-open-sub">핀 · 스토어 · 회상</span>
        </button>
      </div>
    </div>
  `
}

function OwnedTasksSection({ keeper }: { keeper: Keeper }): VNode {
  const owned = ownedTasks(keeper)
  return html`
    <div class="ctx-sec">
      <h4>소유 태스크</h4>
      <div class="ctx-list">
        ${owned.length
          ? owned.map(t => html`
              <button
                type="button"
                class="tasktag"
                key=${t.id}
                title=${`상세 보기 · ${t.id} · ${t.title}`}
                aria-label=${`태스크 열기: ${t.id} ${t.title}`}
                onClick=${() => openTaskDetail(t)}
              >
                <div class="tasktag-top">
                  <span class="tid">${t.id}</span>
                  ${t.status ? html`<span class=${`tasktag-state ${taskStateClass(t.status)}`}>${t.status}</span>` : null}
                </div>
                <span class="ttl">${t.title}</span>
              </button>
            `)
          : html`<div style=${{ fontSize: '12px', color: 'var(--text-dim)' }}>할당된 태스크 없음</div>`}
      </div>
    </div>
  `
}

function toMemoryKeeper(k: Keeper): MemoryKeeper {
  const bucket = keeperBucket(k)
  // stuck keepers still hold a live fiber — keep them on the 'run' glyph
  // (the 3-value MemoryKeeper vocabulary has no attention state).
  const status =
    bucket === 'running' || bucket === 'stuck'
      ? 'run'
      : bucket === 'paused'
        ? 'pause'
        : 'off'
  return {
    id: k.name,
    status,
  }
}

export function KeeperWorkspaceRail({
  keeper,
  runtimeDrift = null,
}: {
  keeper: Keeper
  runtimeDrift?: KeeperRuntimeLensConfigDriftAxis | null
}): VNode {
  const [overlay, setOverlay] = useState<'memory' | null>(null)
  const memoryKeeper = toMemoryKeeper(keeper)
  const memoryKeepers = keepers.value.map(toMemoryKeeper)

  return html`
    <aside class="ctx" aria-label="키퍼 컨텍스트">
      <div class="ctx-scroll">
        <${AttentionSection} keeper=${keeper} />
        <${DrainSection} keeper=${keeper} />
        <${KeeperLaneSection} keeper=${keeper} />
        <${RuntimeSection} keeper=${keeper} drift=${runtimeDrift} />
        <${ContextSection}
          keeper=${keeper}
          onOpenMemory=${() => setOverlay('memory')}
        />
        <${KeeperWaitQueueRail} keeperName=${keeper.name} />
        <${OwnedTasksSection} keeper=${keeper} />
      </div>
    </aside>

    ${overlay === 'memory'
      ? html`
          <${Suspense} fallback=${html`<div class="turn-overlay" role="dialog" aria-modal="true">Keeper 메모리 로딩…</div>`}>
            <${LazyMemoryInspector}
              keeper=${memoryKeeper}
              keepers=${memoryKeepers}
              onClose=${() => setOverlay(null)}
            />
          <//>
        `
      : null}
  `
}
