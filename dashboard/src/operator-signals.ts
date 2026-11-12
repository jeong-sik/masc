import { signal } from '@preact/signals'
import type {
  OperatorActionLogEntry,
  OperatorDigest,
} from './types'

export { operatorSnapshot } from './operator-snapshot-state'
export const operatorWorkspaceDigest = signal<OperatorDigest | null>(null)
export const operatorLoading = signal(false)
export const operatorError = signal<string | null>(null)
export const operatorErrorStatus = signal<number | null>(null)
export const operatorDigestLoading = signal(false)
export const operatorDigestError = signal<string | null>(null)
export const operatorDigestErrorStatus = signal<number | null>(null)
export const operatorActionBusy = signal(false)
export const operatorActionLog = signal<OperatorActionLogEntry[]>([])
