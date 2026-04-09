import { signal, computed } from '@preact/signals'
import type {
  DashboardGovernanceResponse,
  GovernanceCaseBundle,
} from '../types'
import type { RuntimeParam, RuntimeParamsSurface, ParamAuditEntry } from '../api'
import type { GovernanceFilter } from './governance-utils'
import { createAsyncResource, getData } from '../lib/async-state'

// ── Main governance resource ──
const governanceResource = createAsyncResource<DashboardGovernanceResponse>()
export { governanceResource }

export const governanceLoading = computed(() => governanceResource.state.value.status === 'loading')
export const governanceError = signal('')
export const governanceData = computed(() => getData(governanceResource.state.value) ?? null)

// ── Action-specific loading flags (not data-fetch trios) ──
export const governanceStarting = signal(false)
export const governanceActing = signal(false)
export const governanceBriefSubmitting = signal(false)
export const governanceApprovalActing = signal<string | null>(null)

// ── Form inputs ──
export const governanceTopicInput = signal('')
export const governanceBriefInput = signal('')
export const governanceBriefStance = signal<'support' | 'oppose' | 'neutral'>('support')
export const governanceFilter = signal<GovernanceFilter>('open')

// ── Decision detail ──
export const selectedDecisionKey = signal<string | null>(null)
export const selectedCaseDetail = signal<GovernanceCaseBundle | null>(null)
export const detailLoading = signal(false)

// ── Runtime params resource ──
const runtimeParamsResource = createAsyncResource<{ parameters: RuntimeParam[]; surfaces: RuntimeParamsSurface[] }>()
export { runtimeParamsResource }

export const runtimeParams = computed(() => getData(runtimeParamsResource.state.value)?.parameters ?? [])
export const runtimeSurfaces = computed(() => getData(runtimeParamsResource.state.value)?.surfaces ?? [])
export const runtimeLoading = computed(() => runtimeParamsResource.state.value.status === 'loading')

// ── Param audit resource ──
const paramAuditResource = createAsyncResource<ParamAuditEntry[]>()
export { paramAuditResource }

export const paramAuditEntries = computed(() => getData(paramAuditResource.state.value) ?? [])
export const paramAuditLoading = computed(() => paramAuditResource.state.value.status === 'loading')
