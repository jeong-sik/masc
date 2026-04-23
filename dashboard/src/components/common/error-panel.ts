// Error panel dropdown — unacknowledged error list with acknowledge actions

import { html } from 'htm/preact'
import { X, Check, AlertTriangle } from 'lucide-preact'
import {
  unacknowledgedErrors,
  acknowledgeError,
  clearAllErrors,
} from './error-notification'
import { formatElapsedCompact } from '../../lib/format-time'

interface ErrorPanelProps {
  onClose: () => void
}

export function ErrorPanel({ onClose }: ErrorPanelProps) {
  const items = unacknowledgedErrors.value

  if (items.length === 0) {
    return html`
      <div class="absolute right-0 top-full mt-1.5 z-[var(--z-overlay-dropdown,3050)] w-96 max-h-80 overflow-hidden rounded-lg border border-[var(--card-border)] bg-[rgba(10,18,34,0.98)] shadow-xl backdrop-blur-xl">
        <div class="flex items-center justify-between px-3 py-2 border-b border-[var(--white-5)]">
          <span class="text-xs font-medium text-[var(--text-muted)]">에러 없음</span>
          <button type="button" class="text-[var(--text-muted)] hover:text-[var(--text-body)] cursor-pointer p-0.5" onClick=${onClose}>
            <${X} size=${14} />
          </button>
        </div>
        <div class="flex items-center justify-center py-6 text-xs text-[var(--text-muted)]">
          모든 에러를 확인했습니다.
        </div>
      </div>
    `
  }

  return html`
    <div class="absolute right-0 top-full mt-1.5 z-[var(--z-overlay-dropdown,3050)] w-96 max-h-80 overflow-hidden rounded-lg border border-[var(--card-border)] bg-[rgba(10,18,34,0.98)] shadow-xl backdrop-blur-xl flex flex-col">
      <div class="flex items-center justify-between px-3 py-2 border-b border-[var(--white-5)] shrink-0">
        <span class="text-xs font-medium text-[var(--text-muted)]">미확인 에러 <span class="text-[var(--bad)]">${items.length}</span>건</span>
        <div class="flex items-center gap-1">
          <button type="button"
            class="text-2xs px-2 py-0.5 rounded border border-[var(--card-border)] bg-[var(--white-4)] text-[var(--text-muted)] hover:bg-[var(--white-10)] cursor-pointer transition-colors"
            onClick=${() => { clearAllErrors(); onClose() }}
          >모두 확인</button>
          <button type="button" class="text-[var(--text-muted)] hover:text-[var(--text-body)] cursor-pointer p-0.5" onClick=${onClose}>
            <${X} size=${14} />
          </button>
        </div>
      </div>

      <div class="overflow-y-auto flex-1 divide-y divide-[var(--white-5)]">
        ${items.map(e => html`
          <div key=${e.id} class="flex items-start gap-2 px-3 py-2 hover:bg-[var(--white-4)] transition-colors group">
            <span class="mt-0.5 shrink-0 text-[var(--bad)]"><${AlertTriangle} size=${13} /></span>
            <div class="min-w-0 flex-1">
              <div class="flex items-center gap-1.5 text-xs">
                <span class="font-medium text-[var(--text-strong)] truncate">${e.agentName}</span>
                ${e.taskId ? html`<span class="text-[var(--text-muted)] truncate max-w-20">${e.taskId}</span>` : null}
                ${e.count > 1 ? html`<span class="shrink-0 text-2xs text-[var(--warn)]">×${e.count}</span>` : null}
              </div>
              <p class="mt-0.5 text-xs text-[var(--text-body)] leading-[1.4] line-clamp-2">${e.message}</p>
              <span class="mt-0.5 block text-2xs text-[var(--text-muted)]">${formatElapsedCompact((Date.now() - e.timestamp) / 1000)} 전</span>
            </div>
            <button type="button"
              class="shrink-0 mt-0.5 p-1 rounded opacity-0 group-hover:opacity-100 text-[var(--text-muted)] hover:text-[var(--ok)] hover:bg-[var(--white-8)] cursor-pointer transition-all"
              title="확인"
              onClick=${() => acknowledgeError(e.id)}
            ><${Check} size=${14} /></button>
          </div>
        `)}
      </div>
    </div>
  `
}
