/**
 * Right Keeper Header Hero (48px portrait.png + Candle Brass 14% halo + lifecycle controls + 5 entity tabs).
 */

import { html } from 'htm/preact'
import { contextSeverityTone } from '../../api/keeper-diagnostics'
import { useEffect, useRef, useState } from 'preact/hooks'
import { useFocusScope } from '../../../design-system/headless-preact/use-focus-scope'
import { activeWorkspaceId, authSession, currentSessionEpoch, isEpochCurrent, sessionEpoch } from '../../core/auth'
import { extractObserverTopics, subscribeObserverFrames, subscribeObserverReconnect } from '../../core/observer'
import { formatObserved, resourceCache, type Observed } from '../../core/resource-cache'
import { useAuthenticatedPortrait } from '../../lib/portrait-cache'
import { keeperPortraitUrl, kSigil } from '../../components/keeper-badge'
import { PopoverMenu, type PopoverMenuItem } from '../../components/primitives/popover-menu'
import { TargetLockedAction } from '../../components/primitives/target-locked-action'
import {
  bootKeeperAction,
  deleteKeeperAction,
  formatContextDetail,
  interruptKeeperTurnAction,
  isKeeperPathResting,
  loadKeeperToolApprovalModes,
  needsRosterAttention,
  observeRosterContextPct,
  pauseKeeperAction,
  resumeKeeperAction,
} from './keepers-api'
import {
  KEEPER_ENTITY_TAB_LABELS,
  KEEPER_ENTITY_TABS,
  type KeeperEntityTab,
} from '../../routes/router'
import type { KeeperRosterItem, KeeperToolApprovalModesData } from './types'
import { isWaitingUnavailable } from './turn-context'

export interface KeeperHeaderProps {
  readonly keeper: KeeperRosterItem
  readonly turnStatus?: Observed<unknown>['kind']
  readonly activeTab: KeeperEntityTab
  readonly onSelectTab: (tab: KeeperEntityTab) => void
  readonly onLifecycleMutated: () => void
  readonly onDeleted: () => void
}

/** A server due time as local time; the ISO text when it does not parse. */
function formatDueAt(iso: string): string {
  const date = new Date(iso)
  return Number.isNaN(date.getTime()) ? iso : date.toLocaleString()
}

const PURGE_ARTIFACTS: readonly string[] = [
  '메트릭·결정·상태 전이 로그',
  'Memory OS 스냅샷과 저널',
  'TOML 설정 및 대화 기록',
  '격리 작업 디렉터리 및 토큰',
]

const UNBOOTED_PHASES = new Set(['offline', 'stopped', 'crashed'])
const UNBOOTED_STATUSES = new Set(['unbooted', 'offline', 'stopped', 'crashed', 'dead'])
const LIVE_PHASES = new Set(['running', 'failing', 'draining', 'restarting', 'paused'])

export function isKeeperBooted(keeper: KeeperRosterItem): boolean {
  if (keeper.keepalive_running) return true
  if (keeper.paused) return true
  const phase = keeper.phase.trim().toLowerCase()
  const status = keeper.status.trim().toLowerCase()
  if (UNBOOTED_PHASES.has(phase) || UNBOOTED_STATUSES.has(status)) return false
  return LIVE_PHASES.has(phase) || status === 'running' || status === 'active'
}

export function KeeperHeader(props: KeeperHeaderProps) {
  const { keeper } = props
  const rawPortraitUrl = keeperPortraitUrl(keeper.name, 96)
  const authenticatedPortraitSrc = useAuthenticatedPortrait(rawPortraitUrl)
  const [failedSrc, setFailedSrc] = useState<string | null>(null)
  const [busyAction, setBusyAction] = useState<string | null>(null)
  const [statusMessage, setStatusMessage] = useState<{ readonly tone: 'ok' | 'bad'; readonly text: string } | null>(null)
  const [deleteOpen, setDeleteOpen] = useState(false)
  const [deleteConfirmName, setDeleteConfirmName] = useState('')
  const [deleteError, setDeleteError] = useState<string | null>(null)
  const deleteModalRef = useRef<HTMLDivElement>(null)
  const deleteInputRef = useRef<HTMLInputElement>(null)
  const mountedRef = useRef(true)
  const activeKeeperRef = useRef(keeper.name)
  activeKeeperRef.current = keeper.name

  useEffect(() => {
    mountedRef.current = true
    return () => {
      mountedRef.current = false
    }
  }, [])

  useFocusScope({
    containerRef: deleteModalRef,
    active: deleteOpen,
    initialFocus: () => deleteInputRef.current,
  })

  const closeDeleteModal = () => {
    setDeleteOpen(false)
    setDeleteConfirmName('')
    setDeleteError(null)
  }

  useEffect(() => {
    setStatusMessage(null)
    closeDeleteModal()
  }, [keeper.name])

  useEffect(() => {
    if (!deleteOpen) return
    queueMicrotask(() => deleteInputRef.current?.focus())
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.defaultPrevented || event.isComposing || event.keyCode === 229) return
      if (event.key === 'Escape') {
        if (typeof document !== 'undefined') {
          const otherModalOpen = Array.from(
            document.querySelectorAll('[role="dialog"][aria-modal="true"]'),
          ).some((el) => el !== deleteModalRef.current)
          if (otherModalOpen) return
        }
        event.preventDefault()
        event.stopPropagation()
        closeDeleteModal()
      }
    }
    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [deleteOpen])

  const isSingleUser = authSession.value.kind === 'single_user_local'
  const epoch = sessionEpoch.value
  const approvalModesObs = resourceCache.observe<KeeperToolApprovalModesData>('keepers:tool-approval-modes').value

  useEffect(() => {
    if (!isSingleUser) return
    void loadKeeperToolApprovalModes('mount')
    const unsub = subscribeObserverFrames((frame) => {
      const topics = extractObserverTopics(frame)
      if (topics.includes('keeper_tool_approval_mode_changed')) {
        void loadKeeperToolApprovalModes('sse')
      }
    })
    const unsubReconnect = subscribeObserverReconnect(() => {
      void loadKeeperToolApprovalModes('sse')
    })
    return () => {
      unsub()
      unsubReconnect()
    }
  }, [isSingleUser, epoch])

  const approvalMode = isSingleUser && approvalModesObs.kind === 'value'
    ? (approvalModesObs.data.overrides[keeper.name] ?? approvalModesObs.data.defaultMode)
    : null
  const approvalModeRestoreError = isSingleUser && approvalModesObs.kind === 'value'
    ? approvalModesObs.data.restoreError
    : null

  const ctxObs = observeRosterContextPct(keeper)
  const ctxDetail = formatContextDetail(keeper)
  const ctxText = ctxObs.kind === 'value' ? ctxDetail.label : formatObserved(ctxObs, (v) => `${v}%`)
  const failing = needsRosterAttention(keeper)
  const booted = isKeeperBooted(keeper)
  const isPaused = keeper.paused || keeper.phase.trim().toLowerCase() === 'paused'
  const resting = isKeeperPathResting(keeper)
  const turnPreview = keeper.active_turn?.preview
  const waitingUnavailable = isWaitingUnavailable(keeper.waiting_summary) ? keeper.waiting_summary : null
  const waitingSummary = keeper.waiting_summary && !isWaitingUnavailable(keeper.waiting_summary)
    ? keeper.waiting_summary : null
  const statusMentionsTool = (statusText: string, toolName: string): boolean => {
    const escaped = toolName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
    return new RegExp(`(^|[^A-Za-z0-9_-])${escaped}($|[^A-Za-z0-9_-])`).test(statusText)
  }
  const turnDetail =
    (turnPreview
      ? [
          turnPreview.status_text || null,
          turnPreview.last_tool && !statusMentionsTool(turnPreview.status_text, turnPreview.last_tool) ? turnPreview.last_tool : null,
          turnPreview.text_tail && turnPreview.text_tail !== turnPreview.status_text ? turnPreview.text_tail : null,
        ]
          .filter((p): p is string => Boolean(p))
          .join(' · ') || null
      : null)
  const laneFailures = keeper.runtime_lane_failures ?? []
  const turnBreakdown = keeper.turns_24h_breakdown
  const actionableDisposition =
    keeper.operator_disposition && keeper.operator_disposition !== 'pass'
      ? keeper.operator_disposition
      : null
  const hasBlockingFault = Boolean(
    resting
    || keeper.directory_issue
    || keeper.runtime_blocker_summary
    || approvalModeRestoreError
    || waitingUnavailable
    || (waitingSummary && waitingSummary.count > 0)
    || actionableDisposition,
  )
  const hasDiagnostics = Boolean(
    hasBlockingFault
    || keeper.last_failure
    || laneFailures.length > 0
    || (turnBreakdown && (turnBreakdown.failed > 0 || turnBreakdown.rested > 0)),
  )
  const diagSummaryParts: string[] = []
  if (keeper.directory_issue) diagSummaryParts.push(`설정 오류: ${keeper.directory_issue}`)
  if (keeper.runtime_blocker_summary) diagSummaryParts.push(`차단: ${keeper.runtime_blocker_summary}`)
  if (resting) diagSummaryParts.push(`경로 휴식 (${keeper.runtime_path_rest?.runtime_id ?? keeper.runtime_id})`)
  if (approvalModeRestoreError) diagSummaryParts.push('승인 모드 복구 오류')
  if (waitingUnavailable) diagSummaryParts.push('대기 목록 읽기 실패')
  else if (waitingSummary && waitingSummary.count > 0) diagSummaryParts.push(`대기 ${waitingSummary.count}건`)
  if (actionableDisposition) diagSummaryParts.push(`조치: ${actionableDisposition}`)
  if (laneFailures.length > 0) diagSummaryParts.push(`폴백 시도 ${laneFailures.length}건`)
  if (turnBreakdown && (turnBreakdown.failed > 0 || turnBreakdown.rested > 0)) {
    diagSummaryParts.push(`24h 실패 ${turnBreakdown.failed} · 휴식 ${turnBreakdown.rested}`)
  }
  if (diagSummaryParts.length === 0 && keeper.last_failure) {
    diagSummaryParts.push(`최근 실패: ${keeper.last_failure.cause}`)
  }
  const diagSummaryText = diagSummaryParts.slice(0, 2).join(' · ') || '런타임 진단 상세'
  const turnStatusLabel = props.turnStatus === 'loading'
    ? '조회 중…'
    : props.turnStatus === 'failed'
      ? '조회 실패'
      : keeper.active_turn
        ? `실행 중 (${keeper.active_turn.lane})`
        : '유휴'
  const metaTriggerClass = approvalMode === 'yolo'
    ? 'kp-meta-trigger kp-meta-trigger--bad'
    : props.turnStatus === 'failed'
      ? 'kp-meta-trigger kp-meta-trigger--warn'
      : 'kp-meta-trigger'
  const metaTriggerLabel = approvalMode === 'yolo'
    ? '상태 · ⚠ YOLO ▾'
    : props.turnStatus === 'failed'
      ? '상태 · ⚠ ▾'
      : '상태 ▾'
  const overflowActionItems: PopoverMenuItem[] = [
    ...(booted && keeper.active_turn === null
      ? [{
          id: 'interrupt',
          label: 'Interrupt Turn',
          description: '유휴 상태에서도 턴 중단 신호 전송',
          disabled: busyAction !== null,
          onSelect: () => void runLifecycle('Interrupt Turn', () => interruptKeeperTurnAction(keeper.name)),
        }]
      : []),
    {
      id: 'delete',
      label: 'Delete',
      description: 'Keeper 및 모든 아티팩트 영구 삭제',
      danger: true,
      separatorBefore: booted && keeper.active_turn === null,
      disabled: busyAction !== null,
      onSelect: () => setDeleteOpen(true),
    },
  ]

  const runLifecycle = async (
    label: string,
    fn: () => Promise<{ ok: boolean; error?: { message: string } }>,
  ) => {
    const targetKeeper = keeper.name
    const startEpoch = currentSessionEpoch()
    setBusyAction(label)
    setStatusMessage(null)
    const res = await fn()
    if (!mountedRef.current || activeKeeperRef.current !== targetKeeper || !isEpochCurrent(startEpoch)) return
    setBusyAction(null)
    if (!res.ok) {
      setStatusMessage({ tone: 'bad', text: `${label} 실패: ${res.error?.message ?? '오류'}` })
      return
    }
    setStatusMessage({ tone: 'ok', text: `${label} 요청이 처리되었습니다.` })
    props.onLifecycleMutated()
  }

  const handleConfirmDelete = async () => {
    const targetKeeper = keeper.name
    if (deleteConfirmName.trim() !== targetKeeper) return
    const startEpoch = currentSessionEpoch()
    setBusyAction('delete')
    setDeleteError(null)
    const res = await deleteKeeperAction(targetKeeper)
    if (!mountedRef.current || activeKeeperRef.current !== targetKeeper || !isEpochCurrent(startEpoch)) return
    setBusyAction(null)
    if (!res.ok) {
      const msg = `삭제 실패: ${res.error.message}`
      setDeleteError(msg)
      setStatusMessage({ tone: 'bad', text: msg })
      return
    }
    setDeleteOpen(false)
    setDeleteConfirmName('')
    setDeleteError(null)
    props.onDeleted()
  }

  return html`
    <header class="kp-hero">
      <div class="kp-hero-top">
        <div class="kp-hero-id">
          <div class="kp-hero-portrait-ring">
            ${authenticatedPortraitSrc !== null && failedSrc !== authenticatedPortraitSrc
              ? html`
                  <img
                    class="kp-hero-portrait-img"
                    src=${authenticatedPortraitSrc}
                    data-portrait-url=${rawPortraitUrl}
                    alt=${`${keeper.name} portrait`}
                    onError=${() => setFailedSrc(authenticatedPortraitSrc)}
                  />
                `
              : html`
                  <span class="kp-hero-portrait-sigil" aria-label=${keeper.name}>
                    ${kSigil(keeper.name)}
                  </span>
                `}
          </div>

          <div class="kp-hero-text">
            <h1 class="kp-hero-name">${keeper.name}</h1>
            <div class="kp-pill-row">
              <span class="kp-pill" data-tone=${failing ? 'bad' : resting || keeper.paused ? 'warn' : 'ok'}>
                ${failing ? `⚠ ${keeper.health}` : resting ? '⏸ 휴식 중' : keeper.paused ? 'Paused' : keeper.health}
              </span>
              <span
                class="kp-pill"
                data-ctx="true"
                data-tone=${(() => {
                  const tone = ctxObs.kind === 'value' ? contextSeverityTone(ctxObs.data) : 'absent'
                  return tone === 'bad' ? 'bad' : tone === 'warn' ? 'warn' : 'brass'
                })()}
                title=${ctxDetail.tooltip}
              >
                Ctx ${ctxText}
              </span>
              ${keeper.active_turn && html`
                <span class="kp-pill" data-tone="brass" title=${turnDetail ?? undefined}>
                  ● Turn (${keeper.active_turn.lane}${turnDetail ? ` · ${turnDetail}` : ''})
                </span>
              `}
              ${waitingSummary && waitingSummary.count > 0 && html`
                <span
                  class="kp-pill"
                  data-tone="warn"
                  title=${waitingSummary.primary_reason ?? undefined}
                >
                  대기 ${waitingSummary.count}${waitingSummary.primary_reason ? ` · ${waitingSummary.primary_reason}` : ''}
                </span>
              `}
              ${waitingUnavailable && html`
                <span class="kp-pill" data-tone="bad" title=${waitingUnavailable.reason ?? undefined}>
                  대기 목록 읽기 실패
                </span>
              `}
              <${PopoverMenu}
                triggerLabel=${metaTriggerLabel}
                triggerClassName=${metaTriggerClass}
                triggerTestId="keeper-meta-menu"
                popoverTestId="keeper-meta-popover"
                popoverClassName="kp-meta-popover"
                role="dialog"
                ariaLabel="Keeper 런타임 상태 세부정보"
                triggerTitle=${`Phase: ${keeper.phase} · Runtime: ${keeper.runtime_id}`}
              >
                <div class="kp-meta-row">
                  <span class="kp-meta-key">Phase</span>
                  <span class="kp-meta-val">${keeper.phase}</span>
                </div>
                <div class="kp-meta-row">
                  <span class="kp-meta-key">Runtime</span>
                  <span class="kp-meta-val">${keeper.runtime_id}</span>
                </div>
                <div class="kp-meta-row">
                  <span class="kp-meta-key">턴 상태</span>
                  <span class="kp-meta-val">${turnStatusLabel}</span>
                </div>
                ${approvalMode !== null && html`
                  <div class="kp-meta-row">
                    <span class="kp-meta-key">도구 승인</span>
                    <span class="kp-meta-val">
                      ${approvalMode === 'yolo' ? '⚠ YOLO (자동 통과)' : approvalMode}
                    </span>
                  </div>
                `}
              <//>
            </div>
          </div>
        </div>

        <div class="kp-lifecycle-bar" role="group" aria-label="Keeper 수명주기 제어">
          ${!booted && html`
            <button
              type="button"
              class="btn-primary"
              disabled=${busyAction !== null}
              onClick=${() => void runLifecycle('Boot', () => bootKeeperAction(keeper.name))}
            >
              Boot
            </button>
          `}
          ${booted && (isPaused
            ? html`
                <button
                  type="button"
                  class="btn-primary"
                  disabled=${busyAction !== null}
                  onClick=${() => void runLifecycle('Resume', () => resumeKeeperAction(keeper.name))}
                >
                  Resume
                </button>
              `
            : html`
                <button
                  type="button"
                  class="btn-ghost"
                  disabled=${busyAction !== null}
                  onClick=${() => void runLifecycle('Pause', () => pauseKeeperAction(keeper.name))}
                >
                  Pause
                </button>
              `)}
          ${keeper.active_turn !== null && html`
            <button
              type="button"
              class="btn-ghost"
              disabled=${busyAction !== null}
              onClick=${() => void runLifecycle('Interrupt Turn', () => interruptKeeperTurnAction(keeper.name))}
            >
              Interrupt Turn
            </button>
          `}
          <${PopoverMenu}
            align="right"
            triggerLabel="⋯"
            triggerClassName="btn-ghost"
            triggerTestId="keeper-actions-menu"
            popoverTestId="keeper-actions-popover"
            ariaLabel="Keeper 추가 작업"
            items=${overflowActionItems}
          />
        </div>
      </div>

      ${hasDiagnostics && html`
        <details
          class="kp-diag-banner"
          open=${hasBlockingFault || undefined}
          data-tone=${failing ? 'bad' : resting || Boolean(approvalModeRestoreError) ? 'warn' : 'info'}
          data-blocking=${hasBlockingFault ? 'true' : 'false'}
          role="status"
          aria-label="Keeper 런타임 진단"
        >
          <summary class="kp-diag-summary">
            <span class="kp-diag-summary-text">
              ${hasBlockingFault ? '런타임 진단' : '진단 이력'} · ${diagSummaryText}
            </span>
            <span class="kp-diag-chevron" aria-hidden="true">▸</span>
          </summary>
          <div class="kp-diag-body">
            ${keeper.directory_issue && html`
              <div class="kp-diag-row"><strong>설정 오류</strong>: ${keeper.directory_issue}</div>
            `}
            ${keeper.runtime_blocker_summary && html`
              <div class="kp-diag-row">
                <strong>차단 사유</strong>: ${keeper.runtime_blocker_summary}
                ${keeper.runtime_blocker_signature && html` <span class="kp-roster-sub">(${keeper.runtime_blocker_signature})</span>`}
                ${keeper.runtime_blocker_class && html` <span class="kp-roster-sub">[${keeper.runtime_blocker_class}]</span>`}
              </div>
            `}
            ${resting && keeper.runtime_path_rest && html`
              <div class="kp-diag-row">
                <strong>경로 휴식</strong>: ${keeper.runtime_path_rest.runtime_id ?? keeper.runtime_id}
                ${keeper.runtime_path_rest.release_at ? ` · 해제 ${keeper.runtime_path_rest.release_at}` : ''}
                ${keeper.runtime_path_rest.release_basis ? ` (${keeper.runtime_path_rest.release_basis})` : ''}
              </div>
            `}
            ${(keeper.last_failure || actionableDisposition || (keeper.next_action && (failing || resting || keeper.next_action !== 'direct_message'))) && html`
              <div class="kp-diag-row">
                ${keeper.last_failure ? `최근 실패: ${keeper.last_failure.cause}` : ''}
                ${actionableDisposition ? `${keeper.last_failure ? ' · ' : ''}조치: ${actionableDisposition}${keeper.operator_disposition_reason ? ` (${keeper.operator_disposition_reason})` : ''}` : ''}
                ${keeper.next_action && (failing || resting || keeper.next_action !== 'direct_message') ? `${keeper.last_failure || actionableDisposition ? ' · ' : ''}다음 단계: ${keeper.next_action}` : ''}
              </div>
            `}
            ${waitingSummary && waitingSummary.count > 0 && html`
              <div class="kp-diag-row">
                <strong>대기 항목</strong>: ${waitingSummary.count}건
                ${waitingSummary.due_at ? ` (가장 이른 예정 ${formatDueAt(waitingSummary.due_at)})` : ''}
                ${waitingSummary.heads.map((head) => html`
                  <div class="kp-diag-lane-meta" key=${`${head.source}:${head.next_action}`}>
                    <span>${head.what}</span>
                    <span>다음: ${head.next_action}</span>
                    ${head.due_at ? html`<span>예정 ${formatDueAt(head.due_at)}</span>` : null}
                  </div>
                `)}
              </div>
            `}
            ${waitingUnavailable && html`
              <div class="kp-diag-row">
                <strong>대기 항목</strong>: 대기 목록을 읽지 못했어요. 대기가 없다는 뜻이 아니에요.
                ${waitingUnavailable.reason ? ` · ${waitingUnavailable.reason}` : ''}
              </div>
            `}
            ${laneFailures.length > 0 && html`
              <div class="kp-diag-row">
                <strong>폴백 시도</strong>: ${laneFailures.map((f) => `${f.runtime_id ?? 'lane'}${f.fault_kind ? `[${f.fault_kind}]` : ''}: ${f.summary}`).join(' → ')}
                <div class="kp-diag-lane-detail">
                  ${laneFailures.map((f, idx) => html`
                    <div class="kp-diag-lane" key=${`${f.runtime_id ?? 'lane'}:${f.attempt ?? idx}:${f.summary}`}>
                      <span>${f.runtime_id ?? 'lane'}${f.dispatch ? ` · ${f.dispatch}` : ''}${f.attempt != null ? ` · attempt ${f.attempt}` : ''}${f.fault_kind ? ` · ${f.fault_kind}` : ''}</span>
                      ${f.summary ? html`<div>${f.summary}</div>` : null}
                      ${(f.failure_kind || f.failure_detail || f.provider || f.network_kind)
                        ? html`<div class="kp-diag-lane-meta">${f.failure_kind ? html`<span>kind:${f.failure_kind}</span>` : null}${f.provider ? html`<span>provider:${f.provider}</span>` : null}${f.network_kind ? html`<span>network:${f.network_kind}</span>` : null}${f.failure_detail ? html`<span>${f.failure_detail}</span>` : null}</div>`
                        : null}
                    </div>
                  `)}
                </div>
              </div>
            `}
            ${approvalModeRestoreError && html`
              <div class="kp-diag-row"><strong>승인 모드 복구 오류</strong>: ${approvalModeRestoreError}</div>
            `}
            ${turnBreakdown && (turnBreakdown.failed > 0 || turnBreakdown.rested > 0) && html`
              <div class="kp-diag-row">
                <strong>24h 턴 내역</strong>: 성공 ${turnBreakdown.ok} · 휴식 ${turnBreakdown.rested} · 실패 ${turnBreakdown.failed}
                <div class="kp-diag-lane-meta">시작 계기: 예약 ${turnBreakdown.causes.scheduled} · 반응 ${turnBreakdown.causes.reacted} · 채팅 ${turnBreakdown.causes.chat} · 스스로 ${turnBreakdown.causes.own} · 모름 ${turnBreakdown.causes.unknown}</div>
              </div>
            `}
          </div>
        </details>
      `}

      ${statusMessage && html`
        <div
          class=${statusMessage.tone === 'bad' ? 'ap-error' : 'kp-notice'}
          data-tone=${statusMessage.tone}
          role="status"
        >
          ${statusMessage.text}
        </div>
      `}

      <nav class="kp-tabs" role="tablist" aria-label="Keeper 상세 탭" data-mobile-only="true">
        ${KEEPER_ENTITY_TABS.map((tab) => html`
          <button
            key=${tab}
            type="button"
            role="tab"
            class="kp-tab"
            aria-selected=${props.activeTab === tab ? 'true' : 'false'}
            onClick=${() => props.onSelectTab(tab)}
          >
            ${KEEPER_ENTITY_TAB_LABELS[tab]}
          </button>
        `)}
      </nav>

      ${deleteOpen && html`
        <div
          ref=${deleteModalRef}
          class="kp-modal-backdrop"
          role="dialog"
          aria-modal="true"
          aria-label="Keeper 영구 삭제 확인"
          onClick=${(e: MouseEvent) => {
            if (e.target === e.currentTarget) closeDeleteModal()
          }}
        >
          <div class="kp-modal">
            <div class="kp-card-head">
              <h3>Keeper 영구 삭제: ${keeper.name}</h3>
              <button type="button" class="btn-ghost" onClick=${closeDeleteModal}>취소</button>
            </div>
            ${deleteError && html`<div class="ap-error" role="alert">${deleteError}</div>`}
            <p class="ov-sub">다음 아티팩트가 영구 제거됩니다:</p>
            <ul>
              ${PURGE_ARTIFACTS.map((item) => html`<li key=${item}>${item}</li>`)}
            </ul>
            <${TargetLockedAction}
              target=${{
                workspaceId: activeWorkspaceId.value,
                keeper: keeper.name,
                requestId: `purge:${keeper.name}`,
                revision: keeper.phase,
              }}
            >
              <input
                ref=${deleteInputRef}
                type="text"
                class="kp-input"
                placeholder=${`확인하려면 "${keeper.name}" 입력`}
                aria-label="삭제 확인 Keeper 이름"
                value=${deleteConfirmName}
                onInput=${(e: Event) => setDeleteConfirmName((e.currentTarget as HTMLInputElement).value)}
                onKeyDown=${(e: KeyboardEvent) => {
                  if (e.isComposing || e.keyCode === 229) return
                  if (e.key === 'Enter' && deleteConfirmName.trim() === keeper.name && busyAction === null) {
                    e.preventDefault()
                    void handleConfirmDelete()
                  }
                }}
              />
              <button
                type="button"
                class="kp-btn-danger"
                disabled=${deleteConfirmName.trim() !== keeper.name || busyAction !== null}
                onClick=${() => void handleConfirmDelete()}
              >
                영구 삭제 실행
              </button>
            <//>
          </div>
        </div>
      `}
    </header>
  `
}
