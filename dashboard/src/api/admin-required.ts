import { ApiRequestError } from './core'

export const ADMIN_REQUIRED_MESSAGE = '원본 실행 기록과 편집 파일을 보려면 관리자 권한으로 인증해야 합니다.'

export function isAdminRequired(error: unknown): boolean {
  return error instanceof ApiRequestError && (error.status === 401 || error.status === 403)
}
