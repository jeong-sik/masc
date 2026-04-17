import type {
  DashboardProofVerdict,
  DashboardProofWorkerRunEvidence,
} from '../types'

export function verdictTone(verdict?: DashboardProofVerdict | null): string {
  if (verdict === 'proven') return 'ok'
  if (verdict === 'partial') return 'warn'
  return 'bad'
}

export function workerRunEvidenceTone(item: DashboardProofWorkerRunEvidence): string {
  if (item.trace_validated === true) return 'ok'
  if (item.success === false || item.failure_reason || item.error) return 'bad'
  if (item.trace_capability === 'raw') return 'warn'
  if (item.trace_capability === 'summary_only') return 'warn'
  return 'warn'
}

export function workerRunEvidenceLabel(item: DashboardProofWorkerRunEvidence): string {
  if (item.trace_validated === true) return '검증됨'
  if (item.success === false || item.failure_reason || item.error) return '실패'
  if (item.trace_capability === 'raw') return 'raw observed'
  if (item.trace_capability === 'summary_only') return 'summary only'
  return item.status ?? '근거 수집'
}

export function workerRunEvidenceMeta(item: DashboardProofWorkerRunEvidence): string {
  const toolSurfaceCount =
    typeof item.tool_surface_count === 'number'
      ? item.tool_surface_count
      : Array.isArray(item.tool_surface_names)
        ? item.tool_surface_names.length
        : null
  const parts = [
    item.resolved_runtime ?? null,
    item.resolved_model ?? null,
    item.mode ?? null,
    item.proof_present ? (item.proof_status ?? 'proof') : null,
    item.tool_surface_status === 'missing'
      ? 'surface missing'
      : typeof toolSurfaceCount === 'number'
        ? `surface ${toolSurfaceCount}`
        : null,
    typeof item.tool_call_count === 'number' ? `도구 ${item.tool_call_count}` : null,
    typeof item.record_count === 'number' ? `레코드 ${item.record_count}` : null,
  ].filter((value): value is string => Boolean(value))
  return parts.join(' · ')
}

export function workerRunEvidencePreview(item: DashboardProofWorkerRunEvidence): string | null {
  return item.final_text
    ?? item.output_preview
    ?? item.error
    ?? item.failure_reason
    ?? item.stop_reason
    ?? null
}
