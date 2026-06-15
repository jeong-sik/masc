import { html } from 'htm/preact'
import { useState, useRef, useEffect } from 'preact/hooks'
import { route } from '../router'
import { keepers } from '../store'
import { selectKeeper } from '../keeper-runtime'
import { loadKeeperConfig } from './keeper-config-panel'
import { findKeeper } from '../lib/keeper-utils'
import { resolveKeeperForDetail } from '../lib/keeper-detail-resolution'
import { keeperDisplayStatus } from '../lib/keeper-runtime-display'
import { clearKeeper, fetchKeeperTransitions } from '../api/keeper'
import { purgeAgent } from '../api/actions'
import { showToast } from './common/toast'
import { requestConfirm } from './common/confirm-dialog'
import {
  selectedKeeper,
  clearKeeperDetailSelection,
  closeKeeperDetail,
  openKeeperDetail,
} from './keeper-detail-state'
import {
  refreshAfterRuntimeAction,
  keeperNeedsDiagnosticAttention,
  runSocialSweep,
} from './keeper-detail-helpers'
import {
  useKeeperCompositeEvidence,
  useKeeperRuntimeTraceEvidence,
} from './keeper-detail-hooks'
import { evidenceFreshData } from './keeper-detail-evidence-state'
import { KeeperLifecycleButtons } from './keeper-detail-lifecycle'
import {
  KeeperDetailHeaderInfo,
  KeeperDetailMissingState,
} from './keeper-detail-shell'
import { KeeperDetailBody } from './keeper-detail-body'
import { ringFocusClasses } from './common/ring'
import { TextInput } from './common/input'
import { TimeAgo } from './common/time-ago'
import { StatusDot } from './common/status-dot'
import { KeeperBadge } from './keeper-badge'
import { AgentPresence } from './common/agent-presence'
import { keeperActivityDisplay } from '../lib/keeper-runtime-display'
import { isKeeperOffline, isKeeperPaused } from '../lib/keeper-predicates'
import { summarizeKeeperMonitoring } from '../lib/monitoring-runtime'
import { formatTokens } from '../lib/format-number'
import type { Keeper } from '../types'

const CLOSE_BUTTON_FOCUS_CLASS = ringFocusClasses({
  tone: 'accent-medium',
  width: 2,
  offset: 2,
  offsetSurface: 'page',
})

function keeperSearchTerms(keeper: Keeper): string {
  return [
    keeper.name,
    keeper.agent_name,
    keeper.keeper_id,
    keeper.koreanName,
    keeper.short_goal,
    keeper.goal,
    keeper.runtime_id,
    keeper.runtime_canonical,
    keeper.sandbox_profile,
  ].filter((value): value is string => typeof value === 'string' && value.trim() !== '')
    .join(' ')
    .toLowerCase()
}

function keeperSortRank(keeper: Keeper): number {
  if (isKeeperOffline(keeper)) return 4
  if (isKeeperPaused(keeper)) return 3
  if (keeper.needs_attention || keeper.runtime_blocker_class) return 1
  return 2
}

function keeperModelLabel(keeper: Keeper): string {
  return keeper.last_model_used_label
    ?? keeper.last_model_used
    ?? keeper.active_model_label
    ?? keeper.active_model
    ?? keeper.primary_model
    ?? keeper.model
    ?? 'model 미상'
}

function keeperRuntimeLabel(keeper: Keeper): string {
  const runtimeRef = keeper.runtime_ref
    ? [keeper.runtime_ref.group, keeper.runtime_ref.item].filter((value): value is string => Boolean(value)).join(' / ')
    : null
  return keeper.selected_runtime_canonical
    ?? keeper.runtime_canonical
    ?? keeper.runtime_id
    ?? runtimeRef
    ?? keeper.sandbox_profile
    ?? 'runtime 미상'
}

function keeperWorkPreview(keeper: Keeper): string {
  return keeper.recent_output_preview
    ?? keeper.recent_input_preview
    ?? keeper.short_goal
    ?? keeper.goal
    ?? keeper.agent?.current_task
    ?? '최근 작업 요약 없음'
}

function keeperContextMeta(keeper: Keeper): { pct: number; detail: string | null } | null {
  const ratio = keeper.context_ratio ?? keeper.context?.context_ratio
  if (typeof ratio !== 'number' || !Number.isFinite(ratio)) return null
  const pct = Math.max(0, Math.min(100, Math.round(ratio * 100)))
  const tokens = keeper.context_tokens ?? keeper.context?.context_tokens
  const max = keeper.context_max ?? keeper.context?.context_max
  const detail =
    typeof tokens === 'number' && typeof max === 'number'
      ? `${formatTokens(tokens)} / ${formatTokens(max)}`
      : typeof tokens === 'number'
        ? formatTokens(tokens)
        : null
  return { pct, detail }
}

function keeperDotClass(keeper: Keeper): string {
  if (isKeeperOffline(keeper)) return 'bg-[var(--color-fg-disabled)]'
  if (isKeeperPaused(keeper)) return 'bg-[var(--color-status-warn)]'
  if (keeper.needs_attention || keeper.runtime_blocker_class) return 'bg-[var(--color-status-err)]'
  return 'bg-[var(--color-status-ok)]'
}

export function KeeperDetailRosterRail({ activeKeeperName }: { activeKeeperName: string }) {
  const [query, setQuery] = useState('')
  const normalizedQuery = query.trim().toLowerCase()
  const rows = keepers.value
    .filter(keeper => normalizedQuery === '' || keeperSearchTerms(keeper).includes(normalizedQuery))
    .sort((left, right) => {
      const rank = keeperSortRank(left) - keeperSortRank(right)
      return rank !== 0 ? rank : left.name.localeCompare(right.name)
    })
  const activeCount = keepers.value.filter(keeper => !isKeeperOffline(keeper) && !isKeeperPaused(keeper)).length
  const pausedCount = keepers.value.filter(isKeeperPaused).length
  const offlineCount = keepers.value.filter(isKeeperOffline).length

  return html`
    <aside class="keeper-detail-roster-rail flex min-h-0 flex-col overflow-hidden rounded-[var(--r-2)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)] shadow-none xl:sticky xl:top-[calc(var(--header-h)+0.75rem)] xl:max-h-[calc(100svh-var(--header-h)-1.5rem)]" aria-label="Keeper 목록">
      <div class="shrink-0 border-b border-[var(--color-border-default)] px-4 py-3">
        <div class="flex items-center justify-between gap-3">
          <div>
            <div class="text-3xs font-semibold uppercase tracking-[var(--track-brand)] text-[var(--color-fg-muted)]">Keepers</div>
            <div class="mt-1 text-sm font-semibold text-[var(--color-fg-primary)]">${rows.length} / ${keepers.value.length}</div>
          </div>
          <div class="flex flex-wrap justify-end gap-1.5 text-3xs">
            <span class="rounded-[var(--r-0)] border border-[var(--ok-20)] bg-[var(--ok-10)] px-2 py-1 text-[var(--color-status-ok)]">실행 ${activeCount}</span>
            <span class="rounded-[var(--r-0)] border border-[var(--warn-20)] bg-[var(--warn-10)] px-2 py-1 text-[var(--color-status-warn)]">정지 ${pausedCount}</span>
            <span class="rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2 py-1 text-[var(--color-fg-muted)]">오프 ${offlineCount}</span>
          </div>
        </div>
        <label class="mt-3 block">
          <span class="sr-only">Keeper 검색</span>
          <${TextInput}
            name="keeper_detail_roster_search"
            ariaLabel="Keeper 이름 · 네임스페이스 검색"
            autoComplete="off"
            placeholder="이름 · 네임스페이스 검색..."
            value=${query}
            onInput=${(e: Event) => setQuery((e.target as HTMLInputElement).value)}
          />
        </label>
      </div>
      <div class="min-h-0 flex-1 overflow-y-auto py-2 custom-scrollbar">
        ${rows.length === 0
          ? html`<div class="px-4 py-8 text-center text-xs leading-relaxed text-[var(--color-fg-muted)]">검색 결과가 없습니다.</div>`
          : rows.map(keeper => {
              const selected = keeper.name === activeKeeperName
              const activity = keeperActivityDisplay(keeper, keeper.agent?.last_seen)
              const monitoring = summarizeKeeperMonitoring(keeper)
              const work = keeperWorkPreview(keeper)
              return html`
                <button
                  key=${keeper.name}
                  type="button"
                  class=${`keeper-detail-roster-row mx-2 flex w-[calc(100%-1rem)] min-w-0 items-start gap-3 rounded-[var(--r-1)] border px-3 py-3 text-left transition-colors ${ringFocusClasses({ tone: 'accent-fg', width: 2 })}
                    ${selected
                      ? 'border-[var(--accent-30)] bg-[var(--accent-10)]'
                      : 'border-transparent bg-transparent hover:border-[var(--color-border-default)] hover:bg-[var(--color-bg-surface)]'}`}
                  aria-current=${selected ? 'page' : undefined}
                  onClick=${() => openKeeperDetail(keeper)}
                >
                  <${KeeperBadge} id=${keeper.name} size="lg" variant="sigil" beat=${!isKeeperOffline(keeper) && !isKeeperPaused(keeper)} />
                  <span class="min-w-0 flex-1">
                    <span class="flex min-w-0 items-center gap-2">
                      <span class="truncate text-sm font-semibold text-[var(--color-fg-secondary)]">${keeper.koreanName ?? keeper.name}</span>
                      <${StatusDot} size="xs" class=${keeperDotClass(keeper)} ariaLabel=${monitoring.band.label} />
                    </span>
                    <span class="mt-1 flex min-w-0 items-center gap-1.5 text-3xs text-[var(--color-fg-muted)]">
                      <span class="truncate">${monitoring.phase.label}</span>
                      <span aria-hidden="true">·</span>
                      <span class="truncate">${keeper.name}</span>
                    </span>
                    <span class="mt-1 block truncate text-3xs text-[var(--color-fg-muted)]" title=${work}>${work}</span>
                  </span>
                  <span class="shrink-0 text-3xs tabular-nums text-[var(--color-fg-disabled)]">
                    ${activity.timestamp
                      ? html`<${TimeAgo} timestamp=${activity.timestamp} />`
                      : activity.ageSeconds != null
                        ? `${Math.round(activity.ageSeconds / 60)}m`
                        : '—'}
                  </span>
                </button>
              `
            })}
      </div>
    </aside>
  `
}

export function KeeperContextRail({ keeper }: { keeper: Keeper }) {
  const monitoring = summarizeKeeperMonitoring(keeper)
  const activity = keeperActivityDisplay(keeper, keeper.agent?.last_seen)
  const context = keeperContextMeta(keeper)
  const recentTools = [
    ...(keeper.recent_tool_names ?? []),
    ...(keeper.latest_tool_names ?? []),
  ].filter((name, index, arr) => name.trim() !== '' && arr.indexOf(name) === index)
  const goalProgress = keeper.goal_progress
  const ownedTaskParts = [
    goalProgress?.open_task_count != null ? `열림 ${goalProgress.open_task_count}` : null,
    goalProgress?.done_task_count != null ? `완료 ${goalProgress.done_task_count}` : null,
    (goalProgress?.blocked_task_count ?? keeper.blocked_task_count) != null
      ? `차단 ${goalProgress?.blocked_task_count ?? keeper.blocked_task_count}`
      : null,
  ].filter((part): part is string => part !== null)

  return html`
    <aside class="keeper-detail-context-rail hidden min-h-0 flex-col gap-4 rounded-[var(--r-2)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)] p-4 shadow-none 2xl:flex 2xl:sticky 2xl:top-[calc(var(--header-h)+0.75rem)] 2xl:max-h-[calc(100svh-var(--header-h)-1.5rem)] 2xl:overflow-y-auto custom-scrollbar" aria-label="선택한 Keeper 상태">
      <section class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-4">
        <div class="flex items-start justify-between gap-3">
          <div class="min-w-0">
            <div class="text-3xs font-semibold uppercase tracking-[var(--track-brand)] text-[var(--color-fg-muted)]">현재 Keeper</div>
            <h3 class="m-0 mt-1 truncate text-lg font-semibold text-[var(--color-fg-primary)]">${keeper.koreanName ?? keeper.name}</h3>
            <div class="mt-1 truncate text-2xs font-mono text-[var(--color-fg-muted)]">${keeper.name}</div>
          </div>
          <${KeeperBadge} id=${keeper.name} size="lg" variant="sigil" beat=${!isKeeperOffline(keeper) && !isKeeperPaused(keeper)} />
        </div>
        <div class="mt-4 flex flex-wrap gap-2">
          <${AgentPresence} status=${keeper.status} detail=${monitoring.phase.label} size="sm" />
          <span class="rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)] px-2 py-1 text-3xs text-[var(--color-fg-muted)]">${monitoring.band.label}</span>
        </div>
      </section>

      <section class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-4">
        <div class="grid grid-cols-2 gap-3">
          <div>
            <div class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">모델</div>
            <div class="mt-1 break-words text-xs font-semibold text-[var(--color-fg-primary)]">${keeperModelLabel(keeper)}</div>
          </div>
          <div>
            <div class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">런타임</div>
            <div class="mt-1 break-words text-xs font-semibold text-[var(--color-fg-primary)]">${keeperRuntimeLabel(keeper)}</div>
          </div>
          <div>
            <div class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">턴</div>
            <div class="mt-1 text-xs font-semibold text-[var(--color-fg-primary)]">${keeper.turn_count ?? keeper.total_turns ?? '—'}</div>
          </div>
          <div>
            <div class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">최근 활동</div>
            <div class="mt-1 text-xs font-semibold text-[var(--color-fg-primary)]">
              ${activity.timestamp
                ? html`<${TimeAgo} timestamp=${activity.timestamp} />`
                : activity.ageSeconds != null
                  ? `${Math.round(activity.ageSeconds / 60)}m 전`
                  : '기록 없음'}
            </div>
          </div>
        </div>
      </section>

      ${context ? html`
        <section class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-4">
          <div class="flex items-center justify-between gap-3">
            <div class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">컨텍스트 점유</div>
            <div class="text-sm font-semibold tabular-nums text-[var(--color-fg-primary)]">${context.pct}%</div>
          </div>
          <div class="mt-3 h-2 overflow-hidden rounded-[var(--r-0)] bg-[var(--color-bg-hover)]">
            <div
              class=${`h-full rounded-[var(--r-0)] ${context.pct > 85 ? 'bg-[var(--color-status-err)]' : context.pct > 62 ? 'bg-[var(--color-status-warn)]' : 'bg-[var(--color-status-ok)]'}`}
              style=${`width:${context.pct}%`}
            ></div>
          </div>
          ${context.detail ? html`<div class="mt-2 text-3xs font-mono text-[var(--color-fg-muted)]">${context.detail}</div>` : null}
        </section>
      ` : null}

      <section class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-4">
        <div class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">소유 태스크</div>
        <div class="mt-2 text-xs leading-relaxed text-[var(--color-fg-primary)]">
          ${ownedTaskParts.length > 0 ? ownedTaskParts.join(' · ') : '태스크 집계 없음'}
        </div>
        ${keeper.short_goal || keeper.goal
          ? html`<p class="m-0 mt-3 text-xs leading-relaxed text-[var(--color-fg-secondary)]">${keeper.short_goal ?? keeper.goal}</p>`
          : null}
      </section>

      <section class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-4">
        <div class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">최근 도구 호출</div>
        <div class="mt-3 flex flex-col gap-2">
          ${recentTools.length > 0
            ? recentTools.slice(0, 5).map(tool => html`
                <div class="flex min-w-0 items-center gap-2 text-xs text-[var(--color-fg-primary)]">
                  <${StatusDot} size="xs" class="bg-[var(--color-status-ok)]" />
                  <span class="truncate font-mono">${tool}</span>
                </div>
              `)
            : html`<div class="text-xs text-[var(--color-fg-muted)]">최근 도구 호출 없음</div>`}
        </div>
      </section>
    </aside>
  `
}

// Removed `KeeperRouteFocusPanel` (2026-05-19): the panel duplicated the
// sticky page header (`KeeperDetailHeaderInfo`) — same keeper name and
// status — and the CLEAR navigation it offered is covered by the existing
// header close button. `agent_name` was the only unique field; it is
// surfaced in the 정체성 / 세대 section. Plan reference:
// ~/me/memory/project_dashboard_keeper_detail_ssot_reconciliation_2026_05_19.md
// Phase 5 (layout retune).

export function KeeperDetailPage() {
  const keeperName =
    route.value.tab === 'monitoring' && route.value.params.section === 'agents'
      ? route.value.params.keeper?.trim()
      : ''
  if (!keeperName) return null

  // Resolve the active keeper. See [resolveKeeperForDetail] for semantics.
  const keeper = resolveKeeperForDetail(
    keeperName,
    findKeeper(keeperName),
    selectedKeeper.peek(),
    keepers.value.length,
  )
  if (!keeper) {
    return html`<${KeeperDetailMissingState} keeperName=${keeperName} onClose=${closeKeeperDetail} />`
  }

  const titleId = `keeper-detail-title-${keeper.name}`
  const effectiveStatus = keeperDisplayStatus(keeper)
  const shouldOpenDiagnostics = keeperNeedsDiagnosticAttention(keeper)
  const [diagOpen, setDiagOpen] = useState(shouldOpenDiagnostics)
  const [clearDialogOpen, setClearDialogOpen] = useState(false)
  const [clearReason, setClearReason] = useState('')
  const [preserveSystemPrompt, setPreserveSystemPrompt] = useState(true)
  const [clearPending, setClearPending] = useState(false)
  const [purgePending, setPurgePending] = useState(false)
  const [checkpointRefreshToken, setCheckpointRefreshToken] = useState(0)
  // Latest transition's wall_clock_at_decision, in unix seconds.  Used by
  // the header KeeperPhaseAndStage to render "현재 phase에 머문 시간" without
  // requiring a new backend field — derivation is plan-approved trade-off.
  const [phaseEnteredAtSec, setPhaseEnteredAtSec] = useState<number | null>(null)
  // RFC-0046 §7 #1: single composite snapshot shared with the two
  // derived panels (state-diagram + memory-tier).
  const compositeEvidence = useKeeperCompositeEvidence(keeper.name)
  const runtimeTraceEvidence = useKeeperRuntimeTraceEvidence(keeper.name)
  // Surface only the `'fresh'` payload to cascading panels.
  // `'stale'` evidence keeps `data` for explicit consumers (with a
  // visible staleness banner via the typed union) but it must NOT
  // silently feed phase/turn/fiber/FSM/mem cards — that is the
  // Workaround Rejection Bar §2 anti-pattern this PR closes.
  const compositeSnapshot = evidenceFreshData(compositeEvidence)
  const runtimeTrace = evidenceFreshData(runtimeTraceEvidence)
  const prevKeeperRef = useRef(keeper.name)
  if (prevKeeperRef.current !== keeper.name) {
    prevKeeperRef.current = keeper.name
    setDiagOpen(shouldOpenDiagnostics)
    setPhaseEnteredAtSec(null)
  }
  useEffect(() => {
    selectedKeeper.value = keeper
    selectKeeper(keeper.name)
    void loadKeeperConfig(keeper.name)
    return () => {
      clearKeeperDetailSelection(keeper.name)
    }
  }, [keeper.name])
  useEffect(() => {
    const controller = new AbortController()
    fetchKeeperTransitions(keeper.name, 1, { signal: controller.signal })
      .then(res => {
        if (controller.signal.aborted) return
        const head = res.transitions?.[0]
        setPhaseEnteredAtSec(
          typeof head?.wall_clock_at_decision === 'number' ? head.wall_clock_at_decision : null,
        )
      })
      .catch(() => {
        // transient fetch failure — leave dwell hidden rather than showing stale
        if (controller.signal.aborted) return
        setPhaseEnteredAtSec(null)
      })
    return () => controller.abort()
  }, [keeper.name, keeper.phase])
  useEffect(() => {
    setClearDialogOpen(false)
    setClearReason('')
    setPreserveSystemPrompt(true)
    setClearPending(false)
  }, [keeper.name])

  // Removed 4 props formerly fed into KeeperDetailOverviewSidebar QuickFacts
  // (2026-05-19): `상태` duplicated the page header status chip,
  // `컨텍스트` duplicated KpiGrid (rendered inside 운영 상태 개요), and
  // `런타임 / runtime` was the literal hardcoded placeholder string with no
  // real data behind it. `최근 활동` duplicated the page header subtitle.
  // Plan reference: ~/me/memory/.../ssot-reconciliation/Phase 5.

  const submitClearContext = () => {
    void (async () => {
      const trimmedReason = clearReason.trim()
      if (!trimmedReason) {
        showToast('사유를 먼저 적으세요', 'warning')
        return
      }
      setClearPending(true)
      try {
        const res = await clearKeeper(keeper.name, {
          reason: trimmedReason,
          preserve_system_prompt: preserveSystemPrompt,
        })
        if (res.ok) {
          setClearDialogOpen(false)
          setClearReason('')
          setPreserveSystemPrompt(true)
          setCheckpointRefreshToken(token => token + 1)
          showToast(`${keeper.name} 컨텍스트를 비웠습니다`, 'success')
          await refreshAfterRuntimeAction()
        } else {
          showToast(res.error ?? '컨텍스트 비우기 실패', 'error')
        }
      } catch (err) {
        showToast(err instanceof Error ? err.message : '컨텍스트 비우기 실패', 'error')
      } finally {
        setClearPending(false)
      }
    })()
  }

  const submitPurgeKeeper = () => {
    void (async () => {
      const confirmed = await requestConfirm({
        title: '키퍼 완전 삭제',
        message: `${keeper.name}를 완전 삭제합니다.\n런타임 상태, 세션 trace, 인증, metrics와 config/keepers/${keeper.name}.toml까지 함께 제거됩니다.`,
        tone: 'danger',
        confirmText: '완전 삭제',
      })
      if (!confirmed) return
      setPurgePending(true)
      try {
        await purgeAgent(keeper.name)
        closeKeeperDetail()
        showToast(`${keeper.name} 완전 삭제됨`, 'success')
        await refreshAfterRuntimeAction()
      } catch (err) {
        showToast(err instanceof Error ? err.message : '키퍼 삭제 실패', 'error')
      } finally {
        setPurgePending(false)
      }
    })()
  }

  return html`
    <div class="keeper-detail-v2-shell mx-auto grid w-full max-w-[1760px] grid-cols-1 gap-4 pb-8 xl:grid-cols-[minmax(17rem,20rem)_minmax(0,1fr)] 2xl:grid-cols-[minmax(17rem,20rem)_minmax(0,1fr)_minmax(18rem,21rem)]" data-route-focused-keeper=${keeper.name}>
      <${KeeperDetailRosterRail} activeKeeperName=${keeper.name} />

      <main class="flex min-w-0 flex-col gap-5">
        <div class="sm:sticky sm:top-0 z-20 w-full overflow-hidden rounded-[var(--r-2)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)] shadow-none backdrop-blur-xl">
          <div class="flex flex-col items-stretch justify-between gap-3 px-4 py-2.5 sm:flex-row sm:items-center sm:px-5">
            <${KeeperDetailHeaderInfo}
              keeper=${keeper}
              titleId=${titleId}
              phaseEnteredAtSec=${phaseEnteredAtSec}
              onClose=${closeKeeperDetail}
            />
            <div class="flex flex-wrap items-center justify-start gap-2 sm:justify-end">
              <button
                type="button"
                class="py-1 px-3 rounded-[var(--r-1)] text-2xs font-semibold cursor-pointer border border-[var(--bad-30)] bg-[var(--bad-10)] text-[var(--rose-light)] hover:bg-[var(--bad-soft)] transition-colors"
                onClick=${() => setClearDialogOpen(true)}
              >비우기</button>
              <button
                type="button"
                disabled=${purgePending}
                class="py-1 px-3 rounded-[var(--r-1)] text-2xs font-semibold cursor-pointer border border-[var(--bad-30)] bg-[var(--bad-10)] text-[var(--rose-light)] hover:bg-[var(--bad-soft)] transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
                onClick=${submitPurgeKeeper}
              >${purgePending ? '삭제 중...' : '완전 삭제'}</button>
              <${KeeperLifecycleButtons} keeper=${keeper} effectiveStatus=${effectiveStatus} />
              <button
                type="button"
                onClick=${() => closeKeeperDetail()}
                class=${`flex items-center justify-center size-8 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] text-[var(--color-fg-muted)] hover:text-[var(--color-fg-secondary)] hover:bg-[var(--color-bg-hover)] transition-colors cursor-pointer text-sm ${CLOSE_BUTTON_FOCUS_CLASS}`}
                aria-label="키퍼 상세 종료"
              >
                <svg aria-hidden="true" width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><line x1="2" y1="2" x2="12" y2="12"/><line x1="12" y1="2" x2="2" y2="12"/></svg>
              </button>
            </div>
          </div>
        </div>

        <${KeeperDetailBody}
          keeper=${keeper}
          compositeSnapshot=${compositeSnapshot}
          runtimeTrace=${runtimeTrace}
          compositeEvidence=${compositeEvidence}
          runtimeTraceEvidence=${runtimeTraceEvidence}
          diagOpen=${diagOpen}
          onDiagToggle=${setDiagOpen}
          checkpointRefreshToken=${checkpointRefreshToken}
          clearDialogOpen=${clearDialogOpen}
          clearPending=${clearPending}
          clearReason=${clearReason}
          preserveSystemPrompt=${preserveSystemPrompt}
          onClearClose=${() => {
            if (clearPending) return
            setClearDialogOpen(false)
          }}
          onClearReasonInput=${setClearReason}
          onPreserveToggle=${setPreserveSystemPrompt}
          onClearSubmit=${submitClearContext}
          onSocialSweep=${() => { void runSocialSweep() }}
        />
      </main>

      <${KeeperContextRail} keeper=${keeper} />
    </div>
  `
}
