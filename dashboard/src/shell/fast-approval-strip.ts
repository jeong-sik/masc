/**
 * Conditional 1-Row Fast-Path Approval Strip (`Proposal A+` + `code-reviewer-sister` K4).
 *
 * - Shows pending actions or incomplete Inbox reads and collapses after a confirmed empty read.
 * - Wraps every approve/deny mutation in `TargetLockedAction` displaying immutable
 *   `(workspace_id, keeper, request_id, revision)` and auto-locking on revision or epoch drift.
 * - Supports `[Y]` Approve, `[N]` Deny, `[J]` Jump to Inbox (`Alt+Y` / `Alt+N` while typing).
 * - Adapts cleanly to `<768px` mobile as a 1-line compact triage banner (`<=2` taps).
 */

import { html } from 'htm/preact'
import type { VNode } from 'preact'
import { useEffect, useState } from 'preact/hooks'
import { activeWorkspaceId, isAuthenticated, sessionEpoch } from '../core/auth'
import { TargetLockedAction, type TargetLockState } from '../components/primitives/target-locked-action'
import { navigate } from '../routes/router'
import {
  commandPaletteOpen,
  formatInboxPendingCount,
  inboxUncheckedSources,
  isMobileViewport,
  mobileMoreOpen,
  pendingApprovals,
  pendingAsks,
  pendingGateApprovals,
  pendingGoalConfirmations,
  refreshPendingHitl,
  submitFastToolApproval,
  toggleQueueContextOverlay,
  uncheckedHitlStatusLabel,
} from './shell-state'

function isEditableTarget(target: EventTarget | null): boolean {
  if (!(target instanceof HTMLElement)) return false
  const tag = target.tagName
  return tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || target.isContentEditable
}

export function FastApprovalStrip(): VNode | null {
  const approvals = pendingApprovals.value
  const asks = pendingAsks.value
  const gates = pendingGateApprovals.value
  const goalConfirms = pendingGoalConfirmations.value
  const inboxUnchecked = inboxUncheckedSources.value
  const mobile = isMobileViewport.value
  const [submittingId, setSubmittingId] = useState<string | null>(null)
  const [capturedEpoch, setCapturedEpoch] = useState<number>(() => sessionEpoch.peek())
  const [capturedApprovalId, setCapturedApprovalId] = useState<string | null>(null)

  const headApproval = approvals[0] ?? null
  const headAsk = asks[0] ?? null
  const headGate = gates[0] ?? null
  const headGoalConfirm = goalConfirms[0] ?? null

  useEffect(() => {
    if (headApproval && headApproval.approvalId !== capturedApprovalId) {
      setCapturedApprovalId(headApproval.approvalId)
      setCapturedEpoch(sessionEpoch.peek())
    }
  }, [headApproval?.approvalId, capturedApprovalId])

  useEffect(() => {
    if (!headApproval && !headAsk && !headGate && !headGoalConfirm) return
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.defaultPrevented || event.isComposing || event.keyCode === 229) return
      if (event.shiftKey || commandPaletteOpen.peek() || mobileMoreOpen.peek()) return
      if (typeof document !== 'undefined' && document.querySelector('[role="dialog"][aria-modal="true"]')) return
      if (event.metaKey || event.ctrlKey) return
      const key = event.key.toLowerCase()
      const typing = isEditableTarget(event.target)

      if (key === 'j' && !typing && !event.altKey) {
        event.preventDefault()
        navigate('/work/inbox')
        return
      }
      if (!headApproval) return
      const allowedWhileTyping = event.altKey && (key === 'y' || key === 'n')
      if (typing && !allowedWhileTyping) return
      if (!typing && event.altKey && key !== 'y' && key !== 'n') return

      // Respect TargetLockedAction epoch & workspace fence before firing keyboard action
      const epochLocked = sessionEpoch.peek() !== capturedEpoch
      const wsLocked = activeWorkspaceId.peek() !== headApproval.workspaceId
      if (epochLocked || wsLocked || submittingId === headApproval.approvalId) return

      if (key === 'y') {
        event.preventDefault()
        setSubmittingId(headApproval.approvalId)
        void submitFastToolApproval(headApproval, 'approve').finally(() => setSubmittingId(null))
      } else if (key === 'n') {
        event.preventDefault()
        setSubmittingId(headApproval.approvalId)
        void submitFastToolApproval(headApproval, 'deny').finally(() => setSubmittingId(null))
      }
    }
    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [headApproval, headAsk, headGate, headGoalConfirm, capturedEpoch, submittingId])

  const totalPending = approvals.length + asks.length + gates.length + goalConfirms.length
  const countTag = formatInboxPendingCount(totalPending, inboxUnchecked.length > 0)

  // 0px when genuinely clear with all inbox HITL sources observed.
  if (!headApproval && !headAsk && !headGate && !headGoalConfirm) {
    if (!isAuthenticated.value || inboxUnchecked.length === 0) return null
    const allUnbridged = inboxUnchecked.every((u) => u.state.kind === 'unbridged')
    const detailText = inboxUnchecked
      .map((source) => `${source.label}(${uncheckedHitlStatusLabel(source.state)})`)
      .join(' · ')
    return html`
      <section
        class=${`ap-fast-strip ap-fast-strip--ask${mobile ? ' is-mobile' : ''}`}
        role="status"
        aria-label="HITL 대기열 일부 미확인"
        data-testid="fast-approval-strip"
        data-hitl-unchecked="true"
      >
        <div class="ap-fast-row">
          <div class="ap-fast-summary">
            <span class="ap-fast-pill">HITL · ${countTag}</span>
            <span class="ap-fast-question">
              ${allUnbridged ? '멀티 계정 미지원 소스: ' : '미확인 소스: '}${detailText}
            </span>
          </div>
          <div class="ap-fast-actions">
            <button
              type="button"
              class="btn-ghost ap-fast-btn"
              onClick=${() => toggleQueueContextOverlay()}
            >
              Quick-Peek
            </button>
          </div>
        </div>
      </section>
    `
  }

  if (headApproval) {
    const busy = submittingId === headApproval.approvalId
    return html`
      <section
        class=${`ap-fast-strip${mobile ? ' is-mobile' : ''}`}
        role="region"
        aria-label="긴급 도구 승인 대기"
        data-testid="fast-approval-strip"
      >
        <${TargetLockedAction}
          className="ap-fast-tla"
          target=${{
            workspaceId: headApproval.workspaceId,
            keeper: headApproval.keeper,
            requestId: headApproval.approvalId,
            revision: headApproval.revision,
          }}
          currentRevision=${headApproval.revision}
          lockedEpoch=${capturedEpoch}
          onRefresh=${() => {
            setCapturedEpoch(sessionEpoch.peek())
            void refreshPendingHitl()
          }}
        >
          ${(lockState: TargetLockState) => html`
            <div class="ap-fast-row">
              <div class="ap-fast-summary">
                <span class="ap-fast-pill">APPROVAL · ${countTag}</span>
                <strong class="ap-fast-keeper">${headApproval.keeper}</strong>
                <code class="ap-fast-tool">${headApproval.tool || headApproval.toolCallId}</code>
                ${!mobile && headApproval.question && html`
                  <span class="ap-fast-question">${headApproval.question}</span>
                `}
              </div>
              <div class="ap-fast-actions">
                <button
                  type="button"
                  class="btn-primary ap-fast-btn"
                  disabled=${lockState.locked || busy}
                  onClick=${() => {
                    setSubmittingId(headApproval.approvalId)
                    void submitFastToolApproval(headApproval, 'approve').finally(() => setSubmittingId(null))
                  }}
                >
                  승인 <kbd class="ap-kbd">Y</kbd>
                </button>
                <button
                  type="button"
                  class="btn-ghost ap-fast-btn ap-fast-deny"
                  disabled=${lockState.locked || busy}
                  onClick=${() => {
                    setSubmittingId(headApproval.approvalId)
                    void submitFastToolApproval(headApproval, 'deny').finally(() => setSubmittingId(null))
                  }}
                >
                  거절 <kbd class="ap-kbd">N</kbd>
                </button>
                <button
                  type="button"
                  class="btn-ghost ap-fast-btn"
                  onClick=${() => navigate('/work/inbox')}
                >
                  Inbox <kbd class="ap-kbd">J</kbd>
                </button>
              </div>
            </div>
          `}
        <//>
      </section>
    `
  }

  if (headAsk) {
    return html`
      <section
        class=${`ap-fast-strip ap-fast-strip--ask${mobile ? ' is-mobile' : ''}`}
        role="region"
        aria-label="Keeper 질문 대기"
        data-testid="fast-approval-strip"
      >
        <div class="ap-fast-row">
          <div class="ap-fast-summary">
            <span class="ap-fast-pill">ASK · ${countTag}</span>
            <strong class="ap-fast-keeper">${headAsk.keeper}</strong>
            <span class="ap-fast-question">${headAsk.prompt}</span>
          </div>
          <div class="ap-fast-actions">
            <button
              type="button"
              class="btn-primary ap-fast-btn"
              onClick=${() => navigate('/work/inbox')}
            >
              답변하기 <kbd class="ap-kbd">J</kbd>
            </button>
          </div>
        </div>
      </section>
    `
  }

  if (headGate) {
    return html`
      <section
        class=${`ap-fast-strip${mobile ? ' is-mobile' : ''}`}
        role="region"
        aria-label="Channel Gate 승인 대기"
        data-testid="fast-approval-strip"
      >
        <div class="ap-fast-row">
          <div class="ap-fast-summary">
            <span class="ap-fast-pill">GATE · ${countTag}</span>
            <strong class="ap-fast-keeper">${headGate.keeper}</strong>
            <code class="ap-fast-tool">${headGate.toolName}</code>
          </div>
          <div class="ap-fast-actions">
            <button
              type="button"
              class="btn-primary ap-fast-btn"
              onClick=${() => navigate('/work/inbox')}
            >
              Inbox <kbd class="ap-kbd">J</kbd>
            </button>
          </div>
        </div>
      </section>
    `
  }

  return html`
    <section
      class=${`ap-fast-strip ap-fast-strip--ask${mobile ? ' is-mobile' : ''}`}
      role="region"
      aria-label="Goal 완료 확인 대기"
      data-testid="fast-approval-strip"
    >
      <div class="ap-fast-row">
        <div class="ap-fast-summary">
          <span class="ap-fast-pill">GOAL CONFIRM · ${countTag}</span>
          <strong class="ap-fast-keeper">${headGoalConfirm!.goalId}</strong>
          <span class="ap-fast-question">${headGoalConfirm!.title}</span>
        </div>
        <div class="ap-fast-actions">
          <button
            type="button"
            class="btn-primary ap-fast-btn"
            onClick=${() => navigate('/work/inbox')}
          >
            확정하기 <kbd class="ap-kbd">J</kbd>
          </button>
        </div>
      </div>
    </section>
  `
}
