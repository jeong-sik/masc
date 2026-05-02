// VersionHistory — AX organism that shows snapshot timeline + rollback.
//
// Kimi design system sec03 reference: 3.2.3 git-log-style snapshot timeline.

import { html } from 'htm/preact'

export interface VersionSnapshot {
  id: string
  timestamp: number
  author: string
  message: string
  changes: { added: number; modified: number; deleted: number }
}

interface VersionHistoryProps {
  snapshots: VersionSnapshot[]
  currentId: string
  onRollback?: (id: string) => void
  testId?: string
}

function formatRelativeTime(ts: number): string {
  const diff = Date.now() - ts
  const sec = Math.floor(diff / 1000)
  if (sec < 60) return `${sec}초 전`
  const min = Math.floor(sec / 60)
  if (min < 60) return `${min}분 전`
  const hr = Math.floor(min / 60)
  if (hr < 24) return `${hr}시간 전`
  const day = Math.floor(hr / 24)
  return `${day}일 전`
}

export function VersionHistory({
  snapshots,
  currentId,
  onRollback,
  testId,
}: VersionHistoryProps) {
  return html`
    <div
      class="space-y-0"
      data-version-history
      data-testid=${testId}
      role="list"
      aria-label="버전 히스토리"
    >
      ${snapshots.map(
        snap => {
          const isCurrent = snap.id === currentId
          const borderColor = isCurrent ? 'var(--color-accent)' : 'var(--color-border-default)'
          const dotColor = isCurrent ? 'var(--color-accent)' : 'var(--color-border-default)'
          return html`
            <div
              key=${snap.id}
              class="relative flex items-start gap-3 border-l-2 py-2 pl-4"
              style=${{ borderColor }}
              role="listitem"
            >
              <span
                class="absolute -left-[5px] top-3 h-2 w-2 rounded-full"
                style=${{ background: dotColor }}
                aria-hidden="true"
              >
              </span>
              <div class="flex-1 min-w-0">
                <div class="flex items-center gap-2 flex-wrap">
                  <span class="font-mono text-3xs text-[var(--color-fg-secondary)]"
                    >${snap.id.slice(0, 7)}</span
                  >
                  <span class="text-sm text-[var(--color-fg-primary)]"
                    >${snap.message}</span
                  >
                  ${isCurrent
                    ? html`
                        <span
                          class="rounded-[var(--r-1)] bg-[var(--color-accent)] px-1.5 text-3xs text-white"
                          >현재</span
                        >
                      `
                    : null}
                </div>
                <div class="mt-0.5 text-3xs text-[var(--color-fg-secondary)]">
                  ${snap.author} · ${formatRelativeTime(snap.timestamp)}
                  <span class="ml-2 text-[var(--ok-10)]">+${snap.changes.added}</span>
                  <span class="ml-1 text-[var(--warn-10)]">~${snap.changes.modified}</span>
                  <span class="ml-1 text-[var(--error-10)]">-${snap.changes.deleted}</span>
                </div>
              </div>
              ${!isCurrent && onRollback
                ? html`
                    <button
                      class="text-3xs text-[var(--color-accent)] opacity-0 transition-opacity hover:underline focus:opacity-100 group-hover:opacity-100"
                      onClick=${() => onRollback(snap.id)}
                      aria-label="${snap.id.slice(0, 7)} 상태로 롤백"
                    >
                      이 상태로 롤백
                    </button>
                  `
                : null}
            </div>
          `
        },
      )}
    </div>
  `
}
