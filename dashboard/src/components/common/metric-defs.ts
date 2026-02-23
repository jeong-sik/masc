export type MetricKey =
  | 'born_at'
  | 'generation'
  | 'status'
  | 'recent_activity'
  | 'relations'
  | 'personality_change'

export interface MetricDefinition {
  label: string
  description: string
  sourcePath: string
  formula?: string
  interpretation?: string
}

export const CORE_METRIC_KEYS: MetricKey[] = [
  'born_at',
  'generation',
  'status',
  'relations',
  'recent_activity',
  'personality_change',
]

export const METRIC_DEFS: Record<MetricKey, MetricDefinition> = {
  born_at: {
    label: 'Born',
    description: 'Keeper 메타가 생성된 시각입니다.',
    sourcePath: 'keepers[].created_at',
    interpretation: '최근 생성일수록 신규 Keeper입니다.',
  },
  generation: {
    label: 'Generation',
    description: '승계/핸드오프를 거치며 누적된 세대 번호입니다.',
    sourcePath: 'keepers[].generation',
    interpretation: '값이 높을수록 세대 전환을 더 많이 경험했습니다.',
  },
  status: {
    label: 'Status',
    description: '현재 실행 상태입니다.',
    sourcePath: 'keepers[].status',
    interpretation: 'active/idle은 동작 중, offline/inactive는 비활성 상태입니다.',
  },
  recent_activity: {
    label: 'Recent',
    description: '가장 최근 변화/행동 요약입니다.',
    sourcePath: 'keepers[].last_drift_reason | keepers[].last_proactive_reason | keepers[].memory_recent_note',
    formula: 'first_non_null(last_drift_reason, last_proactive_reason, memory_recent_note)',
    interpretation: '최근 어떤 일을 했는지 한 줄로 파악합니다.',
  },
  relations: {
    label: 'Relations',
    description: '다른 Keeper와의 최근 상호작용 빈도입니다.',
    sourcePath: 'keepers[].k2k_count, keepers[].k2k_mentions',
    formula: 'k2k_count + top(k2k_mentions)',
    interpretation: '값이 높을수록 협업/호출이 잦습니다.',
  },
  personality_change: {
    label: 'Personality Change',
    description: '성향 변화 추세를 드리프트 지표로 요약한 값입니다.',
    sourcePath: 'keepers[].drift_count_total, keepers[].metrics_window.goal_drift_avg',
    formula: 'drift_count_total + goal_drift_avg',
    interpretation: '높을수록 최근 성향/목표 정렬 변화가 컸습니다.',
  },
}

export function getMetricDef(metric: MetricKey): MetricDefinition {
  return METRIC_DEFS[metric]
}
