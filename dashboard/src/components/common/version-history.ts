// VersionHistory — AX organism that shows snapshot timeline + rollback.
//
// Kimi design system sec03 reference: 3.2.3 git-log-style snapshot timeline.

import { html } from 'htm/preact'
import { useMemo } from 'preact/hooks'
import { useId } from '../../../design-system/headless-preact/use-id'

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

export type VersionSnapshotState = 'current' | 'historical'

export type VersionHistoryStatus = 'empty' | 'current' | 'missing-current'

export interface VersionHistorySummary {
  totalCount: number
  currentId: string
  currentIndex: number
  currentShortId: string | null
  status: VersionHistoryStatus
  hasCurrent: boolean
  rollbackCount: number
  totalAdded: number
  totalModified: number
  totalDeleted: number
  newestTimestamp: number | null
  oldestTimestamp: number | null
}

export function shortSnapshotId(id: string, snapshots: Array<VersionSnapshot | string> = []): string {
  const minLength = Math.min(7, id.length)
  if (snapshots.length === 0) {
    return id.slice(0, minLength)
  }

  const ids = snapshots.map(snapshot => typeof snapshot === 'string' ? snapshot : snapshot.id)
  for (let length = minLength; length <= id.length; length += 1) {
    const prefix = id.slice(0, length)
    if (ids.filter(candidate => candidate.startsWith(prefix)).length === 1) {
      return prefix
    }
  }

  return id
}

export function getVersionSnapshotState(
  snapshot: VersionSnapshot,
  currentId: string,
): VersionSnapshotState {
  return snapshot.id === currentId ? 'current' : 'historical'
}

export function summarizeVersionHistory(
  snapshots: VersionSnapshot[],
  currentId: string,
  rollbackEnabled = false,
): VersionHistorySummary {
  const currentIndex = snapshots.findIndex(snapshot => snapshot.id === currentId)
  const hasCurrent = currentIndex >= 0
  const timestamps = snapshots.map(snapshot => snapshot.timestamp)
  const totalAdded = snapshots.reduce((sum, snapshot) => sum + snapshot.changes.added, 0)
  const totalModified = snapshots.reduce((sum, snapshot) => sum + snapshot.changes.modified, 0)
  const totalDeleted = snapshots.reduce((sum, snapshot) => sum + snapshot.changes.deleted, 0)

  return {
    totalCount: snapshots.length,
    currentId,
    currentIndex,
    currentShortId: hasCurrent ? shortSnapshotId(currentId, snapshots) : null,
    status: snapshots.length === 0 ? 'empty' : hasCurrent ? 'current' : 'missing-current',
    hasCurrent,
    rollbackCount: rollbackEnabled ? snapshots.filter(snapshot => snapshot.id !== currentId).length : 0,
    totalAdded,
    totalModified,
    totalDeleted,
    newestTimestamp: timestamps.length > 0 ? Math.max(...timestamps) : null,
    oldestTimestamp: timestamps.length > 0 ? Math.min(...timestamps) : null,
  }
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

function snapshotAriaLabel(snapshot: VersionSnapshot, state: VersionSnapshotState): string {
  const stateLabel = state === 'current' ? '현재 버전' : '이전 버전'
  return `${snapshot.id} ${snapshot.message}, ${stateLabel}, 변경 +${snapshot.changes.added} ~${snapshot.changes.modified} -${snapshot.changes.deleted}`
}

export function VersionHistory({
  snapshots,
  currentId,
  onRollback,
  testId,
}: VersionHistoryProps) {
  const summaryId = `${useId()}-version-history-summary`
  const summary = useMemo(
    () => summarizeVersionHistory(snapshots, currentId, Boolean(onRollback)),
    [snapshots, currentId, onRollback],
  )

  return html`
    <div
      class="space-y-3"
      data-version-history
      data-version-history-count=${summary.totalCount}
      data-version-history-current-id=${summary.currentId}
      data-version-history-current-index=${summary.currentIndex}
      data-version-history-status=${summary.status}
      data-version-history-rollback-count=${summary.rollbackCount}
      data-version-history-added=${summary.totalAdded}
      data-version-history-modified=${summary.totalModified}
      data-version-history-deleted=${summary.totalDeleted}
      data-testid=${testId}
      role="region"
      aria-label="버전 히스토리"
      aria-describedby=${summaryId}
    >
      <div
        id=${summaryId}
        class="grid grid-cols-3 gap-2 rounded-[var(--r-1)] bg-[var(--color-bg-elevated)] p-2"
        aria-label="버전 히스토리 요약"
      >
        <div>
          <div class="text-3xs text-[var(--color-fg-secondary)]">스냅샷</div>
          <div class="font-mono text-sm text-[var(--color-fg-primary)]">${summary.totalCount}</div>
        </div>
        <div>
          <div class="text-3xs text-[var(--color-fg-secondary)]">현재</div>
          <div class="font-mono text-sm text-[var(--color-fg-primary)]">${summary.currentShortId ?? '없음'}</div>
        </div>
        <div>
          <div class="text-3xs text-[var(--color-fg-secondary)]">변경</div>
          <div class="font-mono text-sm">
            <span class="text-[var(--ok)]">+${summary.totalAdded}</span>
            <span class="ml-1 text-[var(--warn)]">~${summary.totalModified}</span>
            <span class="ml-1 text-[var(--err)]">-${summary.totalDeleted}</span>
          </div>
        </div>
      </div>
      ${summary.totalCount === 0
        ? html`
            <div
              class="rounded-[var(--r-1)] border border-dashed border-[var(--color-border-default)] px-3 py-2 text-sm text-[var(--color-fg-secondary)]"
              role="status"
            >
              스냅샷 없음
            </div>
          `
        : html`
            <div class="space-y-0" role="list" aria-label="버전 히스토리">
              ${snapshots.map((snap, index) => {
                const state = getVersionSnapshotState(snap, currentId)
                const isCurrent = state === 'current'
                const borderColor = isCurrent ? 'var(--color-accent)' : 'var(--color-border-default)'
                const dotColor = isCurrent ? 'var(--color-accent)' : 'var(--color-border-default)'
                const timestampIso = new Date(snap.timestamp).toISOString()
                return html`
                  <div
                    key=${snap.id}
                    class="group relative flex items-start gap-3 border-l-2 py-2 pl-4"
                    style=${{ borderColor }}
                    role="listitem"
                    aria-current=${isCurrent ? 'step' : undefined}
                    aria-label=${snapshotAriaLabel(snap, state)}
                    data-version-snapshot-id=${snap.id}
                    data-version-snapshot-index=${index}
                    data-version-snapshot-state=${state}
                    data-version-snapshot-current=${String(isCurrent)}
                    data-version-snapshot-added=${snap.changes.added}
                    data-version-snapshot-modified=${snap.changes.modified}
                    data-version-snapshot-deleted=${snap.changes.deleted}
                    data-version-snapshot-timestamp=${snap.timestamp}
                  >
                    <span
                      class="absolute -left-[5px] top-3 h-2 w-2 rounded-full"
                      style=${{ background: dotColor }}
                      aria-hidden="true"
                    >
                    </span>
                    <div class="min-w-0 flex-1">
                      <div class="flex flex-wrap items-center gap-2">
                        <span class="font-mono text-3xs text-[var(--color-fg-secondary)]"
                          >${shortSnapshotId(snap.id, snapshots)}</span
                        >
                        <span class="min-w-0 text-sm text-[var(--color-fg-primary)]"
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
                        ${snap.author} ·
                        <time datetime=${timestampIso}>${formatRelativeTime(snap.timestamp)}</time>
                        <span class="ml-2 text-[var(--ok)]">+${snap.changes.added}</span>
                        <span class="ml-1 text-[var(--warn)]">~${snap.changes.modified}</span>
                        <span class="ml-1 text-[var(--err)]">-${snap.changes.deleted}</span>
                      </div>
                    </div>
                    ${!isCurrent && onRollback
                      ? html`
                          <button
                            class="shrink-0 rounded-[var(--r-1)] px-2 py-1 text-3xs text-[var(--color-accent)] opacity-100 transition-colors hover:bg-[var(--color-bg-hover)] hover:underline focus:bg-[var(--color-bg-hover)] sm:opacity-0 sm:group-hover:opacity-100 sm:focus:opacity-100"
                            onClick=${() => onRollback(snap.id)}
                            aria-label="${snap.id} 상태로 롤백"
                          >
                            이 상태로 롤백
                          </button>
                        `
                      : null}
                  </div>
                `
              })}
            </div>
          `}
    </div>
  `
}
