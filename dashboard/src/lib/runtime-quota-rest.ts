// Words for a runtime's quota rest. The cause is the server's typed value, so
// each one gets its own word and a new cause fails to compile here.

import type { RuntimeQuotaRest } from '../api/schemas/runtime-resolved'
import { formatTimestampKo } from './format-time'

export function runtimeQuotaCauseLabel(cause: RuntimeQuotaRest['cause']): string {
  switch (cause) {
    case 'payment_refused':
      return '결제 거절'
    case 'provider_quota_refused':
      return '한도 소진'
    case 'usage_read':
      return '한도 소진 (사용량 조회)'
  }
}

export function runtimeQuotaEndLabel(rest: RuntimeQuotaRest): string {
  const at = formatTimestampKo(rest.until)
  return rest.reset_stated ? `${at} 초기화` : `초기화 시각 없음, ${at} 다시 호출`
}

export function runtimeQuotaRestLabel(rest: RuntimeQuotaRest): string {
  return `${runtimeQuotaCauseLabel(rest.cause)} (${runtimeQuotaEndLabel(rest)})`
}
