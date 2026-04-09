import type {
  DashboardProofActorContribution,
  DashboardProofSelection,
  DashboardProofTimelineItem,
  DashboardProofToolEvidence,
  DashboardProofWorkerRunEvidence,
  DashboardProofVerdict,
} from '../types'
import { asString, asNumber, isRecord } from './common/normalize'

export type DedupedTimelineItem = DashboardProofTimelineItem & {
  sources: string[]
}

export function verdictTone(verdict?: DashboardProofVerdict | null): string {
  if (verdict === 'proven') return 'ok'
  if (verdict === 'partial') return 'warn'
  return 'bad'
}

export function safeArray<T>(value: T[] | null | undefined): T[] {
  return Array.isArray(value) ? value : []
}

export function asRecord(value: unknown): Record<string, unknown> {
  return isRecord(value) ? value : {}
}

export function compactPath(path: string): string {
  const parts = path.split('/')
  return parts.length <= 3 ? path : `…/${parts.slice(-3).join('/')}`
}

export function verdictChipLabel(verdict: DashboardProofVerdict): string {
  if (verdict === 'proven') return '충분'
  if (verdict === 'partial') return '부분'
  return '부족'
}

export function verdictLabel(verdict: DashboardProofVerdict): string {
  if (verdict === 'proven') return '협업 증거가 충분합니다'
  if (verdict === 'partial') return '흔적은 있으나 협업 증거가 덜 모였습니다'
  return '증거가 부족합니다'
}

export function verdictReasonLines(
  verdict: DashboardProofVerdict,
  liveVerdict: DashboardProofVerdict,
  historicalVerdict: DashboardProofVerdict | null,
  actorCount: number,
  plannedActorCount: number,
  unansweredActorCount: number,
  interactionCount: number,
  evidenceCount: number,
  cpTraceCount: number,
): string[] {
  const lines = [
    `${actorCount}명이 실제 흔적을 남겼고, 계획된 참여자는 ${plannedActorCount}명입니다.`,
    interactionCount > 0
      ? `서로를 참조한 상호작용 증거가 ${interactionCount}건 있습니다.`
      : '서로를 참조한 명시적 상호작용 증거가 아직 없습니다.',
    evidenceCount > 0
      ? `도구·산출물·체크포인트 증거가 ${evidenceCount}건 있습니다.`
      : '도구·산출물·체크포인트 증거가 거의 없습니다.',
    cpTraceCount > 0
      ? `CPv2 backing trace가 ${cpTraceCount}건 있어 실행 흔적은 남아 있습니다.`
      : '관리형 backing trace는 아직 없습니다.',
  ]
  if (historicalVerdict === 'proven' && liveVerdict === 'insufficient') {
    return [
      lines[0] ?? '',
      '왜 이렇게 판정됐나: 과거 proof는 proved였지만, 현재 보이는 live evidence는 부족해서 partial로 완화했습니다.',
      '다음 보강 포인트: 최근 응답 턴이나 도구 호출을 다시 남겨 historical proof를 현재 상태와 연결해야 합니다.',
    ]
  }
  if (historicalVerdict === 'proven' && liveVerdict === 'partial') {
    return [
      lines[0] ?? '',
      '왜 이렇게 판정됐나: historical proof는 강하지만, 현재 live evidence는 아직 partial 수준입니다.',
      '다음 보강 포인트: 최근 상호작용과 실행 근거를 더 남기면 proven으로 회복할 수 있습니다.',
    ]
  }
  if (verdict === 'partial') {
    return [
      lines[0] ?? '',
      unansweredActorCount > 0
        ? `partial인 이유: 호출되었지만 응답하지 않은 참여자가 ${unansweredActorCount}명 있습니다.`
        : interactionCount === 0
          ? 'partial인 이유: 여러 흔적은 있지만 actor 간 상호작용이 직접 보이지 않습니다.'
          : 'partial인 이유: 일부 증거는 있으나 proven 기준을 모두 채우지 못했습니다.',
      cpTraceCount > 0
        ? '다음 보강 포인트: 응답 턴이나 도구 호출을 남기면 proof가 협업 수준으로 올라갑니다.'
        : '다음 보강 포인트: 관리형 trace 또는 산출물 연결을 더 남기면 근거가 강해집니다.',
    ]
  }
  if (verdict === 'proven') {
    return [
      lines[0] ?? '',
      '결론: 참여, 상호작용, 산출물, backing evidence가 모두 연결돼 있습니다.',
      '다음 행동: raw evidence는 접어두고 결과 산출물과 다음 실행 결정만 확인하면 됩니다.',
    ]
  }
  return [
    lines[0] ?? '',
    unansweredActorCount > 0
      ? `결론: 협업 시도는 있었지만 무응답 참여자가 ${unansweredActorCount}명 있어 협업 증거로 인정하기 어렵습니다.`
      : '결론: 기록은 있으나 협업을 증명할 만큼의 연결 증거가 부족합니다.',
    evidenceCount > 0
      ? '다음 보강 포인트: 응답 턴과 도구 근거를 서로 연결해 남겨야 합니다.'
      : '다음 보강 포인트: 참여자 간 턴, 도구 근거, 산출물 연결을 더 남겨야 합니다.',
  ]
}

export function verdictBasisLabel(basis?: string | null): string {
  if (basis === 'historical_only') return '과거 기록만'
  if (basis === 'live_and_historical') return '실시간 + 과거'
  return '실시간'
}

export function selectionTone(selection?: DashboardProofSelection | null): string {
  if (selection?.mode === 'requested_not_found') return 'bad'
  if (selection?.mode === 'latest_auto_selected') return 'warn'
  return 'ok'
}

export function selectionLabel(selection?: DashboardProofSelection | null): string {
  if (selection?.mode === 'requested_not_found') return '선택 실패'
  if (selection?.mode === 'latest_auto_selected') return '자동 선택'
  if (selection?.mode === 'explicit') return '명시 선택'
  return '선택 없음'
}

export function actorActivityTone(item: DashboardProofActorContribution): string {
  if (item.activity_state === 'acted') {
    return (item.interaction_count ?? 0) > 0 || (item.tool_evidence_count ?? 0) > 0 ? 'ok' : 'warn'
  }
  if (item.activity_state === 'mentioned_only') return 'warn'
  return 'muted'
}

export function actorActivityLabel(item: DashboardProofActorContribution): string {
  if (item.activity_state === 'acted') return '실제 흔적'
  if (item.activity_state === 'mentioned_only') return '호출만 됨'
  return '계획만 됨'
}

export function actorActivityMeta(item: DashboardProofActorContribution): string {
  if (item.activity_state === 'acted') {
    return `턴 ${item.turn_count ?? 0} · spawn ${item.spawn_count ?? 0} · 도구 근거 ${item.tool_evidence_count ?? 0}`
  }
  if (item.activity_state === 'mentioned_only') {
    const caller = item.requested_by ? `호출자 ${item.requested_by}` : '호출자 미상'
    return `호출 ${item.mention_count ?? 0}회 · ${caller}`
  }
  return '계획된 참여자이지만 아직 이벤트가 없습니다.'
}

export function toolEvidenceTags(item: DashboardProofToolEvidence): string[] {
  return Array.isArray(item.tool_names) ? item.tool_names : []
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

export function dedupeTimeline(items: DashboardProofTimelineItem[]): DedupedTimelineItem[] {
  const map = new Map<string, DedupedTimelineItem>()
  for (const item of items) {
    const key = [
      item.timestamp ?? '',
      item.event_type ?? '',
      item.actor ?? '',
      item.summary ?? '',
    ].join('|')
    const source = item.source ?? 'unknown'
    const existing = map.get(key)
    if (existing) {
      if (!existing.sources.includes(source)) existing.sources.push(source)
      if (!existing.operation_id && item.operation_id) existing.operation_id = item.operation_id
      continue
    }
    map.set(key, {
      ...item,
      sources: [source],
    })
  }
  return [...map.values()]
}

export function timelineMetaLabel(item: DedupedTimelineItem): string {
  if (item.sources.length === 2) return '세션 + 관제'
  if (item.sources.length === 1) return item.sources[0] === 'unknown' ? '출처 미상' : item.sources[0] ?? '출처'
  return item.sources.join(' + ')
}

export function keyValueRows(data: Record<string, unknown>): Array<{ label: string; value: string }> {
  const rows: Array<{ label: string; value: string }> = []
  for (const [key, raw] of Object.entries(data)) {
    if (raw == null) continue
    if (typeof raw === 'string') {
      if (raw.trim() === '') continue
      rows.push({ label: key, value: raw })
      continue
    }
    if (typeof raw === 'number' || typeof raw === 'boolean') {
      rows.push({ label: key, value: String(raw) })
      continue
    }
  }
  return rows
}

export function extractBackingSummary(cpEvidence: unknown): Array<{ label: string; value: string }> {
  const root = asRecord(cpEvidence)
  const traces = asRecord(root.traces)
  const traceEvents = Array.isArray(traces.events) ? traces.events : []
  const detachments = asRecord(root.detachments)
  const detachmentsList = Array.isArray(detachments.detachments) ? detachments.detachments : []
  const firstDetachment = asRecord(detachmentsList[0])
  const detachmentRecord = asRecord(firstDetachment.detachment)
  const operationRecord = asRecord(firstDetachment.operation)
  const summary = asRecord(root.summary)
  const summaryOperations = asRecord(summary.operations)
  const operationsSummary = asRecord(summaryOperations.summary)

  return [
    { label: '작전', value: asString(root.operation_id) ?? '없음' },
    { label: '분견대', value: asString(root.detachment_id) ?? '없음' },
    { label: '트레이스 이벤트', value: `${traceEvents.length}` },
    { label: '분견대 상태', value: asString(detachmentRecord.status) ?? '없음' },
    { label: '작전 단계', value: asString(operationRecord.stage) ?? '없음' },
    { label: '활성 작전', value: `${asNumber(operationsSummary.active) ?? 0}` },
  ]
}
