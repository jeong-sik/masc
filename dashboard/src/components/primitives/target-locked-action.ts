/**
 * Target-Locked HITL Safety Action Wrapper (`code-reviewer-sister` K4).
 *
 * - Always renders the 4 immutable target identity fields:
 *   `(workspace_id, keeper, request_id, revision)`.
 * - Automatically locks (`data-locked="true"`, disables all nested controls) whenever:
 *   1. `currentRevision !== lockedRevision` (target changed on server / CAS drift), OR
 *   2. `sessionEpoch.value !== lockedEpoch` (Account or Workspace switched), OR
 *   3. `currentWorkspaceId !== workspaceId` (active workspace diverged).
 */

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { useRef } from 'preact/hooks'
import { activeWorkspaceId, sessionEpoch } from '../../core/auth'

export interface TargetIdentity {
  readonly workspaceId: string
  readonly keeper: string
  readonly requestId: string
  readonly revision: string | number
}

export interface TargetLockState {
  readonly locked: boolean
  readonly reason: string | null
  readonly lockedEpoch: number
}

export interface TargetLockedActionProps {
  readonly target: TargetIdentity
  /** Latest known revision for this target; defaults to `target.revision`. */
  readonly currentRevision?: string | number
  /** Explicit epoch bound to this confirmation view; captured on first render if omitted. */
  readonly lockedEpoch?: number
  /** Optional refresh callback offered when locked due to drift. */
  readonly onRefresh?: () => void
  readonly children: ComponentChildren | ((state: TargetLockState) => ComponentChildren)
  readonly className?: string
}

export function evaluateTargetLock(params: {
  readonly target: TargetIdentity
  readonly currentRevision: string | number
  readonly lockedEpoch: number
  readonly currentEpoch: number
  readonly currentWorkspaceId: string
}): TargetLockState {
  if (params.currentEpoch !== params.lockedEpoch) {
    return {
      locked: true,
      reason: `세션 또는 워크스페이스가 변경되었습니다 (epoch ${params.lockedEpoch} → ${params.currentEpoch}). 대상을 다시 확인하세요.`,
      lockedEpoch: params.lockedEpoch,
    }
  }
  if (params.currentWorkspaceId !== params.target.workspaceId) {
    return {
      locked: true,
      reason: `활성 워크스페이스(${params.currentWorkspaceId})가 대상(${params.target.workspaceId})과 일치하지 않습니다.`,
      lockedEpoch: params.lockedEpoch,
    }
  }
  if (String(params.currentRevision) !== String(params.target.revision)) {
    return {
      locked: true,
      reason: `대상 리비전이 변경되었습니다 (rev ${params.target.revision} → ${params.currentRevision}). 새로고침 후 다시 승인하세요.`,
      lockedEpoch: params.lockedEpoch,
    }
  }
  return { locked: false, reason: null, lockedEpoch: params.lockedEpoch }
}

export function TargetLockedAction(props: TargetLockedActionProps) {
  const identityKey = `${props.target.workspaceId}:${props.target.requestId}`
  const lastIdentityRef = useRef<string | null>(null)
  const capturedEpochRef = useRef<number | null>(null)
  if (lastIdentityRef.current !== identityKey || capturedEpochRef.current === null) {
    lastIdentityRef.current = identityKey
    capturedEpochRef.current = props.lockedEpoch ?? sessionEpoch.peek()
  }
  const lockedEpoch = props.lockedEpoch ?? capturedEpochRef.current
  const currentEpoch = sessionEpoch.value
  const currentWs = activeWorkspaceId.value
  const currentRev = props.currentRevision ?? props.target.revision

  const lockState = evaluateTargetLock({
    target: props.target,
    currentRevision: currentRev,
    lockedEpoch,
    currentEpoch,
    currentWorkspaceId: currentWs,
  })

  const renderedChildren = typeof props.children === 'function'
    ? props.children(lockState)
    : props.children

  return html`
    <div
      class=${`tla ${props.className ?? ''}`.trim()}
      data-locked=${lockState.locked ? 'true' : 'false'}
      data-workspace-id=${props.target.workspaceId}
      data-request-id=${props.target.requestId}
    >
      <dl class="tla-meta" aria-label="대상 식별 정보">
        <span class="tla-kv">
          <dt class="tla-k">workspace_id:</dt>
          <dd>${props.target.workspaceId}</dd>
        </span>
        <span class="tla-kv">
          <dt class="tla-k">keeper:</dt>
          <dd>${props.target.keeper}</dd>
        </span>
        <span class="tla-kv">
          <dt class="tla-k">request_id:</dt>
          <dd>${props.target.requestId}</dd>
        </span>
        <span class="tla-kv">
          <dt class="tla-k">revision:</dt>
          <dd>${String(props.target.revision)}</dd>
        </span>
      </dl>

      ${lockState.locked && html`
        <div class="tla-lock-banner" role="alert">
          <span>${lockState.reason}</span>
          ${props.onRefresh && html`
            <button type="button" class="btn-ghost" onClick=${props.onRefresh}>
              대상 새로고침
            </button>
          `}
        </div>
      `}

      <fieldset class="tla-actions" disabled=${lockState.locked}>
        ${renderedChildren}
      </fieldset>
    </div>
  `
}
