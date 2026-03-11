import { signal } from '@preact/signals'
import { fetchDashboardProof } from './api'
import type { DashboardProofResponse } from './types'

export const proofSnapshot = signal<DashboardProofResponse | null>(null)
export const proofLoading = signal(false)
export const proofError = signal<string | null>(null)

export async function refreshProofSnapshot(
  sessionId?: string | null,
  operationId?: string | null,
): Promise<void> {
  proofLoading.value = true
  proofError.value = null
  try {
    proofSnapshot.value = await fetchDashboardProof(sessionId, operationId)
  } catch (err) {
    proofError.value = err instanceof Error ? err.message : String(err)
  } finally {
    proofLoading.value = false
  }
}
