import { signal, computed } from '@preact/signals'
import type { DashboardGateResponse } from '../types'
import { createManagedAsyncResource } from '../lib/async-state'

// ── Main Gate resource ──
// Managed (stale-while-revalidate): a refetch keeps the previously loaded data
// visible while `loading` is true, instead of blanking to a dataless state.
// createAsyncResource cleared data on every load(), so each auto-refresh and
// each post-action refresh made gateData null mid-flight — the approvals
// queue (and the Gate surface) flashed its empty state every cycle.
export const gateResource = createManagedAsyncResource<DashboardGateResponse>()

export const gateLoading = computed(() => gateResource.state.value.loading)
export const gateError = signal('')
export const gateData = computed(() => gateResource.state.value.data)

// ── Action-specific loading flag (not a data-fetch trio) ──
export const gateApprovalActing = signal<string | null>(null)
