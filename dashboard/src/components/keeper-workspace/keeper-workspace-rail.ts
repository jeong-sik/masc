// Keeper Workspace — context rail (right). Ported to the keeper-v2 prototype DOM
// (rails.jsx ContextRail): `.ctx` → `.ctx-scroll` → `.ctx-sec` sections (주의 /
// 런타임 `.rtc-card` / 처리량 `.tps-card` / 컨텍스트 `.ctx-card` / 소유 태스크
// `.ctx-list`), styled by the vendored SSOT CSS. Live wiring (Keeper object +
// tasks store + masc_keeper_compact) is unchanged; only the DOM/classes changed.
// Data gaps (runtime capability flags, effort segments, compaction/memory
// inspectors) are MARKED, never faked.

import { html } from 'htm/preact'
import { lazy, Suspense } from 'preact/compat'
import { useEffect, useState } from 'preact/hooks'
import type { VNode } from 'preact'
import { shellAuthSummary, tasks } from '../../store'
import type { Keeper, Task } from '../../types'
import type { KeeperRuntimeLensConfigDriftAxis } from '../../api/keeper-runtime-trace'
import { navigate } from '../../router'
import {
  keeperBucket,
  keeperModelLabel,
  phaseTokenFromKeeper,
  keeperRuntimeLabel,
} from './keeper-workspace-shared'
import { CountBadge } from '../v2/primitives-v2'
import { callMcpTool } from '../../api/mcp'
import { showToast } from '../common/toast'
import { requestConfirm } from '../common/confirm-dialog'
import { dashboardAuthAccess } from '../../lib/dashboard-auth-access'
import { errorToString } from '../../lib/format-string'
import { refreshAfterRuntimeAction } from '../keeper-detail-helpers'
import { contextThresholds } from '../../config/context-thresholds'
import {
  loadRuntimeCatalog,
  resolveRuntimeCatalogEntry,
  runtimeCatalogState,
  type RuntimeCatalogEntryResolution,
} from '../../lib/runtime-catalog-resource'
import type { DashboardRuntimeThinkingControlFormat } from '../../api/dashboard'
import {
  runtimeCatalogDeclaredSpec,
  runtimeCatalogEffectiveCapabilities,
  runtimeCatalogParameterPolicy,
  runtimeCatalogRequestConfig,
} from '../../lib/runtime-provider-summary'
import { formatContextTokens } from '../../lib/format-number'
import { persistentSignal } from '../../lib/persistent-signal'
import { recordManualCompaction } from './compaction-snapshots'
import type { MemoryKeeper } from '../memory-inspector'
import { keepers } from '../../store'
import { KeeperLaneSection } from './keeper-lane-strip'

const LazyCompactionInspectorOverlay = lazy(async () => ({
  default: (await import('./compaction-inspector-overlay')).CompactionInspectorOverlay,
}))

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
  const awaiting = ownedTasks(keeper).filter(t => t.status === 'awaiting_verification')
  if (awaiting.length > 0) items.push({ sev: 'warn', text: `검증 대기 ${awaiting.length}건` })
  const fallback = items.length === 0 ? attentionFallback(keeper) : null
  if (fallback) items.push({ sev: 'warn', text: fallback })
  return items
}

function AttentionSection({ keeper }: { keeper: Keeper }): VNode | null {
  const items = attentionItems(keeper)
  if (items.length === 0) return null
  return html`
    <div class="ctx-sec">
      <h4 style=${{ display: 'flex', alignItems: 'center', gap: '7px' }}>주의 <${CountBadge}>${items.length}</${CountBadge}></h4>
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
      readonly mode: DashboardRuntimeThinkingControlFormat
      readonly controlled: boolean
      readonly adjustable: boolean
      readonly acceptedEfforts: readonly string[]
    }

function thinkingControlEnabled(mode: DashboardRuntimeThinkingControlFormat): boolean {
  switch (mode) {
    case 'none':
      return false
    case 'thinking-object':
    case 'thinking-object-adaptive':
    case 'thinking-object-only':
    case 'chat-template-kwargs':
    case 'chat-template-token':
    case 'ollama-think':
    case 'reasoning-effort':
    case 'enable-thinking':
      return true
  }
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
        controlled: thinkingControlEnabled(mode),
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
      return state.controlled
        ? html`<span class="rtc-eff-na" data-effort-status="ready" data-effort-mode=${state.mode}>${state.mode} · ${state.adjustable ? '조정 가능' : '고정'}${state.acceptedEfforts.length > 0 ? ` (${state.acceptedEfforts.join(', ')})` : ''}</span>`
        : html`<span class="rtc-eff-na" data-effort-status="ready" data-effort-mode="none">effort 제어 없음</span>`
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

  const model = keeperModelLabel(keeper)
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
  // Effort reads OAS-catalog effective_capabilities, the same source request
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
              title="저장된 런타임 지정은 키퍼가 다음 turn-up(재시작)할 때 적용됩니다. 현재 표시된 런타임은 지금 실제로 실행 중인 것입니다."
            >
              지정됨 <span class="mono">${pendingRuntime}</span> · 재시작 시 적용
            </div>`
          : null}
        <div class="rtc-model mono">
          ${entry?.model_api_name ?? model ?? '—'}${ctxK ? html` · ${ctxK}` : null}
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

function compactionGatePct(keeper: Keeper): number {
  const raw = keeper.compaction_ratio_gate
  const ratio = typeof raw === 'number' && Number.isFinite(raw) && raw > 0
    ? raw
    : contextThresholds.value.compacting
  return Math.max(1, Math.min(99, Math.round(ratio * 100)))
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
  onOpenCompaction,
  onOpenMemory,
}: {
  keeper: Keeper
  onOpenCompaction: () => void
  onOpenMemory: () => void
}): VNode {
  const [compacting, setCompacting] = useState(false)
  const pct = contextPercent(keeper)
  const compactAt = compactionGatePct(keeper)
  const hot = pct !== null && pct >= compactAt
  const max = contextMax(keeper)
  const baseTokens = keeper.context_tokens ?? keeper.context?.context_tokens ?? null
  const tokens = formatK(baseTokens)
  const maxLabel = formatK(max)
  const compactionCount = keeper.compaction_count ?? null
  const hasCompactionHistory = typeof compactionCount === 'number' && compactionCount > 0
  const hasMeterData = pct !== null && (pct > 0 || max !== null)
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
        const parsed = JSON.parse(raw) as { before_tokens?: number; after_tokens?: number; phase_after?: string }
        const before = formatK(parsed.before_tokens)
        const after = formatK(parsed.after_tokens)
        recordManualCompaction(
          keeper.name,
          parsed.before_tokens,
          parsed.after_tokens,
          keeperRuntimeLabel(keeper) ?? '—',
        )
        showToast(
          before && after ? `${keeper.name} compact 완료: ${before} -> ${after}` : `${keeper.name} compact 완료`,
          'success',
        )
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
      <span class=${`ctx-meter-pct mono${hot ? ' hot' : ''}`}>${pct ?? 0}%</span>
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
                  class=${`meter${hot ? ' hot' : ''}`}
                  role="meter"
                  aria-label="컨텍스트 윈도우 사용률"
                  aria-valuenow=${pct ?? 0}
                  aria-valuemin="0"
                  aria-valuemax="100"
                ><span style=${{ width: `${pct ?? 0}%` }}></span></div>
                <span class=${`meter-mark${hot ? ' hot' : ''}`} style=${{ left: `${compactAt}%` }}>
                  <i class="meter-mark-lbl">compact ${compactAt}%</i>
                </span>
              </div>
            `
          : html`<div class="ctx-empty" data-missing="context-window"><strong>윈도우 사용률 미수신</strong><span>런타임이 전체 윈도우 총량을 아직 보내지 않았습니다.</span></div>`}
        <div class="ctx-tok">
          <span class="mono">${tokens ?? '—'}</span>
          <span class="ctx-tok-sep">/</span>
          <span class="mono ctx-tok-full">${maxLabel ?? '—'}</span>
          <span class="ctx-tok-lbl">사용 / 전체 윈도우</span>
        </div>
        <div class="cmp-actions">
          <button
            type="button"
            class=${`cmp-run${compacting ? ' busy' : ''}`}
            disabled=${!canCompact}
            title=${compactAccess.allowed ? 'masc_keeper_compact 실행' : compactReason}
            onClick=${runCompact}
          >${compacting ? html`<span class="cmp-spin"></span> 컴팩트 실행 중…` : '◉ 지금 컴팩트'}</button>
        </div>
        <button type="button" class="cmp-open" data-testid="open-compaction-inspector" onClick=${onOpenCompaction}>
          ◉ 컴팩션 스냅샷${hasCompactionHistory ? ` · ${compactionCount}` : ''} <span class="cmp-open-sub">before/after 보기</span>
        </button>
        <button type="button" class="cmp-open" data-testid="open-memory-inspector" onClick=${onOpenMemory}>
          ◈ 메모리 보기 <span class="cmp-open-sub">핀 · 스토어 · 회상</span>
        </button>
      </div>
    </div>
  `
}

function OwnedTasksSection({ keeper }: { keeper: Keeper }): VNode {
  const owned = ownedTasks(keeper)
  const openTask = (task: Task) => {
    navigate('workspace', { section: 'planning', task: task.id })
  }
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
                title=${`작업으로 이동 · ${t.id} · ${t.title}`}
                aria-label=${`태스크 열기: ${t.id} ${t.title}`}
                onClick=${() => openTask(t)}
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
  const status = bucket === 'running' ? 'run' : bucket === 'paused' ? 'pause' : 'off'
  return {
    id: k.name,
    ctx: contextRatio(k) ?? 0,
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
  const [overlay, setOverlay] = useState<'compaction' | 'memory' | null>(null)
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
          onOpenCompaction=${() => setOverlay('compaction')}
          onOpenMemory=${() => setOverlay('memory')}
        />
        <${OwnedTasksSection} keeper=${keeper} />
      </div>
    </aside>

    ${overlay === 'compaction'
      ? html`
          <${Suspense} fallback=${html`<div class="turn-overlay" role="dialog" aria-modal="true">컴팩션 스냅샷 로딩…</div>`}>
            <${LazyCompactionInspectorOverlay} keeper=${keeper} onClose=${() => setOverlay(null)} />
          <//>
        `
      : null}
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
