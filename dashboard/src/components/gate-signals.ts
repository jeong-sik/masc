import { signal, computed } from '@preact/signals'
import type {
  DashboardGateResponse,
  KeeperApprovalAuditFailureNotice,
  KeeperApprovalAuditReceipt,
} from '../types'
import { createManagedAsyncResource } from '../lib/async-state'
import { gateObservationErrorState } from '../lib/gate-observation-state'

// ── Main Gate resource ──
// Managed (stale-while-revalidate): a refetch keeps the previously loaded data
// visible while `loading` is true, instead of blanking to a dataless state.
// createAsyncResource cleared data on every load(), so each auto-refresh and
// each post-action refresh made gateData null mid-flight — the approvals
// queue (and the Gate surface) flashed its empty state every cycle.
export const gateResource = createManagedAsyncResource<DashboardGateResponse>()

export function gateObservationErrorSnapshot(operatorDetail: string): DashboardGateResponse {
  return {
    approval_queue: null,
    approval_queue_state: gateObservationErrorState(operatorDetail),
    recent_resolved: null,
    recent_resolved_page: null,
    recent_resolved_state: {
      state: 'unavailable',
      stage: 'list_recent_resolved',
      error: operatorDetail,
    },
    approval_rules: [],
    approval_rules_state: { state: 'unavailable', error: operatorDetail },
    keeper_modes: [],
    keeper_modes_state: { state: 'unavailable', error: operatorDetail },
    keeper_exact_lanes: [],
    keeper_exact_lanes_state: { state: 'unavailable', error: operatorDetail },
    hitl: null,
  }
}

export const gateLoading = computed(() => gateResource.state.value.loading)
export const gateError = signal('')
export const gateData = computed(() => gateResource.state.value.data)

export const gateAuditWriteFailures = signal<KeeperApprovalAuditFailureNotice[]>([])

export function observeGateAuditReceipts(
  receipts: KeeperApprovalAuditReceipt[],
  context: { id: string | null; transport: 'http' | 'sse' },
): void {
  const observedAt = new Date().toISOString()
  let notices = gateAuditWriteFailures.value
  for (const receipt of receipts) {
    if (receipt.recorded) continue
    const duplicate = context.id !== null && notices.some(notice =>
      notice.id === context.id
      && notice.receipt.event === receipt.event
      && notice.receipt.stage === receipt.stage
      && notice.receipt.detail === receipt.detail)
    if (!duplicate) {
      notices = [
        { ...context, observed_at: observedAt, receipt },
        ...notices,
      ].slice(0, 20)
    }
  }
  gateAuditWriteFailures.value = notices
}

export function clearGateAuditWriteFailures(): void {
  gateAuditWriteFailures.value = []
}

// ── Action-specific loading flag (not a data-fetch trio) ──
export const gateApprovalActing = signal<string | null>(null)
