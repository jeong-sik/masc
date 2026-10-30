// Keeper Workspace — operator actions on one event-queue row (#29473 PR-2).
// The waiting-inventory row already carries the exact-entry address
// (`detail.source_ref` + `detail.source_incarnation`), so urgency, transfer and
// cancel act on the row the operator is looking at; no second queue read.
// Admission is decided by the caller: the pure strip renders these only when
// it receives an actions object, and `useLaneEventQueueActions` is mounted by
// the live section for an Admin session.

import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
import type { VNode } from 'preact'
import {
  KeeperEventQueueOperationError,
  operateKeeperEventQueue,
  parseKeeperEventQueueSourceAddress,
  type DashboardKeeperWaitingRow,
  type KeeperEventQueueOperatorAction,
  type KeeperEventQueueReplayableAction,
} from '../../api'
import { refreshKeeperWaitingInventory } from '../../keeper-waiting-inventory-store'
import { showToast } from '../common/toast'

const URGENCIES = ['immediate', 'normal', 'low'] as const

/** A cancel/transfer whose commit state the server could not confirm. The
 *  same operation id replays idempotently, so the operator can ask for the
 *  result instead of issuing a second, different mutation. */
export interface LaneEventRecovery {
  readonly operation: KeeperEventQueueReplayableAction
  readonly commitState: 'committed' | 'unknown'
  readonly message: string
}

export interface LaneEventQueueActions {
  /** Row key whose mutation is in flight; that row's buttons are disabled. */
  readonly pendingKey: string | null
  readonly recoveries: readonly LaneEventRecovery[]
  readonly error: string | null
  readonly operate: (key: string, operation: KeeperEventQueueOperatorAction) => Promise<void>
}

export function laneEventRowKey(sourceRef: string): string {
  return `event:${sourceRef}`
}

export function useLaneEventQueueActions(keeperName: string): LaneEventQueueActions {
  const [pendingKey, setPendingKey] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [recoveries, setRecoveries] = useState<readonly LaneEventRecovery[]>([])

  const operate = async (key: string, operation: KeeperEventQueueOperatorAction) => {
    setPendingKey(key)
    try {
      await operateKeeperEventQueue(keeperName, operation)
      if (operation.action !== 'reprioritize' && operation.operationId) {
        setRecoveries(current => current.filter(
          recovery => recovery.operation.operationId !== operation.operationId,
        ))
      }
      setError(null)
      await refreshKeeperWaitingInventory(keeperName)
    } catch (cause) {
      const message = cause instanceof Error ? cause.message : String(cause)
      if (cause instanceof KeeperEventQueueOperationError) {
        const recovery: LaneEventRecovery = {
          operation: cause.operation,
          commitState: cause.commitState,
          message,
        }
        setRecoveries(current => [
          ...current.filter(
            item => item.operation.operationId !== cause.operation.operationId,
          ),
          recovery,
        ])
      }
      await Promise.allSettled([refreshKeeperWaitingInventory(keeperName)])
      setError(message)
      showToast(message, 'error')
    } finally {
      setPendingKey(null)
    }
  }

  return { pendingKey, recoveries, error, operate }
}

/** Replay buttons for operations whose commit state is unconfirmed. */
export function LaneEventRecoveries({ actions }: { actions: LaneEventQueueActions }): VNode | null {
  if (actions.recoveries.length === 0 && actions.error == null) return null
  return html`
    <div class="grid gap-1.5" data-testid="keeper-lane-event-recoveries">
      ${actions.error == null
        ? null
        : html`<div class="rounded-[var(--r-0)] bg-[var(--danger-10)] p-2 text-2xs text-[var(--color-status-err)]" data-testid="keeper-lane-event-error">${actions.error}</div>`}
      ${actions.recoveries.map(recovery => {
        const operationId = recovery.operation.operationId
        const key = `event-recovery:${operationId}`
        return html`
          <div key=${key} class="grid gap-1 rounded-[var(--r-0)] border border-[var(--danger-20)] bg-[var(--danger-10)] p-2">
            <div class="text-2xs text-[var(--color-status-err)]">
              ${recovery.commitState === 'committed' ? 'source commit 완료 · 후속 확인 필요' : 'commit 결과 확인 필요'}
              · ${recovery.operation.action}
            </div>
            <div class="break-words text-3xs text-[var(--color-fg-secondary)]">${recovery.message}</div>
            <div class="break-all font-mono text-3xs text-[var(--color-fg-muted)]">${operationId}</div>
            <button
              type="button"
              disabled=${actions.pendingKey === key}
              class="w-fit rounded-[var(--r-0)] border border-[var(--danger-20)] px-2 py-1 text-2xs text-[var(--color-status-err)] disabled:opacity-50"
              onClick=${() => void actions.operate(key, recovery.operation)}
            >동일 작업 결과 확인</button>
          </div>
        `
      })}
    </div>
  `
}

/** Urgency / transfer / cancel for one `event_queue_pending` row. */
export function LaneEventRowActions({
  row,
  actions,
}: {
  row: DashboardKeeperWaitingRow
  actions: LaneEventQueueActions
}): VNode {
  const address = parseKeeperEventQueueSourceAddress(row.detail)
  if (address === null) {
    return html`<div class="text-3xs text-[var(--color-fg-muted)]" data-testid="keeper-lane-event-address-missing">항목 주소 미수신</div>`
  }
  const key = laneEventRowKey(address.sourceRef)
  const busy = actions.pendingKey === key
  return html`
    <div class="flex flex-wrap gap-1.5" data-testid="keeper-lane-event-actions">
      ${URGENCIES.map(urgency => html`
        <button
          key=${urgency}
          type="button"
          disabled=${busy}
          class="rounded-[var(--r-0)] border border-[var(--color-border-default)] px-2 py-1 text-2xs disabled:opacity-50"
          onClick=${() => void actions.operate(key, {
            action: 'reprioritize',
            sourceIncarnation: address.sourceIncarnation,
            sourceRef: address.sourceRef,
            urgency,
          })}
        >${urgency}</button>
      `)}
      <button
        type="button"
        disabled=${busy}
        class="rounded-[var(--r-0)] border border-[var(--color-border-default)] px-2 py-1 text-2xs disabled:opacity-50"
        onClick=${() => {
          const targetKeeper = window.prompt('이 이벤트를 넘길 Keeper 이름을 입력하세요.')
          if (targetKeeper === null) return
          void actions.operate(key, {
            action: 'transfer',
            sourceIncarnation: address.sourceIncarnation,
            sourceRef: address.sourceRef,
            targetKeeper,
          })
        }}
      >이관</button>
      <button
        type="button"
        disabled=${busy}
        class="rounded-[var(--r-0)] border border-[var(--danger-20)] bg-[var(--danger-10)] px-2 py-1 text-2xs text-[var(--color-status-err)] disabled:opacity-50"
        onClick=${() => {
          const reason = window.prompt('이벤트 취소 이유를 입력하세요.')
          if (reason === null) return
          void actions.operate(key, {
            action: 'cancel',
            sourceIncarnation: address.sourceIncarnation,
            sourceRef: address.sourceRef,
            reason,
          })
        }}
      >취소</button>
    </div>
  `
}
