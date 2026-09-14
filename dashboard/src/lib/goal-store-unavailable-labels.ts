// Plain-words rendering of the RFC-0444 Goal store unavailable union. Every
// switch is exhaustive over the closed token lists in
// types/goal-store-unavailable.ts; render at the end of a path, never
// branch on the rendered text.

import type {
  GoalStoreMirror,
  GoalStoreResetStep,
  GoalStoreUnavailable,
  GoalStoreUnavailableReason,
} from '../types/goal-store-unavailable'

export const GOAL_STORE_UNAVAILABLE_TITLE = 'Goal store 를 읽을 수 없습니다'

export function goalStoreReasonLabel(reason: GoalStoreUnavailableReason, field: string | null): string {
  switch (reason) {
    case 'missing_after_init':
      return 'goals.json 이 초기화 뒤 사라졌습니다 (.last-good 미러만 남아 있음)'
    case 'unreadable':
      return '파일을 열거나 읽을 수 없습니다'
    case 'not_json':
      return '파일 내용이 JSON 이 아닙니다'
    case 'schema_rejected':
      return field === null
        ? '이 빌드의 goal 스키마가 파일을 거절했습니다'
        : `이 빌드의 goal 스키마가 파일을 거절했습니다 (필드: ${field})`
    default: {
      const unhandled: never = reason
      return unhandled
    }
  }
}

export function goalStoreMirrorLabel(mirror: GoalStoreMirror): string {
  switch (mirror.status) {
    case 'mirror_absent':
      return '.last-good 미러 없음'
    case 'mirror_unreadable':
      return '.last-good 미러를 읽을 수 없음'
    case 'mirror_decodes':
      return mirror.goalCount === null
        ? '.last-good 미러는 읽힘 (서빙하지 않음)'
        : `.last-good 미러는 읽힘 · goal ${mirror.goalCount}개 (서빙하지 않음)`
    case 'mirror_rejected':
      return '.last-good 미러도 거절됨'
    default: {
      const unhandled: never = mirror.status
      return unhandled
    }
  }
}

export function goalStoreResetStepLabel(resetStep: GoalStoreResetStep, field: string | null): string {
  switch (resetStep) {
    case 'repair_field':
      return field === null
        ? '거절된 필드를 채우면 다시 읽힙니다'
        : `필드 ${field} 를 채우면 다시 읽힙니다`
    case 'reset_goal_store':
      return 'masc goals reset --base-path <p> 로 goal store 를 리셋합니다 (파일은 옮기고 지우지 않음)'
    case 'restore_permission':
      return '파일 읽기 권한을 복구합니다'
    default: {
      const unhandled: never = resetStep
      return unhandled
    }
  }
}

/** One line for surfaces whose terminus is a string (toasts, badges, logs). */
export function goalStoreUnavailableSummary(unavailable: GoalStoreUnavailable): string {
  return [
    GOAL_STORE_UNAVAILABLE_TITLE,
    unavailable.file,
    goalStoreReasonLabel(unavailable.reason, unavailable.field),
    `다음 단계: ${goalStoreResetStepLabel(unavailable.resetStep, unavailable.field)}`,
  ].join(' · ')
}
