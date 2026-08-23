// Keeper Workspace — context rail (right). Ported to the keeper-v2 prototype DOM
// (rails.jsx ContextRail): `.ctx` → `.ctx-scroll` → `.ctx-sec` sections (주의 /
// 런타임 `.rtc-card` / 컨텍스트 `.ctx-card` with `.ctx-usage` + `.ctx-notobs` /
// 소유 태스크 `.ctx-list`), styled by the vendored SSOT CSS. Live wiring (Keeper
// object + tasks store + masc_keeper_compact) is unchanged; only the DOM/classes
// changed. Documented local divergences: the 처리량 `.tps-card` section was
// removed as low-signal (#22681), the 컴팩션 스냅샷 button was purged because
// the backend surface has no writer (#29503), and the last-turn meter stays
// (design deleted the gauge; #22681 explicitly kept it). Data gaps (runtime
// capability flags, effort segments, memory inspector, live ctx occupancy)
// are MARKED, never faked.

import { html } from 'htm/preact'
import { lazy, Suspense } from 'preact/compat'
import { useEffect, useState } from 'preact/hooks'
import type { VNode } from 'preact'
import { shellAuthSummary, tasks } from '../../store'
import type { Keeper, Task } from '../../types'
import type { KeeperRuntimeLensConfigDriftAxis } from '../../api/keeper-runtime-trace'
import {
  keeperBucket,
  phaseTokenFromKeeper,
  keeperRuntimeLabel,
} from './keeper-workspace-shared'
import { callMcpTool } from '../../api/mcp'
import { showToast } from '../common/toast'
import { requestConfirm } from '../common/confirm-dialog'
import { dashboardAuthAccess } from '../../lib/dashboard-auth-access'
import { errorToString } from '../../lib/format-string'
import { refreshAfterRuntimeAction } from '../keeper-detail-helpers'
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
import { persistentSignal } from '../../lib/persistent-signal'
import type { MemoryKeeper } from '../memory-inspector'
import { keepers } from '../../store'
import { KeeperLaneSection } from './keeper-lane-strip'
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

function ownedTasks(keeper: Keeper): Task[] {
  return tasks.value.filter(t => t.assignee === keeper.name || (keeper.agent_name != null && t.assignee === keeper.agent_name))
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

  return html`
    <div class="ctx-sec">
      <h4>런타임</h4>
      <div class="rtc-card">
        <div class="rtc-id mono">${runtime ?? '런타임 미수신'}</div>
        ${pendingRuntime
          ? html`<div
              class="rtc-drift"
              data-testid="runtime-drift"
              title="지정은 다음 turn-up에 적용 · 표시는 현재 실행 중인 런타임"
            >
              지정됨 <span class="mono">${pendingRuntime}</span> · 재시작 시 적용
            </div>`
          : null}
        <div class="rtc-model mono">
          ${entry?.model_api_name ?? '—'}${ctxK ? html` · ${ctxK}` : null}
        </div>
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
    </div>
  `
}

function compactRequiresForce(keeper: Keeper): boolean {
  const phase = phaseTokenFromKeeper(keeper)
  if (phase === 'overflowed' || phase === 'paused' || phase === 'compacting') return false
  if (phase === 'running' || phase === 'failing') return true
  const status = keeper.status.toLowerCase()
  return status === 'running' || status === 'active' || status === 'busy' || status === 'failing'
}

function ContextSection({
  keeper,
  onOpenMemory,
}: {
  keeper: Keeper
  onOpenMemory: () => void
}): VNode {
  const [compacting, setCompacting] = useState(false)
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
  const compactAccess = dashboardAuthAccess(shellAuthSummary.value, 'worker')
  const canCompact = compactAccess.allowed && !compacting
  const compactReason = compactAccess.reason ?? '컴팩션 실행 권한이 필요합니다.'
  const runCompact = () => {
    if (!compactAccess.allowed) {
      showToast(compactReason, 'error', 6000)
      return
    }
    void (async () => {
      const force = compactRequiresForce(keeper)
      if (force) {
        const confirmed = await requestConfirm({
          title: 'Force keeper compact',
          message: `${keeper.name} is not in an explicit overflow/paused compaction phase. Run masc_keeper_compact with force=true?`,
          confirmText: 'Force compact',
          tone: 'warning',
        })
        if (!confirmed) return
      }
      setCompacting(true)
      try {
        const raw = await callMcpTool('masc_keeper_compact', { name: keeper.name, force })
        const parsed = JSON.parse(raw) as {
          before_tokens?: number
          after_tokens?: number
          phase_after?: string
          queued?: boolean
          queue_outcome?: string
        }
        const before = formatK(parsed.before_tokens)
        const after = formatK(parsed.after_tokens)
        if (before && after) {
          // Measured before/after present: a compaction actually ran and reduced tokens.
          showToast(`${keeper.name} compact 완료: ${before} -> ${after}`, 'success')
        } else if (parsed.queued) {
          // masc_keeper_compact only ENQUEUES the request; the compaction runs later on the
          // keeper's owning lane. Queuing is not completion: a queue stuck behind an
          // unrecovered inflight turn stays pending indefinitely, so rendering it as "완료"
          // is a false success. Surface the pending state instead.
          const alreadyQueued = parsed.queue_outcome === 'already_present'
          showToast(
            alreadyQueued
              ? `${keeper.name} compaction 이미 예약됨 — 대기열에서 실행 대기 중`
              : `${keeper.name} compaction 예약됨 — 대기열에서 실행 대기 중`,
            'warning',
          )
        } else {
          // Unrecognized response shape: acknowledge receipt without claiming completion.
          showToast(`${keeper.name} compaction 요청 접수됨 (상태 미확인)`, 'warning')
        }
        await refreshAfterRuntimeAction()
      } catch (err) {
        showToast(`compact 실패: ${errorToString(err)}`, 'error', 8000)
      } finally {
        setCompacting(false)
      }
    })()
  }

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
        <div class="cmp-actions">
          <button
            type="button"
            class=${`cmp-run${compacting ? ' busy' : ''}`}
            disabled=${!canCompact}
            title=${compactAccess.allowed ? 'masc_keeper_compact 실행' : compactReason}
            onClick=${runCompact}
          >${compacting ? html`<span class="cmp-spin"></span> 컴팩트 실행 중…` : '◉ 지금 컴팩트'}</button>
        </div>
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
        <${KeeperLaneSection} keeper=${keeper} />
        <${RuntimeSection} keeper=${keeper} drift=${runtimeDrift} />
        <${ContextSection}
          keeper=${keeper}
          onOpenMemory=${() => setOverlay('memory')}
        />
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
