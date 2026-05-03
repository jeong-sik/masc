// SyncConflict — AX molecule for offline-online sync conflict resolution.
//
// Kimi design system sec03 reference: 3.2.2 Git-style diff + manual merge UI.

import { html } from 'htm/preact'
import { useMemo, useState } from 'preact/hooks'
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

export function SyncConflict({ conflicts, onResolve, testId }: SyncConflictProps) {
  const [resolutions, setResolutions] = useState<Record<string, string>>({})

  const resolvedCount = useMemo(
    () => conflicts.filter(c => resolutions[c.field] !== undefined || c.mergedValue !== undefined).length,
    [conflicts, resolutions],
  )

  const setResolution = (field: string, value: string) => {
    setResolutions(prev => ({ ...prev, [field]: value }))
  }

  return html`
    <div
      class="rounded-[var(--r-1)] border border-[var(--error-10)] bg-[var(--color-bg-surface)] p-3"
      data-sync-conflict
      data-testid=${testId}
      role="region"
      aria-label="동기화 충돌"
    >
      <h4 class="mb-2 text-sm font-medium text-[var(--error-10)]">
        동기화 충돌 (${resolvedCount}/${conflicts.length})
      </h4>
      <div role="list" aria-label="충돌 항목 목록">
        ${conflicts.map(
          c => html`
            <div
              key=${c.field}
              class="mb-3 border-b border-[var(--color-border-default)] pb-2 last:mb-0 last:border-b-0 last:pb-0"
              role="listitem"
            >
              <div class="mb-1 font-mono text-3xs text-[var(--color-fg-secondary)]">${c.field}</div>
              <div class="mb-1 grid grid-cols-2 gap-2">
                <div class="rounded-[var(--r-1)] bg-[var(--ok-10)]/10 p-2">
                  <div class="mb-0.5 text-3xs font-medium text-[var(--ok-10)]">로컬</div>
                  <div class="break-all font-mono text-xs text-[var(--color-fg-primary)]">${c.localValue}</div>
                </div>
                <div class="rounded-[var(--r-1)] bg-[var(--error-10)]/10 p-2">
                  <div class="mb-0.5 text-3xs font-medium text-[var(--error-10)]">원격</div>
                  <div class="break-all font-mono text-xs text-[var(--color-fg-primary)]">${c.remoteValue}</div>
                </div>
              </div>
              <div class="mt-1 flex items-center gap-2">
                <span class="text-3xs text-[var(--color-fg-secondary)]">병합:</span>
                <div class="flex-1">
                  <${InlineEdit}
                    value=${resolutions[c.field] ?? c.mergedValue ?? c.localValue}
                    onSave=${(v: string) => setResolution(c.field, v)}
                  />
                </div>
              </div>
            </div>
          `,
        )}
      </div>
      <button
        class="mt-2 w-full rounded-[var(--r-1)] bg-[var(--color-accent)] py-1.5 text-sm text-white transition-colors hover:bg-[var(--accent-11)]"
        onClick=${() => onResolve(resolutions)}
        aria-label="병합 적용"
      >
        병합 적용
      </button>
    </div>
  `
}
