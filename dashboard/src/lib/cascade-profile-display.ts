export interface CascadeProfileDisplay {
  label: string
  description: string
}

const DISPLAY: Record<string, CascadeProfileDisplay> = {
  default: {
    label: 'Single',
    description: '단일 Claude baseline. 문맥 일관성이 중요한 keeper용.',
  },
  keeper_unified: {
    label: 'Balanced',
    description: '기본 멀티-CLI 균형형. 대부분 keeper용.',
  },
  tool_use_strict: {
    label: 'Tool Required',
    description: '툴 호출 강제가 필요한 keeper용.',
  },
  resilient_breaker: {
    label: 'Resilient',
    description: '장애 격리와 backoff가 필요한 keeper용.',
  },
  local_only: {
    label: 'Local Fallback',
    description: '3-CLI가 모두 불가할 때만 쓰는 로컬 fallback.',
  },
  tool_rerank: {
    label: 'Tool Rerank',
    description: '짧은 rerank scoring 전용 system profile.',
  },
  governance_judge: {
    label: 'Governance Judge',
    description: 'Dashboard governance judge 전용 system profile.',
  },
  operator_judge: {
    label: 'Operator Judge',
    description: 'Operator judge 전용 system profile.',
  },
}

const fallbackDisplay = (name: string): CascadeProfileDisplay => ({
  label: name,
  description: 'Custom/internal cascade profile.',
})

export function cascadeProfileDisplay(name: string): CascadeProfileDisplay {
  return DISPLAY[name] ?? fallbackDisplay(name)
}

export function cascadeProfileLabel(name: string): string {
  return cascadeProfileDisplay(name).label
}

export function cascadeProfileDescription(name: string): string {
  return cascadeProfileDisplay(name).description
}

export function cascadeProfileOptionLabel(name: string): string {
  const display = cascadeProfileDisplay(name)
  return display.label === name ? name : `${display.label} (${name})`
}

export function cascadeProfileSearchText(name: string): string {
  const display = cascadeProfileDisplay(name)
  return `${name} ${display.label} ${display.description}`.toLowerCase()
}
