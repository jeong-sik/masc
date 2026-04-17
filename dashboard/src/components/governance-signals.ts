import { signal, computed } from '@preact/signals'
import type {
  DashboardGovernanceResponse,
  GovernanceCaseBundle,
} from '../types'
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
