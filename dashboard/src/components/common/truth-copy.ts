export type TruthTone = 'ok' | 'warn' | 'bad'

function normalize(value?: string | null): string {
  return value?.trim().toLowerCase() ?? ''
}

export function provenanceLabel(value?: string | null): string {
  switch (normalize(value)) {
    case 'truth':
      return '확정 기준'
    case 'derived':
      return '계산된 요약'
    case 'fallback':
      return '보조 추정'
    case 'judgment':
      return '상주 판단'
    case 'recorded':
      return '기록 기반'
    case 'managed':
      return '관리형'
    case 'projected':
      return '투영 추정'
    default:
      return value?.trim() || '계산된 요약'
  }
}

export function provenanceTone(value?: string | null): TruthTone {
  switch (normalize(value)) {
    case 'truth':
    case 'judgment':
    case 'managed':
      return 'ok'
    case 'fallback':
      return 'bad'
    default:
      return 'warn'
  }
}

export function authoritativeLabel(value?: boolean | null): string {
  return value ? '상주 판단 사용 중' : '보조 판단'
}

export function guidanceLayerLabel(value?: string | null): string {
  switch (normalize(value)) {
    case 'judgment':
      return '상주 판단'
    case 'fallback':
      return '보조 읽기 모델'
    default:
      return value?.trim() || '안내'
  }
}

export function guidanceLayerTone(value?: string | null): TruthTone {
  switch (normalize(value)) {
    case 'judgment':
      return 'ok'
    case 'fallback':
      return 'warn'
    default:
      return 'warn'
  }
}

export function sourceOfTruthLabel(value?: string | null): string {
  switch (normalize(value)) {
    case 'truth':
      return '확정 기준'
    case 'derived':
      return '계산된 요약'
    case 'managed':
      return '관리형'
    case 'projected':
      return '투영 추정'
    case 'recorded':
      return '기록 기반'
    case 'fallback':
      return '보조 추정'
    default:
      return value?.trim() || '출처 확인 필요'
  }
}
