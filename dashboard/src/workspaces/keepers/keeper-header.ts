/**
 * Right Keeper Header Hero (48px portrait.png + Candle Brass 14% halo + lifecycle controls + 5 entity tabs).
 */

import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import { activeWorkspaceId } from '../../core/auth'
import { formatObserved, type Observed } from '../../core/resource-cache'
import { useAuthenticatedPortrait } from '../../lib/portrait-cache'
import { keeperPortraitUrl, kSigil } from '../../components/keeper-badge'
import { TargetLockedAction } from '../../components/primitives/target-locked-action'
import {
  bootKeeperAction,
  deleteKeeperAction,
  formatContextDetail,
  interruptKeeperTurnAction,
  isKeeperPathResting,
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
import type { KeeperRosterItem } from './types'

export interface KeeperHeaderProps {
  readonly keeper: KeeperRosterItem
  readonly turnStatus?: Observed<unknown>['kind']
  readonly activeTab: KeeperEntityTab
  readonly onSelectTab: (tab: KeeperEntityTab) => void
  readonly onLifecycleMutated: () => void
  readonly onDeleted: () => void
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
  const deleteInputRef = useRef<HTMLInputElement>(null)

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
        event.preventDefault()
        event.stopPropagation()
        closeDeleteModal()
      }
    }
    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [deleteOpen])

  const ctxObs = observeRosterContextPct(keeper)
  const ctxDetail = formatContextDetail(keeper)
  const ctxText = ctxObs.kind === 'value' ? ctxDetail.label : formatObserved(ctxObs, (v) => `${v}%`)
  const failing = needsRosterAttention(keeper)
  const booted = isKeeperBooted(keeper)
  const isPaused = keeper.paused || keeper.phase.trim().toLowerCase() === 'paused'
  const resting = isKeeperPathResting(keeper)
  const turnPreview = keeper.active_turn?.preview
  const turnDetail =
    (turnPreview
      ? [
          turnPreview.status_text || null,
          turnPreview.last_tool && !turnPreview.status_text.includes(turnPreview.last_tool) ? turnPreview.last_tool : null,
          turnPreview.text_tail && turnPreview.text_tail !== turnPreview.status_text ? turnPreview.text_tail : null,
        ]
          .filter((p): p is string => Boolean(p))
          .join(' · ') || null
      : null)
    ?? keeper.active_turn?.tool_in_flight
    ?? null
  const laneFailures = keeper.runtime_lane_failures ?? []
  const turnBreakdown = keeper.turns_24h_breakdown
  const actionableDisposition =
    keeper.operator_disposition && keeper.operator_disposition !== 'pass'
      ? keeper.operator_disposition
      : null
  const hasDiagnostics = Boolean(
    keeper.directory_issue
    || keeper.runtime_blocker_summary
    || resting
    || keeper.last_failure
    || actionableDisposition
    || laneFailures.length > 0
    || (keeper.waiting_summary && keeper.waiting_summary.count > 0)
    || (turnBreakdown && (turnBreakdown.failed > 0 || turnBreakdown.rested > 0)),
  )

  const runLifecycle = async (
    label: string,
    fn: () => Promise<{ ok: boolean; error?: { message: string } }>,
  ) => {
    setBusyAction(label)
    setStatusMessage(null)
    const res = await fn()
    setBusyAction(null)
    if (!res.ok) {
      setStatusMessage({ tone: 'bad', text: `${label} 실패: ${res.error?.message ?? '오류'}` })
      return
    }
    setStatusMessage({ tone: 'ok', text: `${label} 요청이 처리되었습니다.` })
    props.onLifecycleMutated()
  }

  const handleConfirmDelete = async () => {
    if (deleteConfirmName.trim() !== keeper.name) return
    setBusyAction('delete')
    setDeleteError(null)
    const res = await deleteKeeperAction(keeper.name)
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
              <span class="kp-pill" data-tone="info">${keeper.phase}</span>
              <span class="kp-pill">${keeper.runtime_id}</span>
              <span
                class="kp-pill"
                data-tone=${ctxObs.kind === 'value' && ctxObs.data >= 80 ? 'warn' : 'brass'}
                title=${ctxDetail.tooltip}
              >
                Ctx ${ctxText}
              </span>
              ${keeper.active_turn && html`
                <span class="kp-pill" data-tone="brass" title=${turnDetail ?? undefined}>
                  ● Turn (${keeper.active_turn.lane}${turnDetail ? ` · ${turnDetail}` : ''})
                </span>
              `}
              ${keeper.waiting_summary && keeper.waiting_summary.count > 0 && html`
                <span
                  class="kp-pill"
                  data-tone="warn"
                  title=${keeper.waiting_summary.primary_reason ?? undefined}
                >
                  대기 ${keeper.waiting_summary.count}${keeper.waiting_summary.primary_reason ? ` · ${keeper.waiting_summary.primary_reason}` : ''}
                </span>
              `}
              ${props.turnStatus === 'loading' && html`<span class="kp-pill">턴 상태 조회 중…</span>`}
              ${props.turnStatus === 'failed' && html`<span class="kp-pill" data-tone="warn">턴 상태 조회 실패</span>`}
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
          ${(booted || keeper.active_turn !== null) && html`
            <button
              type="button"
              class="btn-ghost"
              disabled=${busyAction !== null}
              onClick=${() => void runLifecycle('Interrupt Turn', () => interruptKeeperTurnAction(keeper.name))}
            >
              Interrupt Turn
            </button>
          `}
          <button
            type="button"
            class="kp-btn-danger"
            disabled=${busyAction !== null}
            onClick=${() => setDeleteOpen(true)}
          >
            Delete
          </button>
        </div>
      </div>

      ${hasDiagnostics && html`
        <div
          class="kp-diag-banner"
          data-tone=${failing ? 'bad' : resting ? 'warn' : 'info'}
          role="status"
          aria-label="Keeper 런타임 진단"
        >
          ${keeper.directory_issue && html`
            <div class="kp-diag-row"><strong>설정 오류</strong>: ${keeper.directory_issue}</div>
          `}
          ${keeper.runtime_blocker_summary && html`
            <div class="kp-diag-row">
              <strong>차단 사유</strong>: ${keeper.runtime_blocker_summary}
              ${keeper.runtime_blocker_signature && html` <span class="kp-roster-sub">(${keeper.runtime_blocker_signature})</span>`}
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
          ${keeper.waiting_summary && keeper.waiting_summary.count > 0 && html`
            <div class="kp-diag-row">
              <strong>대기 항목</strong>: ${keeper.waiting_summary.count}건
              ${keeper.waiting_summary.primary_reason ? ` · ${keeper.waiting_summary.primary_reason}` : ''}
              ${keeper.waiting_summary.due_at ? ` (예정 ${keeper.waiting_summary.due_at})` : ''}
            </div>
          `}
          ${laneFailures.length > 0 && html`
            <div class="kp-diag-row">
              <strong>폴백 시도</strong>: ${laneFailures.map((f) => `${f.runtime_id ?? 'lane'}${f.fault_kind ? `[${f.fault_kind}]` : ''}: ${f.summary}`).join(' → ')}
            </div>
          `}
          ${turnBreakdown && (turnBreakdown.failed > 0 || turnBreakdown.rested > 0) && html`
            <div class="kp-diag-row">
              <strong>24h 턴 내역</strong>: 성공 ${turnBreakdown.ok} · 휴식 ${turnBreakdown.rested} · 실패 ${turnBreakdown.failed}
            </div>
          `}
        </div>
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

      <nav class="kp-tabs" role="tablist" aria-label="Keeper 상세 탭">
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
