import { html } from 'htm/preact'
import { lazy, memo, Suspense } from 'preact/compat'
import { useState, useRef, useEffect } from 'preact/hooks'
import { ChevronLeft, ChevronRight } from 'lucide-preact'
import type { Keeper } from '../types'
import { route } from '../router'
import { keepers } from '../store'
import { selectKeeper } from '../keeper-actions'
import { loadKeeperConfig } from './keeper-config-state'
import { findKeeper } from '../lib/keeper-utils'
import { resolveKeeperForDetail } from '../lib/keeper-detail-resolution'
import { mostRecentlyActiveKeeper } from '../lib/keeper-recency'
import { keeperDisplayStatus } from '../lib/keeper-runtime-display'
import { clearKeeper, fetchKeeperTransitions } from '../api/keeper'
import { purgeAgent } from '../api/actions'
import { showToast } from './common/toast'
import { requestConfirm } from './common/confirm-dialog'
import {
  selectedKeeper,
  clearKeeperDetailSelection,
  closeKeeperDetail,
  keeperMobilePane,
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
import { KeeperLifecycleButtons, KeeperClearContextDialog } from './keeper-detail-lifecycle'
import {
  KeeperDetailHeaderInfo,
  KeeperDetailMissingState,
  activeKeeperDetailSection,
} from './keeper-detail-shell'
import { KeeperWorkspaceRoster } from './keeper-workspace/keeper-workspace-roster'
import { KeeperWorkspaceChat } from './keeper-workspace/keeper-workspace-chat'
import { KeeperWorkspaceRail } from './keeper-workspace/keeper-workspace-rail'
import {
  beginPaneResize,
  clampPaneWidth,
  effectiveRosterWidthForViewport,
  rosterWidth,
  railWidth,
} from './keeper-workspace/keeper-workspace-pane-resize'
import { ringFocusClasses } from './common/ring'
import { tweaksRosterOpen, tweaksCtxOpen } from './tweaks-panel'

const CLOSE_BUTTON_FOCUS_CLASS = ringFocusClasses({
  tone: 'accent-medium',
  width: 2,
  offset: 2,
  offsetSurface: 'page',
})

const LazyKeeperDetailBody = lazy(async () => ({
  default: (await import('./keeper-detail-body')).KeeperDetailBody,
}))

const LazyKeeperConfigPanel = lazy(async () => ({
  default: (await import('./keeper-config-panel')).KeeperConfigPanel,
}))

// Removed `KeeperRouteFocusPanel` (2026-05-19): the panel duplicated the
// sticky page header (`KeeperDetailHeaderInfo`) — same keeper name and
// status — and the CLEAR navigation it offered is covered by the existing
// header close button. `agent_name` was the only unique field; it is
// surfaced in the 정체성 / 세대 section. Plan reference:
// ~/me/memory/project_dashboard_keeper_detail_ssot_reconciliation_2026_05_19.md
// Phase 5 (layout retune).

export function KeeperDetailPage() {
  const routeSurface = route.value.tab === 'keepers' ? 'keepers' : 'monitoring'
  const keeperName = route.value.tab === 'keepers'
    ? route.value.params.keeper?.trim() || selectedKeeper.peek()?.name || mostRecentlyActiveKeeper(keepers.value)?.name || ''
    : route.value.tab === 'monitoring' && route.value.params.section === 'agents'
      ? route.value.params.keeper?.trim()
      : ''

  if (!keeperName) {
    return html`
      <div class="kw-grid" data-detail="open">
        <${KeeperWorkspaceRoster} activeName="" routeSurface=${routeSurface} />
        <div class="kw-detail">
          <div class="kw-detail-scroll">
            <div class="rounded-[var(--r-2)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-6 text-sm text-[var(--color-fg-muted)]">
              표시할 keeper가 없습니다.
            </div>
          </div>
        </div>
      </div>
    `
  }
  return html`<${KeeperDetailResolver} keeperName=${keeperName} routeSurface=${routeSurface} />`
}

// P0 render-perf: isolate the `keepers` signal subscription here. A heartbeat,
// turn, or phase update on *any* keeper mutates the global `keepers` array and
// would otherwise re-render the whole detail subtree (chat + rail + body,
// ~1,400 LOC). keeper identity is reference-stable via `reconcileKeepers`, so
// memoizing KeeperDetailContent below skips the heavy subtree whenever the
// resolved keeper object did not change — which is every heartbeat that is
// not this keeper's phase transition.
function KeeperDetailResolver({
  keeperName,
  routeSurface,
}: {
  keeperName: string
  routeSurface: 'monitoring' | 'keepers'
}) {
  const keeper = resolveKeeperForDetail(
    keeperName,
    findKeeper(keeperName),
    selectedKeeper.peek(),
    keepers.value.length,
  )
  if (!keeper) {
    // Keep the roster mounted so the operator can switch to a live keeper
    // in place (a stale-watchdog kill or dead deep link must not strand the
    // 3-pane shell). `data-detail="open"` drops the empty rail column and
    // gives the missing-state card the full conversation span.
    return html`
      <div class="kw-grid" data-detail="open">
        <${KeeperWorkspaceRoster} activeName=${keeperName} routeSurface=${routeSurface} />
        <div class="kw-detail">
          <div class="kw-detail-scroll">
            <${KeeperDetailMissingState} keeperName=${keeperName} onClose=${closeKeeperDetail} />
          </div>
        </div>
      </div>
    `
  }
  return html`<${KeeperDetailContent} keeper=${keeper} routeSurface=${routeSurface} />`
}

// Breakpoints mirror keeper-workspace.css responsive bands: at <=1180px the
// context-rail column is dropped, at <=860px the layout collapses to a single
// mobile pane.
const KW_MOBILE_QUERY = '(max-width: 860px)'
const KW_NARROW_QUERY = '(max-width: 1180px)'

function useMatchMedia(query: string): boolean {
  const getInitial = () =>
    typeof window !== 'undefined' &&
    typeof window.matchMedia === 'function' &&
    window.matchMedia(query).matches
  const [matches, setMatches] = useState(getInitial)

  useEffect(() => {
    if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') return
    const media = window.matchMedia(query)
    const update = () => setMatches(media.matches)
    update()
    media.addEventListener('change', update)
    return () => media.removeEventListener('change', update)
  }, [query])

  return matches
}

const KeeperDetailContent = memo(function KeeperDetailContent({
  keeper,
  routeSurface,
}: {
  keeper: Keeper
  routeSurface: 'monitoring' | 'keepers'
}) {
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
  // 3-pane workspace is the default conversation view; "운영 상세" flips to
  // the full tabbed KeeperDetailBody (FSM / 진단 / 정체성 / 설정 / 디버그).
  const [detailOpen, setDetailOpen] = useState(false)
  const [configOverlayKeeper, setConfigOverlayKeeper] = useState<string | null>(null)
  const rosterOpen = tweaksRosterOpen.value
  const setRosterOpen = (v: boolean | ((prev: boolean) => boolean)) => {
    tweaksRosterOpen.value = typeof v === 'function' ? v(tweaksRosterOpen.value) : v
  }
  const railOpen = tweaksCtxOpen.value
  const setRailOpen = (v: boolean | ((prev: boolean) => boolean)) => {
    tweaksCtxOpen.value = typeof v === 'function' ? v(tweaksCtxOpen.value) : v
  }
  const isMobile = useMatchMedia(KW_MOBILE_QUERY)
  // <=1180px drops the rail column entirely (keeper-workspace.css), so the right
  // resizer must not render there even when railOpen is still toggled on.
  const isNarrow = useMatchMedia(KW_NARROW_QUERY)
  const [mobileRailState, setMobileRailState] = useState<{ keeperName: string; open: boolean }>(() => ({
    keeperName: keeper.name,
    open: false,
  }))
  const mobileRailOpen = mobileRailState.keeperName === keeper.name && mobileRailState.open
  const setMobileRailOpenForKeeper = (open: boolean) => {
    setMobileRailState({ keeperName: keeper.name, open })
  }
  // Latest transition's wall_clock_at_decision, in unix seconds.  Used by
  // the header KeeperPhaseAndStage to render "현재 phase에 머문 시간" without
  // requiring a new backend field — derivation is plan-approved trade-off.
  const [phaseEnteredAtSec, setPhaseEnteredAtSec] = useState<number | null>(null)
  const pendingConfigKeeperRef = useRef<string | null>(null)
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
    const shouldOpenPendingConfig = pendingConfigKeeperRef.current === keeper.name
    prevKeeperRef.current = keeper.name
    if (shouldOpenPendingConfig) {
      pendingConfigKeeperRef.current = null
    }
    setDiagOpen(shouldOpenDiagnostics)
    setPhaseEnteredAtSec(null)
    setDetailOpen(false)
    setConfigOverlayKeeper(shouldOpenPendingConfig ? keeper.name : null)
  }
  useEffect(() => {
    selectedKeeper.value = keeper
    selectKeeper(keeper.name)
    void loadKeeperConfig(keeper.name)
    // Entering a keeper (mount or keeper change) always lands on the chat pane
    // on mobile. keeperMobilePane is a module-global signal; the back button
    // sets it to 'roster', but many entry points (command palette, overview
    // cards, reactivity monitor, …) route straight to a keeper via navigate()
    // without going through openKeeperDetail/roster-select, so without this
    // reset a stale 'roster' would hide the chat of the keeper just selected.
    keeperMobilePane.value = 'chat'
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

  // Full tabbed detail (FSM / 진단 / 정체성 / 설정 / 디버그) — the original
  // detail-page layout, preserved verbatim and surfaced behind "운영 상세".
  const detailContent = html`
    <div class="kw-detail-content mx-auto flex w-full max-w-[1380px] flex-col gap-5 pb-8 v2-monitoring-surface" data-route-focused-keeper=${keeper.name}>
      <div class="kw-detail-full-head sm:sticky sm:top-0 z-20 mx-auto w-full max-w-[1180px] overflow-hidden rounded-[var(--r-2)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)] shadow-none backdrop-blur-xl v2-monitoring-toolbar">
        <div class="flex flex-col items-stretch justify-between gap-3 px-4 py-2.5 sm:flex-row sm:items-center sm:px-5">
          <${KeeperDetailHeaderInfo}
            keeper=${keeper}
            titleId=${titleId}
            phaseEnteredAtSec=${phaseEnteredAtSec}
            onClose=${() => setDetailOpen(false)}
          />
          <div class="flex flex-wrap items-center justify-start gap-2 sm:justify-end v2-monitoring-toolbar">
            <button
              type="button"
              class="py-1 px-3 rounded-[var(--r-1)] text-2xs font-semibold cursor-pointer border border-[var(--bad-30)] bg-[var(--bad-10)] text-[var(--color-status-err)] hover:bg-[var(--bad-soft)] transition-colors v2-monitoring-action"
              onClick=${() => setClearDialogOpen(true)}
            >비우기</button>
            <button
              type="button"
              disabled=${purgePending}
              class="py-1 px-3 rounded-[var(--r-1)] text-2xs font-semibold cursor-pointer border border-[var(--bad-30)] bg-[var(--bad-10)] text-[var(--color-status-err)] hover:bg-[var(--bad-soft)] transition-colors disabled:opacity-50 disabled:cursor-not-allowed v2-monitoring-action"
              onClick=${submitPurgeKeeper}
            >${purgePending ? '삭제 중...' : '완전 삭제'}</button>
            <${KeeperLifecycleButtons} keeper=${keeper} effectiveStatus=${effectiveStatus} />
            <button
              type="button"
              onClick=${() => closeKeeperDetail()}
              class=${`flex items-center justify-center size-8 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] text-[var(--color-fg-muted)] hover:text-[var(--color-fg-secondary)] hover:bg-[var(--color-bg-hover)] transition-colors cursor-pointer text-sm ${CLOSE_BUTTON_FOCUS_CLASS} v2-monitoring-action`}
              aria-label="키퍼 상세 종료"
            >
              <svg aria-hidden="true" width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><line x1="2" y1="2" x2="12" y2="12"/><line x1="12" y1="2" x2="2" y2="12"/></svg>
            </button>
          </div>
        </div>
      </div>

      <${Suspense} fallback=${html`<div class="rounded-[var(--r-2)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-4 text-sm text-[var(--color-fg-muted)]">상세 로딩…</div>`}>
        <${LazyKeeperDetailBody}
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
      <//>
    </div>
  `
  const openKeeperConfig = (name = keeper.name) => {
    activeKeeperDetailSection.value = 'keeper-config'
    setMobileRailOpenForKeeper(false)
    if (name !== keeper.name) {
      pendingConfigKeeperRef.current = name
    }
    setDetailOpen(false)
    setConfigOverlayKeeper(name)
  }

  // Drag-resizable roster/rail columns in the desktop 3-pane chat view. Only set
  // the width vars when the pane is open (mini/closed states keep their CSS-driven
  // widths), and only outside detail/mobile layouts where the grid differs.
  const paneResizable = !detailOpen && !isMobile
  const gridStyle = paneResizable
    ? {
        ...(rosterOpen ? { '--kw-roster-w': `${effectiveRosterWidthForViewport(rosterWidth.value, isNarrow)}px` } : {}),
        ...(railOpen ? { '--kw-rail-w': `${clampPaneWidth('rail', railWidth.value)}px` } : {}),
      }
    : undefined

  return html`
    <div
      class="kw-grid v2-monitoring-surface"
      style=${gridStyle}
      data-detail=${detailOpen ? 'open' : 'closed'}
      data-roster=${rosterOpen ? 'open' : 'mini'}
      data-rail=${railOpen ? 'open' : 'closed'}
      data-mobile-pane=${keeperMobilePane.value}
      data-route-focused-keeper=${keeper.name}
    >
      ${paneResizable && rosterOpen
        ? html`<div
            class="kw-pane-resizer left"
            role="separator"
            aria-orientation="vertical"
            aria-label="로스터 폭 조절"
            title="드래그하여 로스터 폭 조절"
            onPointerDown=${(e: PointerEvent) =>
              beginPaneResize('roster', e, (e.currentTarget as HTMLElement).closest('.kw-grid') as HTMLElement)}
          ></div>`
        : null}
      ${paneResizable && railOpen && !isNarrow
        ? html`<div
            class="kw-pane-resizer right"
            role="separator"
            aria-orientation="vertical"
            aria-label="컨텍스트 레일 폭 조절"
            title="드래그하여 컨텍스트 레일 폭 조절"
            onPointerDown=${(e: PointerEvent) =>
              beginPaneResize('rail', e, (e.currentTarget as HTMLElement).closest('.kw-grid') as HTMLElement)}
          ></div>`
        : null}
      <${KeeperWorkspaceRoster}
        activeName=${keeper.name}
        routeSurface=${routeSurface}
        mini=${!rosterOpen && !detailOpen}
        onOpenConfig=${openKeeperConfig}
        onSelect=${() => {
          keeperMobilePane.value = 'chat'
        }}
      />
      ${detailOpen
        ? html`
            <div class="kw-detail v2-monitoring-panel">
              <div class="kw-detail-head v2-monitoring-toolbar">
                <button type="button" class="kw-act v2-monitoring-action" onClick=${() => setDetailOpen(false)}>← 대화로</button>
                <strong class="text-sm font-semibold text-[var(--color-fg-primary)]">${keeper.name} · 상세</strong>
                <span class="flex-1"></span>
                <button
                  type="button"
                  class=${`kw-act ${CLOSE_BUTTON_FOCUS_CLASS} v2-monitoring-action`}
                  onClick=${() => closeKeeperDetail()}
                >← Keepers</button>
              </div>
              <div class="kw-detail-scroll v2-monitoring-panel">${detailContent}</div>
            </div>
          `
        : html`
            <button
              type="button"
              class="kw-rail-toggle left v2-monitoring-action"
              aria-label=${rosterOpen ? '로스터 접기' : '로스터 펼치기'}
              aria-pressed=${rosterOpen ? 'true' : 'false'}
              title=${rosterOpen ? '로스터 접기' : '로스터 펼치기'}
              onClick=${() => setRosterOpen(open => !open)}
            >
              ${rosterOpen
                ? html`<${ChevronLeft} size=${14} aria-hidden="true" />`
                : html`<${ChevronRight} size=${14} aria-hidden="true" />`}
            </button>
            <${KeeperWorkspaceChat}
              keeper=${keeper}
              mobile=${isMobile}
              onBack=${() => {
                keeperMobilePane.value = 'roster'
              }}
              onOpenRail=${() => setMobileRailOpenForKeeper(true)}
              onOpenConfig=${() => {
                openKeeperConfig()
              }}
              onOpenDetail=${() => setDetailOpen(true)}
            />
            <button
              type="button"
              class="kw-rail-toggle right v2-monitoring-action"
              aria-label=${railOpen ? '컨텍스트 레일 접기' : '컨텍스트 레일 펼치기'}
              aria-pressed=${railOpen ? 'true' : 'false'}
              title=${railOpen ? '컨텍스트 레일 접기' : '컨텍스트 레일 펼치기'}
              onClick=${() => setRailOpen(open => !open)}
            >
              ${railOpen
                ? html`<${ChevronRight} size=${14} aria-hidden="true" />`
                : html`<${ChevronLeft} size=${14} aria-hidden="true" />`}
            </button>
            ${!isMobile && railOpen ? html`<${KeeperWorkspaceRail} keeper=${keeper} />` : null}
            ${isMobile && mobileRailOpen
              ? html`
                  <div
                    class="kw-mobile-rail-overlay"
                    role="dialog"
                    aria-modal="true"
                    aria-label="키퍼 컨텍스트"
                    data-testid="kw-mobile-rail-overlay"
                    onClick=${() => setMobileRailOpenForKeeper(false)}
                  >
                    <div class="kw-mobile-rail-drawer v2-monitoring-surface" onClick=${(e: Event) => e.stopPropagation()}>
                      <div class="kw-mobile-rail-head v2-monitoring-toolbar">
                        <strong>${keeper.name} 컨텍스트</strong>
                        <button
                          type="button"
                          class="kw-act v2-monitoring-action"
                          onClick=${() => setMobileRailOpenForKeeper(false)}
                        >닫기</button>
                      </div>
                      <${KeeperWorkspaceRail} keeper=${keeper} />
                    </div>
                  </div>
                `
              : null}
          `}
    </div>
    ${!detailOpen
      ? html`<${KeeperClearContextDialog}
          keeperName=${keeper.name}
          open=${clearDialogOpen}
          pending=${clearPending}
          reason=${clearReason}
          preserveSystemPrompt=${preserveSystemPrompt}
          onClose=${() => {
            if (clearPending) return
            setClearDialogOpen(false)
          }}
          onReasonInput=${setClearReason}
          onPreserveToggle=${setPreserveSystemPrompt}
          onSubmit=${submitClearContext}
        />`
      : null}
    ${configOverlayKeeper
      ? html`<${KeeperConfigOverlay}
          keeperName=${configOverlayKeeper}
          onClose=${() => setConfigOverlayKeeper(null)}
        />`
      : null}
  `
})

function KeeperConfigOverlay({
  keeperName,
  onClose,
}: {
  keeperName: string
  onClose: () => void
}) {
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        event.stopPropagation()
        onClose()
      }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [onClose])

  // The panel now owns the full .kcf-overlay modal shell (top bar + 8-tab rail +
  // footer close), so the host is a thin wrapper that only supplies the ESC
  // keybinding and the onClose callback. (Backdrop click + the footer/top 닫기
  // buttons are rendered by the panel itself.)
  return html`
    <${Suspense} fallback=${html`<div class="kcf-overlay" data-testid="kw-config-overlay"><div class="kcf v2-monitoring-surface">설정 로딩…</div></div>`}>
      <${LazyKeeperConfigPanel} keeperName=${keeperName} onClose=${onClose} />
    <//>
  `
}
