/**
 * Conditional 1-Row Fast-Path Approval Strip (`Proposal A+` + `code-reviewer-sister` K4).
 *
 * - Renders ONLY when pending Tool Approvals or Keeper Asks exist (`null` = 0px when clear).
 * - Wraps every approve/deny mutation in `TargetLockedAction` displaying immutable
 *   `(workspace_id, keeper, request_id, revision)` and auto-locking on revision or epoch drift.
 * - Supports `[Y]` Approve, `[N]` Deny, `[J]` Jump to Inbox (`Alt+Y` / `Alt+N` while typing).
 * - Adapts cleanly to `<768px` mobile as a 1-line compact triage banner (`<=2` taps).
 */

import { html } from 'htm/preact'
import type { VNode } from 'preact'
import { useEffect, useState } from 'preact/hooks'
import { activeWorkspaceId, sessionEpoch } from '../core/auth'
import { TargetLockedAction, type TargetLockState } from '../components/primitives/target-locked-action'
import { navigate } from '../routes/router'
import {
  commandPaletteOpen,
  isMobileViewport,
  mobileMoreOpen,
  pendingApprovals,
  pendingAsks,
  refreshPendingHitl,
  submitFastToolApproval,
} from './shell-state'

function isEditableTarget(target: EventTarget | null): boolean {
  if (!(target instanceof HTMLElement)) return false
  const tag = target.tagName
  return tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || target.isContentEditable
}

export function FastApprovalStrip(): VNode | null {
  const approvals = pendingApprovals.value
  const asks = pendingAsks.value
  const mobile = isMobileViewport.value
  const [submittingId, setSubmittingId] = useState<string | null>(null)
  const [capturedEpoch, setCapturedEpoch] = useState<number>(() => sessionEpoch.peek())
  const [capturedApprovalId, setCapturedApprovalId] = useState<string | null>(null)

  const headApproval = approvals[0] ?? null
  const headAsk = asks[0] ?? null

  useEffect(() => {
    if (headApproval && headApproval.approvalId !== capturedApprovalId) {
      setCapturedApprovalId(headApproval.approvalId)
      setCapturedEpoch(sessionEpoch.peek())
    }
  }, [headApproval?.approvalId, capturedApprovalId])

  useEffect(() => {
    if (!headApproval && !headAsk) return
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
  }, [headApproval, headAsk, capturedEpoch, submittingId])

  // 0px when clear!
  if (!headApproval && !headAsk) return null

  const totalPending = approvals.length + asks.length

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
                <span class="ap-fast-pill">APPROVAL · ${totalPending}</span>
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

  return html`
    <section
      class=${`ap-fast-strip ap-fast-strip--ask${mobile ? ' is-mobile' : ''}`}
      role="region"
      aria-label="Keeper 질문 대기"
      data-testid="fast-approval-strip"
    >
      <div class="ap-fast-row">
        <div class="ap-fast-summary">
          <span class="ap-fast-pill">ASK · ${asks.length}</span>
          <strong class="ap-fast-keeper">${headAsk!.keeper}</strong>
          <span class="ap-fast-question">${headAsk!.prompt}</span>
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
