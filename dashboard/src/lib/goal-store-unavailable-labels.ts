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

// Older servers may send an arbitrary member name directly. Keep invisible
// characters and terminal controls distinguishable from an empty location.
function goalStoreLocationLabel(field: string): string {
  if (field === '') return '이름이 빈 필드 · 정확한 위치 미확인'
  if (field === '$') return '문서 최상위 또는 이름이 $인 필드'
  const chars = Array.from(field)
  const simple = chars.every(char => {
    const code = char.codePointAt(0)!
    return code >= 0x21 && code <= 0x7e && char !== '"' && char !== '\\'
  })
  if (simple) return field
  return `"${chars.map(char => {
    const code = char.codePointAt(0)!
    return code >= 0x21 && code <= 0x7e && char !== '"' && char !== '\\'
      ? char : `\\u{${code.toString(16)}}`
  }).join('')}"`
}

export function goalStoreReasonLabel(reason: GoalStoreUnavailableReason, field: string | null): string {
  switch (reason) {
    case 'missing_after_init':
      return 'goals.json을 찾지 못했습니다. 마지막 저장본의 상태를 확인하세요'
    case 'unreadable':
      return '파일을 열거나 읽을 수 없습니다'
    case 'nonregular':
      return 'Goal 경로가 일반 파일이 아닙니다'
    case 'not_json':
      return '파일 내용이 JSON 이 아닙니다'
    case 'schema_rejected':
      return field === null
        ? '이 빌드의 goal 스키마가 파일을 거절했습니다'
        : `이 빌드의 goal 스키마가 파일을 거절했습니다 (위치: ${goalStoreLocationLabel(field)})`
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
    case 'mirror_nonregular':
      return '.last-good 미러가 일반 파일이 아님'
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
        ? '거절된 위치를 확인하고 수정한 뒤 다시 조회하세요'
        : `파일의 ${goalStoreLocationLabel(field)} 위치를 확인하고 수정한 뒤 다시 조회하세요`
    case 'reset_goal_store':
      return 'masc goals reset --base-path <p> 로 goal store 를 리셋합니다 (파일은 옮기고 지우지 않음)'
    case 'restore_permission':
      return '파일 읽기 권한을 복구합니다'
    case 'inspect_path':
      return '파일 경로와 링크, 연결된 저장소와 서버 상태를 확인한 뒤 다시 조회하세요'
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
