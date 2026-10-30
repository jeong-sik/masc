import { signal } from '@preact/signals'
import type { DashboardNamespaceTruthResponse } from './types'

export const namespaceTruth = signal<DashboardNamespaceTruthResponse | null>(null)
export const namespaceTruthLoading = signal(false)
export const namespaceTruthError = signal<string | null>(null)
export const namespaceTruthInitializing = signal(false)
