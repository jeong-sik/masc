import type { KeeperContextMetricsUnavailable, KeeperContextNotObservedReason } from '../types'

interface ContextObservationMessage {
  severity: 'info' | 'warning' | 'error'
  label: string
  detail: string
}

const MESSAGES: Record<KeeperContextNotObservedReason, ContextObservationMessage> = {
  context_measurement_missing: {
    severity: 'info', label: '완료 요청의 측정 기록 없음',
    detail: '컨텍스트 점유율을 계산할 완료 요청 기록이 아직 없습니다.',
  },
  turn_record_undecodable: {
    severity: 'error', label: '컨텍스트 기록 형식 오류',
    detail: '최신 요청 기록을 해석하지 못했습니다. 기록 진단을 확인하세요.',
  },
  turn_record_read_failed: {
    severity: 'error', label: '컨텍스트 기록 읽기 실패',
    detail: '최신 요청 기록을 읽지 못했습니다. 저장소 진단을 확인하세요.',
  },
  turn_record_without_usage: {
    severity: 'info', label: '완료 요청의 사용량 보고 없음',
    detail: '제공자가 입력 토큰 사용량을 보고하지 않아 점유율을 계산하지 않습니다.',
  },
  turn_record_trace_mismatch: {
    severity: 'info', label: '현재 실행의 측정 기록 없음',
    detail: '이전 실행의 기록을 현재 실행의 점유율로 사용하지 않습니다.',
  },
  conversation_cumulative_usage: {
    severity: 'info', label: '대화 누적 사용량만 관측됨',
    detail: '누적 토큰 수는 한 요청의 컨텍스트 점유율이 아닙니다.',
  },
  turn_total_usage: {
    severity: 'info', label: '턴 합산 사용량만 관측됨',
    detail: '턴 전체의 합산 토큰 수는 한 요청의 컨텍스트 점유율이 아닙니다.',
  },
  usage_scope_unavailable: {
    severity: 'info', label: '사용량의 집계 범위 미확인',
    detail: '기록된 사용량의 집계 범위를 알 수 없어 점유율을 계산하지 않습니다.',
  },
  context_tokens_exceed_window: {
    severity: 'warning', label: '보고된 입력 토큰이 창 크기를 초과함',
    detail: '보고된 토큰 수와 창 크기를 확인하세요. 점유율은 보정하거나 추정하지 않습니다.',
  },
}

export function contextObservationMessage(value: KeeperContextMetricsUnavailable): ContextObservationMessage {
  if (value.kind === 'invalid_payload') {
    return {
      severity: 'error', label: '컨텍스트 진단 형식 오류',
      detail: `kind: ${value.reported_kind ?? '없음'} · reason: ${value.reported_reason ?? '없음'}`,
    }
  }
  const message = MESSAGES[value.reason]
  if ('usage_scope' in value && (value.raw_input_tokens !== null || value.context_window !== null)) {
    return {
      ...message,
      detail: `${message.detail} 보고된 입력: ${value.raw_input_tokens ?? '미보고'} · 창 크기: ${value.context_window ?? '미보고'}`,
    }
  }
  return message
}
