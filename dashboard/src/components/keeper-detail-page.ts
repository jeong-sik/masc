import { html } from 'htm/preact'
import { useState, useRef, useEffect } from 'preact/hooks'
import { replaceRoute, route } from '../router'
import { keepers } from '../store'
import { selectKeeper } from '../keeper-runtime'
import { loadKeeperConfig } from './keeper-config-panel'
import { findKeeper } from '../lib/keeper-utils'
import { resolveKeeperForDetail } from '../lib/keeper-detail-resolution'
import {
  keeperDisplayStatus,
  keeperActivityDisplay,
} from '../lib/keeper-runtime-display'
import { clearKeeper, fetchKeeperTransitions } from '../api/keeper'
import { purgeAgent } from '../api/actions'
import { showToast } from './common/toast'
import { requestConfirm } from './common/confirm-dialog'
import {
  selectedKeeper,
  clearKeeperDetailSelection,
  closeKeeperDetail,
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

const CLOSE_BUTTON_FOCUS_CLASS = ringFocusClasses({
  tone: 'accent-medium',
  width: 2,
  offset: 2,
  offsetSurface: 'page',
})

function clearKeeperRouteFocus(): void {
  const params: Record<string, string> = { ...route.value.params, section: 'agents' }
  delete params.agent
  delete params.keeper
  replaceRoute('monitoring', params)
}

function KeeperRouteFocusPanel({
  keeperName,
  status,
  agentName,
}: {
  keeperName: string
  status: string
  agentName?: string | null
}) {
  return html`
    <section
      class="rounded-[var(--r-1)] border border-[var(--color-brass-border)] bg-[var(--color-brass-soft)] px-3 py-2"
      data-testid="keeper-route-focus"
      aria-label="Keeper route focus"
    >
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="font-mono text-3xs font-semibold uppercase tracking-[var(--track-section)] text-[var(--color-accent-fg)]">
            ROUTE FOCUS
          </div>
          <div class="mt-1 flex min-w-0 flex-wrap items-center gap-2 text-xs text-[var(--color-fg-secondary)]">
            <span class="rounded-[var(--r-0)] border border-[var(--color-brass-border)] bg-[var(--color-bg-page)] px-2 py-1 font-mono text-3xs text-[var(--color-accent-fg)]">
              KEEPER ${keeperName}
            </span>
            <span class="font-mono text-3xs text-[var(--color-fg-muted)]">status ${status}</span>
            ${agentName ? html`
              <span class="font-mono text-3xs text-[var(--color-fg-muted)]">agent ${agentName}</span>
            ` : null}
          </div>
        </div>
        <button
          type="button"
          class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)] px-2 py-1 font-mono text-3xs text-[var(--color-fg-muted)] transition-colors hover:border-[var(--color-border-strong)] hover:text-[var(--color-fg-primary)]"
          onClick=${clearKeeperRouteFocus}
        >
          CLEAR
        </button>
      </div>
    </section>
  `
}

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

  const contextRatioPct =
    typeof keeper.context_ratio === 'number' && Number.isFinite(keeper.context_ratio)
      ? `${Math.round(keeper.context_ratio * 100)}%`
      : '정보 없음'
  const effectiveModelLabel = '런타임'
  const effectiveModel = 'runtime'
  const activityDisplay = keeperActivityDisplay(keeper, keeper.agent?.last_seen)

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
    <div class="mx-auto flex w-full max-w-[1600px] flex-col gap-5 pb-8" data-route-focused-keeper=${keeper.name}>
      <div class="sticky top-0 z-20 overflow-hidden rounded-[var(--r-6)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] shadow-[var(--shadow-raised)] backdrop-blur-xl">
        <div class="flex flex-col items-stretch justify-between gap-4 border-b border-[var(--color-border-default)] px-5 py-4 sm:flex-row sm:items-center sm:px-6">
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

      <${KeeperRouteFocusPanel}
        keeperName=${keeper.name}
        status=${effectiveStatus}
        agentName=${keeper.agent_name ?? keeper.agent?.name ?? null}
      />

      <${KeeperDetailBody}
        keeper=${keeper}
        effectiveStatus=${effectiveStatus}
        contextRatioPct=${contextRatioPct}
        effectiveModelLabel=${effectiveModelLabel}
        effectiveModel=${effectiveModel}
        activityDisplay=${activityDisplay}
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
    </div>
  `
}
