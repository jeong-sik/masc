// SyncConflict — AX molecule for offline-online sync conflict resolution.
//
// Kimi design system sec03 reference: 3.2.2 Git-style diff + manual merge UI.

import { html } from 'htm/preact'
import { useMemo, useState } from 'preact/hooks'
import { useId } from '../../../design-system/headless-preact/use-id'
import { InlineEdit } from './inline-edit'

export interface ConflictEntry {
  field: string
  localValue: string
  remoteValue: string
  mergedValue?: string
}

interface SyncConflictProps {
  conflicts: ConflictEntry[]
  onResolve: (resolutions: Record<string, string>) => void
  testId?: string
}

export type ConflictResolutionState = 'resolved' | 'unresolved'

export type SyncConflictStatus = 'empty' | 'open' | 'partial' | 'resolved'

export interface SyncConflictSummary {
  totalCount: number
  resolvedCount: number
  unresolvedCount: number
  status: SyncConflictStatus
  actionRequired: boolean
  fields: string[]
  resolvedFields: string[]
  unresolvedFields: string[]
}

export function isConflictResolved(
  conflict: ConflictEntry,
  resolutions: Record<string, string> = {},
): boolean {
  return resolutions[conflict.field] !== undefined || conflict.mergedValue !== undefined
}

export function getConflictResolutionState(
  conflict: ConflictEntry,
  resolutions: Record<string, string> = {},
): ConflictResolutionState {
  return isConflictResolved(conflict, resolutions) ? 'resolved' : 'unresolved'
}

export function summarizeSyncConflicts(
  conflicts: ConflictEntry[],
  resolutions: Record<string, string> = {},
): SyncConflictSummary {
  const fields = conflicts.map(conflict => conflict.field)
  const resolvedFields = conflicts
    .filter(conflict => isConflictResolved(conflict, resolutions))
    .map(conflict => conflict.field)
  const unresolvedFields = conflicts
    .filter(conflict => !isConflictResolved(conflict, resolutions))
    .map(conflict => conflict.field)

  const totalCount = conflicts.length
  const resolvedCount = resolvedFields.length
  const unresolvedCount = unresolvedFields.length
  const status: SyncConflictStatus =
    totalCount === 0
      ? 'empty'
      : unresolvedCount === 0
        ? 'resolved'
        : resolvedCount === 0
          ? 'open'
          : 'partial'

  return {
    totalCount,
    resolvedCount,
    unresolvedCount,
    status,
    actionRequired: unresolvedCount > 0,
    fields,
    resolvedFields,
    unresolvedFields,
  }
}

function resolutionLabel(state: ConflictResolutionState): string {
  return state === 'resolved' ? '해결됨' : '미해결'
}

export function SyncConflict({ conflicts, onResolve, testId }: SyncConflictProps) {
  const [resolutions, setResolutions] = useState<Record<string, string>>({})
  const summaryId = `${useId()}-sync-conflict-summary`

  const summary = useMemo(
    () => summarizeSyncConflicts(conflicts, resolutions),
    [conflicts, resolutions],
  )

  const setResolution = (field: string, value: string) => {
    setResolutions(prev => ({ ...prev, [field]: value }))
  }

  return html`
    <div
      class="rounded-[var(--r-1)] border border-[var(--bad-20)] bg-[var(--color-bg-surface)] p-3"
      data-sync-conflict
      data-sync-conflict-count=${summary.totalCount}
      data-sync-conflict-resolved-count=${summary.resolvedCount}
      data-sync-conflict-unresolved-count=${summary.unresolvedCount}
      data-sync-conflict-status=${summary.status}
      data-sync-conflict-action-required=${String(summary.actionRequired)}
      data-testid=${testId}
      role="region"
      aria-label="동기화 충돌"
      aria-describedby=${summaryId}
    >
      <h4 class="mb-2 text-sm font-medium text-[var(--err)]">
        동기화 충돌 (${summary.resolvedCount}/${summary.totalCount})
      </h4>
      <div
        id=${summaryId}
        class="mb-3 grid grid-cols-3 gap-2 rounded-[var(--r-1)] bg-[var(--color-bg-elevated)] p-2"
        aria-label="동기화 충돌 요약"
      >
        <div>
          <div class="text-3xs text-[var(--color-fg-secondary)]">전체</div>
          <div class="font-mono text-sm text-[var(--color-fg-primary)]">${summary.totalCount}</div>
        </div>
        <div>
          <div class="text-3xs text-[var(--color-fg-secondary)]">해결</div>
          <div class="font-mono text-sm text-[var(--ok)]">${summary.resolvedCount}</div>
        </div>
        <div>
          <div class="text-3xs text-[var(--color-fg-secondary)]">남음</div>
          <div class="font-mono text-sm text-[var(--err)]">${summary.unresolvedCount}</div>
        </div>
      </div>
      ${summary.totalCount === 0
        ? html`
            <div
              class="rounded-[var(--r-1)] border border-dashed border-[var(--color-border-default)] px-3 py-2 text-sm text-[var(--color-fg-secondary)]"
              role="status"
            >
              충돌 없음
            </div>
          `
        : html`
            <div role="list" aria-label="충돌 항목 목록">
              ${conflicts.map(c => {
                const resolutionState = getConflictResolutionState(c, resolutions)
                return html`
                  <div
                    key=${c.field}
                    class="mb-3 border-b border-[var(--color-border-default)] pb-2 last:mb-0 last:border-b-0 last:pb-0"
                    role="listitem"
                    aria-label=${`${c.field} 충돌, ${resolutionLabel(resolutionState)}`}
                    data-sync-conflict-field=${c.field}
                    data-sync-conflict-resolution-state=${resolutionState}
                  >
                    <div class="mb-1 flex items-center justify-between gap-2">
                      <span class="min-w-0 truncate font-mono text-3xs text-[var(--color-fg-secondary)]">
                        ${c.field}
                      </span>
                      <span
                        class="shrink-0 rounded-[var(--r-1)] bg-[var(--color-bg-elevated)] px-1.5 py-0.5 text-3xs text-[var(--color-fg-secondary)]"
                      >
                        ${resolutionLabel(resolutionState)}
                      </span>
                    </div>
                    <div class="mb-1 grid grid-cols-1 gap-2 sm:grid-cols-2">
                      <div
                        class="rounded-[var(--r-1)] bg-[var(--ok-10)]/10 p-2"
                        data-sync-conflict-side="local"
                      >
                        <div class="mb-0.5 text-3xs font-medium text-[var(--ok)]">로컬</div>
                        <div class="break-all font-mono text-xs text-[var(--color-fg-primary)]">${c.localValue}</div>
                      </div>
                      <div
                        class="rounded-[var(--r-1)] bg-[var(--bad-10)] p-2"
                        data-sync-conflict-side="remote"
                      >
                        <div class="mb-0.5 text-3xs font-medium text-[var(--err)]">원격</div>
                        <div class="break-all font-mono text-xs text-[var(--color-fg-primary)]">${c.remoteValue}</div>
                      </div>
                    </div>
                    <div class="mt-1 flex items-center gap-2" data-sync-conflict-merge-field=${c.field}>
                      <span class="text-3xs text-[var(--color-fg-secondary)]">병합:</span>
                      <div class="min-w-0 flex-1">
                        <${InlineEdit}
                          value=${resolutions[c.field] ?? c.mergedValue ?? c.localValue}
                          onSave=${(v: string) => setResolution(c.field, v)}
                        />
                      </div>
                    </div>
                  </div>
                `
              })}
            </div>
          `}
      <button
        class="mt-2 w-full rounded-[var(--r-1)] bg-[var(--color-accent)] py-1.5 text-sm text-white transition-colors hover:bg-[var(--accent-11)] disabled:cursor-not-allowed disabled:opacity-50"
        onClick=${() => onResolve(resolutions)}
        disabled=${summary.totalCount === 0}
        aria-label="병합 적용"
      >
        병합 적용
      </button>
    </div>
  `
}
