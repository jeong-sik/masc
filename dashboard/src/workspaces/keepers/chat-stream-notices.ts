/**
 * What the Keeper chat stream says beside the reply text: which runtime
 * attempt is streaming, a provider retry in progress, a broken stream, a
 * continuation checkpoint, an interrupt that did not land. The TUI shows the
 * same facts (lib/masc_tui/store/fleet_store.ml, keeper_dive.ml).
 */

import type { KeeperProviderRetry } from '../../lib/keeper-chat-stream-contract'
import type {
  ChatDeliveryState,
  ChatProviderRetry,
  ChatRuntimeAttempt,
  ChatStreamNotice,
} from './types'

/** The reply's delivery state once the server has accepted the operation.
 *  A terminal failure or cancellation is not a delivery. */
export function acceptedReplyState(state: string): { readonly delivery: ChatDeliveryState; readonly detail: string | null } {
  switch (state) {
    case 'Queued':
      return { delivery: 'Queued', detail: null }
    case 'Running':
      return { delivery: 'Pending_processing', detail: null }
    case 'Failed':
      return { delivery: 'Failed', detail: '작업이 실패로 끝났어요.' }
    case 'Cancelled':
      return { delivery: 'Failed', detail: '작업이 취소됐어요.' }
    default:
      return { delivery: 'Delivered', detail: null }
  }
}

export function chatProviderRetry(retry: KeeperProviderRetry): ChatProviderRetry {
  return {
    runtimeId: retry.attempt.runtime_id,
    attempt: retry.retry.attempt,
    maxRetries: retry.retry.max_retries,
    delayMs: retry.retry.retry_delay_ms,
    errorStatus: retry.retry.error_status,
  }
}

/** "공급자 재시도 2/5 · HTTP 529 · 4초 뒤 · <runtime>" */
export function providerRetryLabel(retry: ChatProviderRetry): string {
  const seconds = Math.max(1, Math.round(retry.delayMs / 1000))
  return [
    `공급자 재시도 ${retry.attempt}/${retry.maxRetries}`,
    retry.errorStatus === null ? '' : `HTTP ${retry.errorStatus}`,
    `${seconds}초 뒤`,
    retry.runtimeId,
  ]
    .filter((part) => part !== '')
    .join(' · ')
}

/** The pill for the runtime streaming the reply. A later attempt says so:
 *  what it streamed replaced the earlier attempt's text. */
export function runtimeAttemptLabel(attempt: ChatRuntimeAttempt): string | null {
  const retried = attempt.attemptIndex !== null && attempt.attemptIndex > 1
  if (attempt.runtimeId === null) return retried ? `다시 시도 #${attempt.attemptIndex}` : null
  return retried ? `${attempt.runtimeId} · 다시 시도 #${attempt.attemptIndex}` : attempt.runtimeId
}

/** Adds a notice unless the same one is already the last one. */
export function appendStreamNotice(
  notices: readonly ChatStreamNotice[] | undefined,
  notice: ChatStreamNotice,
): readonly ChatStreamNotice[] {
  const list = notices ?? []
  const last = list[list.length - 1]
  if (last && last.kind === notice.kind && last.text === notice.text) return list
  return [...list, notice]
}

export function streamNoticePrefix(kind: ChatStreamNotice['kind']): string {
  switch (kind) {
    case 'protocol_error':
      return '스트림 오류'
    case 'checkpoint':
      return '체크포인트'
    case 'interrupt':
      return '끼어들기'
  }
}
