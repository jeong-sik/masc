// Error panel dropdown — unacknowledged error list with acknowledge actions

import { html } from 'htm/preact'
import { X, Check, AlertTriangle, Info } from 'lucide-preact'
import {
  unacknowledgedErrors,
  acknowledgeError,
  clearAllErrors,
} from './error-notification-state'
import type { ErrorCode, ErrorSeverity } from '../../types/error'
import { formatElapsedCompact } from '../../lib/format-time'

const CODE_LABELS: Record<ErrorCode, string> = {
  validation_error: '입력',
  not_found: '404',
  auth_required: '인증',
  permission_denied: '권한',
  conflict: '충돌',
  rate_limited: '제한',
  timeout: '지연',
  not_implemented: '미구현',
  internal_error: '오류',
  precondition_failed: '사전조건',
  unknown: '기타',
}

const SEVERITY_ICON_COLOR: Record<ErrorSeverity, string> = {
  critical: 'text-[var(--bad)]',
  warning: 'text-[var(--warn)]',
  info: 'text-[var(--accent-45)]',
}

const CODE_BADGE_BG: Record<ErrorSeverity, string> = {
  critical: 'bg-[var(--bad)]/15 text-[var(--bad)]',
  warning: 'bg-[var(--warn)]/15 text-[var(--warn)]',
  info: 'bg-[var(--accent-45)]/15 text-[var(--accent-45)]',
}

interface ErrorPanelProps {
  onClose: () => void
}

export function ErrorPanel({ onClose }: ErrorPanelProps) {
  const items = unacknowledgedErrors.value

  if (items.length === 0) {
    return html`
      <div class="absolute right-0 top-full mt-1.5 z-[var(--z-overlay-dropdown,3050)] w-96 max-h-80 overflow-hidden rounded-lg border border-[var(--card-border)] bg-[rgba(10,18,34,0.98)] shadow-xl backdrop-blur-xl" role="region" aria-label="에러 패널">
        <div class="flex items-center justify-between px-3 py-2 border-b border-[var(--white-5)]">
          <span class="text-xs font-medium text-[var(--text-muted)]">에러 없음</span>
          <button type="button" class="text-[var(--text-muted)] hover:text-[var(--text-body)] cursor-pointer p-1.5" onClick=${onClose} aria-label="닫기">
            <${X} size=${14} aria-hidden="true" />
          </button>
        </div>
        <div class="flex items-center justify-center py-6 text-xs text-[var(--text-muted)]">
          모든 에러를 확인했습니다.
        </div>
      </div>
    `
  }

  return html`
    <div class="absolute right-0 top-full mt-1.5 z-[var(--z-overlay-dropdown,3050)] w-96 max-h-80 overflow-hidden rounded-lg border border-[var(--card-border)] bg-[rgba(10,18,34,0.98)] shadow-xl backdrop-blur-xl flex flex-col" role="region" aria-label="미확인 에러">
      <div class="flex items-center justify-between px-3 py-2 border-b border-[var(--white-5)] shrink-0">
        <span class="text-xs font-medium text-[var(--text-muted)]">미확인 에러 <span class="text-[var(--bad)]">${items.length}</span>건</span>
        <div class="flex items-center gap-1">
          <button type="button"
            class="text-2xs px-2 py-0.5 rounded border border-[var(--card-border)] bg-[var(--white-4)] text-[var(--text-muted)] hover:bg-[var(--white-10)] cursor-pointer transition-colors"
            onClick=${() => { clearAllErrors(); onClose() }}
          >모두 확인</button>
          <button type="button" class="text-[var(--text-muted)] hover:text-[var(--text-body)] cursor-pointer p-1.5" onClick=${onClose} aria-label="닫기">
            <${X} size=${14} aria-hidden="true" />
          </button>
        </div>
      </div>

      <div class="overflow-y-auto custom-scrollbar flex-1 divide-y divide-[var(--white-5)]">
        ${items.map(e => {
          const sev = e.severity
          const iconColor = SEVERITY_ICON_COLOR[sev]
          const badgeBg = CODE_BADGE_BG[sev]
          const label = CODE_LABELS[e.errorCode]
          return html`
          <div key=${e.id} class="flex items-start gap-2 px-3 py-2 hover:bg-[var(--white-4)] transition-colors group">
            <span class="mt-0.5 shrink-0 ${iconColor}" aria-hidden="true">
              ${sev === 'info' ? html`<${Info} size=${13} />` : html`<${AlertTriangle} size=${13} />`}
            </span>
            <div class="min-w-0 flex-1">
              <div class="flex items-center gap-1.5 text-xs">
                <span class="font-medium text-[var(--text-strong)] truncate" title=${e.agentName}>${e.agentName}</span>
                <span class="shrink-0 text-2xs px-1 py-px rounded ${badgeBg}">${label}</span>
                ${e.taskId ? html`<span class="text-[var(--text-muted)] truncate max-w-20" title=${e.taskId}>${e.taskId}</span>` : null}
                ${e.count > 1 ? html`<span class="shrink-0 text-2xs text-[var(--warn)]">×${e.count}</span>` : null}
              </div>
              <p class="mt-0.5 text-xs text-[var(--text-body)] leading-[1.4] line-clamp-2">${e.message}</p>
              <span class="mt-0.5 block text-2xs text-[var(--text-muted)]">${formatElapsedCompact((Date.now() - e.timestamp) / 1000)} 전</span>
            </div>
            <button type="button"
              class="shrink-0 mt-0.5 p-1 rounded opacity-0 group-hover:opacity-100 text-[var(--text-muted)] hover:text-[var(--ok)] hover:bg-[var(--white-8)] cursor-pointer transition-all"
              title="확인"
              aria-label="에러 확인"
              onClick=${() => acknowledgeError(e.id)}
            ><${Check} size=${14} aria-hidden="true" /></button>
          </div>
        `})}
      </div>
    </div>
  `
}
