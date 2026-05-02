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
import { ActionButton } from './button'

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
  critical: 'text-[var(--color-status-err)]',
  warning: 'text-[var(--color-status-warn)]',
  info: 'text-[var(--accent-45)]',
}

const CODE_BADGE_BG: Record<ErrorSeverity, string> = {
  critical: 'bg-[var(--color-status-err)]/15 text-[var(--color-status-err)]',
  warning: 'bg-[var(--color-status-warn)]/15 text-[var(--color-status-warn)]',
  info: 'bg-[var(--accent-45)]/15 text-[var(--accent-45)]',
}

interface ErrorPanelProps {
  onClose: () => void
}

export function ErrorPanel({ onClose }: ErrorPanelProps) {
  const items = unacknowledgedErrors.value

  if (items.length === 0) {
    return html`
      <div class="absolute right-0 top-full mt-1.5 z-[var(--z-overlay-dropdown,3050)] w-96 max-h-80 overflow-hidden rounded-lg border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] shadow-[var(--shadow-panel)] backdrop-blur-xl">
        <div class="flex items-center justify-between px-3 py-2 border-b border-[var(--white-5)]">
          <span class="text-xs font-medium text-[var(--color-fg-muted)]">에러 없음</span>
          <${ActionButton} variant="subtle" size="sm" class="p-0.5" ariaLabel="에러 패널 닫기" onClick=${onClose}>
            <${X} size=${14} />
          <//>
        </div>
        <div class="flex items-center justify-center py-6 text-xs text-[var(--color-fg-muted)]">
          모든 에러를 확인했습니다.
        </div>
      </div>
    `
  }

  return html`
    <div class="absolute right-0 top-full mt-1.5 z-[var(--z-overlay-dropdown,3050)] w-96 max-h-80 overflow-hidden rounded-lg border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] shadow-[var(--shadow-panel)] backdrop-blur-xl flex flex-col" role="alert">
      <div class="flex items-center justify-between px-3 py-2 border-b border-[var(--white-5)] shrink-0">
        <span class="text-xs font-medium text-[var(--color-fg-muted)]">미확인 에러 <span class="text-[var(--color-status-err)]">${items.length}</span>건</span>
        <div class="flex items-center gap-1">
          <${ActionButton}
            variant="ghost"
            size="sm"
            class="text-2xs"
            onClick=${() => { clearAllErrors(); onClose() }}
          >모두 확인<//>
          <${ActionButton} variant="subtle" size="sm" class="p-0.5" ariaLabel="에러 패널 닫기" onClick=${onClose}>
            <${X} size=${14} />
          <//>
        </div>
      </div>

      <div class="overflow-y-auto flex-1 divide-y divide-[var(--white-5)]">
        ${items.map(e => {
          const sev = e.severity
          const iconColor = SEVERITY_ICON_COLOR[sev]
          const badgeBg = CODE_BADGE_BG[sev]
          const label = CODE_LABELS[e.errorCode]
          return html`
          <div key=${e.id} class="flex items-start gap-2 px-3 py-2 hover:bg-[var(--white-4)] transition-colors group">
            <span class="mt-0.5 shrink-0 ${iconColor}">
              ${sev === 'info' ? html`<${Info} size=${13} />` : html`<${AlertTriangle} size=${13} />`}
            </span>
            <div class="min-w-0 flex-1">
              <div class="flex items-center gap-1.5 text-xs">
                <span class="font-medium text-[var(--color-fg-secondary)] truncate">${e.agentName}</span>
                <span class="shrink-0 text-2xs px-1 py-px rounded-[var(--r-1)] ${badgeBg}">${label}</span>
                ${e.taskId ? html`<span class="text-[var(--color-fg-muted)] truncate max-w-20">${e.taskId}</span>` : null}
                ${e.count > 1 ? html`<span class="shrink-0 text-2xs text-[var(--color-status-warn)]">×${e.count}</span>` : null}
              </div>
              <p class="mt-0.5 text-xs text-[var(--color-fg-primary)] leading-[1.4] line-clamp-2">${e.message}</p>
              <span class="mt-0.5 block text-2xs text-[var(--color-fg-muted)]">${formatElapsedCompact((Date.now() - e.timestamp) / 1000)} 전</span>
            </div>
            <${ActionButton}
              variant="subtle"
              size="sm"
              class="shrink-0 mt-0.5 p-1 opacity-0 group-hover:opacity-100 hover:text-[var(--color-status-ok)] hover:bg-[var(--white-8)]"
              title="확인"
              ariaLabel="에러 확인"
              onClick=${() => acknowledgeError(e.id)}
            ><${Check} size=${14} /><//>
          </div>
        `})}
      </div>
    </div>
  `
}
