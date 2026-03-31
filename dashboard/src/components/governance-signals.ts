import { signal } from '@preact/signals'
import type {
  DashboardGovernanceResponse,
  GovernanceCaseBundle,
} from '../types'
import type { RuntimeParam, RuntimeParamsSurface, ParamAuditEntry } from '../api'
import type { GovernanceFilter } from './governance-utils'

export const governanceLoading = signal(false)
export const governanceStarting = signal(false)
export const governanceActing = signal(false)
export const governanceBriefSubmitting = signal(false)
export const governanceError = signal('')
export const governanceTopicInput = signal('')
export const governanceBriefInput = signal('')
export const governanceBriefStance = signal<'support' | 'oppose' | 'neutral'>('support')
export const governanceFilter = signal<GovernanceFilter>('open')
export const governanceData = signal<DashboardGovernanceResponse | null>(null)
export const selectedDecisionKey = signal<string | null>(null)
export const selectedCaseDetail = signal<GovernanceCaseBundle | null>(null)
export const detailLoading = signal(false)

export const runtimeParams = signal<RuntimeParam[]>([])
export const runtimeSurfaces = signal<RuntimeParamsSurface[]>([])
export const runtimeLoading = signal(false)
export const paramAuditEntries = signal<ParamAuditEntry[]>([])
export const paramAuditLoading = signal(false)
