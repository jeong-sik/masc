import { signal, computed } from '@preact/signals'
import type {
  DashboardGovernanceResponse,
  GovernanceCaseBundle,
} from '../types'
import type { GovernanceFilter } from './governance-utils'
import { createManagedAsyncResource } from '../lib/async-state'

// ── Main governance resource ──
// Managed (stale-while-revalidate): a refetch keeps the previously loaded data
// visible while `loading` is true, instead of blanking to a dataless state.
// createAsyncResource cleared data on every load(), so each auto-refresh and
// each post-action refresh made governanceData null mid-flight — the approvals
// queue (and the governance surface) flashed its empty state every cycle.
export const governanceResource = createManagedAsyncResource<DashboardGovernanceResponse>()

export const governanceLoading = computed(() => governanceResource.state.value.loading)
export const governanceError = signal('')
export const governanceData = computed(() => governanceResource.state.value.data)

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
