import { signal } from '@preact/signals'
import type { DashboardRoomTruthResponse } from './types'

export const roomTruth = signal<DashboardRoomTruthResponse | null>(null)
export const roomTruthLoading = signal(false)
export const roomTruthError = signal<string | null>(null)
export const roomTruthInitializing = signal(false)
