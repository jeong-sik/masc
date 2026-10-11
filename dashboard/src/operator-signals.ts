import { computed, signal } from '@preact/signals'
import type {
  OperatorActionLogEntry,
  OperatorDigest,
  OperatorSnapshot,
} from './types'

export const operatorSnapshot = signal<OperatorSnapshot | null>(null)
export const operatorWorkspaceDigest = signal<OperatorDigest | null>(null)
export const operatorLoading = signal(false)
export const operatorError = signal<string | null>(null)
export const operatorErrorStatus = signal<number | null>(null)
export const operatorDigestLoading = signal(false)
export const operatorDigestError = signal<string | null>(null)
export const operatorDigestErrorStatus = signal<number | null>(null)
const pendingOperatorActions = signal<ReadonlySet<symbol>>(new Set())
export const operatorActionBusy = computed(() => pendingOperatorActions.value.size > 0)

export function acquireOperatorAction(): () => void {
  const id = Symbol('operator action')
  pendingOperatorActions.value = new Set([...pendingOperatorActions.value, id])
  return () => {
    if (!pendingOperatorActions.value.has(id)) return
    const remaining = new Set(pendingOperatorActions.value)
    remaining.delete(id)
    pendingOperatorActions.value = remaining
  }
}
export const operatorActionLog = signal<OperatorActionLogEntry[]>([])
