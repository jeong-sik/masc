import { signal } from '@preact/signals'
import type {
  OperatorActionLogEntry,
  OperatorDigest,
  OperatorSnapshot,
} from './types'

export const operatorSnapshot = signal<OperatorSnapshot | null>(null)
export const operatorRoomDigest = signal<OperatorDigest | null>(null)
export const operatorLoading = signal(false)
export const operatorError = signal<string | null>(null)
export const operatorErrorStatus = signal<number | null>(null)
export const operatorDigestLoading = signal(false)
export const operatorDigestError = signal<string | null>(null)
export const operatorDigestErrorStatus = signal<number | null>(null)
export const operatorActionBusy = signal(false)
export const operatorActionLog = signal<OperatorActionLogEntry[]>([])
