import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { unixSecondsToDate } from '../lib/format-time'
import { ActionButton } from './common/button'
import { requestConfirm } from './common/confirm-dialog'
import {
  deleteKeeperHistorySnapshots,
  fetchKeeperCheckpoints,
  type KeeperCheckpointCurrentError,
  type KeeperCheckpointHistoryError,
  type KeeperCheckpointInventory,
  type KeeperCheckpointSummary,
} from '../api/keeper'
import { TextInput } from './common/input'
import { Checkbox } from './common/checkbox'
import { showToast } from './common/toast'
import { StatusChip, type StatusChipTone } from './common/status-chip'

function SnapshotBadge({ tone, children }: { tone: 'accent' | 'neutral' | 'ok' | 'warn' | 'bad'; children: unknown }) {
  const chipTone: StatusChipTone = tone === 'accent' ? 'info' : tone
  return html`<${StatusChip} tone=${chipTone} uppercase=${false} class="font-semibold">${children}</${StatusChip}>`
}

export function MonoBadge({ children }: { children: unknown }) {
  return html`<${StatusChip} tone="info" uppercase=${false} class="font-mono">${children}</${StatusChip}>`
}

function formatCheckpointTime(timestamp: number): string {
  if (!Number.isFinite(timestamp) || timestamp <= 0) return '-'
  return unixSecondsToDate(timestamp).toLocaleString('ko-KR', {
    hour12: false,
  })
}

/**
 * Pure filter for OAS snapshot history rows.
 *
 * Case-insensitive substring match on `snapshot_id`, `source_kind`, and
 * `latest_preview` so operators can locate a snapshot by partial id, by the
 * preview text that described the turn, or by its source kind
 * (`oas_current` / `oas_history`).
 *
 * Empty/whitespace query returns the input reference unchanged (no new
 * array allocation, preserves referential equality for memoisation).
 *
 * Input is never mutated. Treats `null` fields defensively.
 */
export function filterCheckpointHistory(
  rows: readonly KeeperCheckpointSummary[],
  query: string,
): readonly KeeperCheckpointSummary[] {
  const needle = query.trim().toLowerCase()
  if (needle === '') return rows
  return rows.filter(row => {
    if (row.snapshot_id.toLowerCase().includes(needle)) return true
    if (row.source_kind && row.source_kind.toLowerCase().includes(needle)) return true
    if (row.latest_preview && row.latest_preview.toLowerCase().includes(needle)) return true
    return false
  })
}

function CheckpointSummaryCard({
  title,
  summary,
  status,
  error,
}: {
  title: string
  summary: KeeperCheckpointSummary | null
  status: KeeperCheckpointInventory['current_status']
  error: KeeperCheckpointCurrentError | null
}) {
  if (!summary) {
    if (status === 'unavailable') {
      return html`
        <div
          class="rounded-[var(--r-1)] border border-[var(--bad-30)] bg-[var(--bad-10)] px-3 py-3 text-xs text-[var(--rose-light)] v2-monitoring-card"
          role="alert"
        >
          <div class="flex flex-wrap items-center gap-2">
            <span class="font-semibold">${title}: checkpoint 읽기 실패</span>
            <${SnapshotBadge} tone="bad">${error?.kind ?? 'unknown'}</${SnapshotBadge}>
          </div>
          ${error?.detail
            ? html`<div class="mt-2 break-words font-mono text-2xs">${error.detail}</div>`
            : null}
        </div>
      `
    }
    return html`
      <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-3 text-xs text-[var(--color-fg-muted)] v2-monitoring-card">
        ${title}: 저장된 checkpoint 없음
      </div>
    `
  }

  return html`
    <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-3 v2-monitoring-card">
      <div class="flex flex-wrap items-center gap-2">
        <span class="text-xs font-semibold text-[var(--color-fg-secondary)]">${title}</span>
        <${SnapshotBadge} tone="accent">gen ${summary.generation}</${SnapshotBadge}>
        <${SnapshotBadge} tone="neutral">${summary.message_count} msgs</${SnapshotBadge}>
        ${summary.system_prompt_present
          ? html`<${SnapshotBadge} tone="ok">system kept</${SnapshotBadge}>`
          : null}
      </div>
      <div class="mt-2 text-2xs text-[var(--color-fg-muted)]">
        ${formatCheckpointTime(summary.created_at)}
      </div>
      ${summary.latest_preview
        ? html`<div class="mt-2 text-xs leading-relaxed text-[var(--color-fg-primary)]">${summary.latest_preview}</div>`
        : null}
    </div>
  `
}

function CheckpointHistoryFailures({
  failures,
}: {
  failures: readonly KeeperCheckpointHistoryError[]
}) {
  if (failures.length === 0) return null
  return html`
    <div
      class="rounded-[var(--r-1)] border border-[var(--bad-30)] bg-[var(--bad-10)] px-3 py-3 v2-monitoring-panel"
      role="alert"
    >
      <div class="flex flex-wrap items-center gap-2">
        <span class="text-xs font-semibold text-[var(--rose-light)]">
          읽지 못한 checkpoint history
        </span>
        <${SnapshotBadge} tone="bad">${failures.length}</${SnapshotBadge}>
      </div>
      <div class="mt-2 flex flex-col gap-2">
        ${failures.map(failure => html`
          <div
            class="rounded-[var(--r-1)] border border-[var(--bad-30)] bg-[var(--color-bg-surface)] px-2.5 py-2 text-2xs"
            key=${failure.snapshot_id}
          >
            <div class="flex flex-wrap items-center gap-2">
              <span class="font-mono text-[var(--color-fg-primary)]">${failure.snapshot_id}</span>
              <${SnapshotBadge} tone=${failure.status === 'missing' ? 'warn' : 'bad'}>
                ${failure.error_kind}
              </${SnapshotBadge}>
            </div>
            ${failure.error_detail
              ? html`<div class="mt-1 break-words font-mono text-[var(--rose-light)]">${failure.error_detail}</div>`
              : null}
            <div class="mt-1 break-all font-mono text-[var(--color-fg-muted)]">${failure.path}</div>
          </div>
        `)}
      </div>
    </div>
  `
}

export function KeeperCheckpointPanel({
  keeperName,
  refreshToken,
}: {
  keeperName: string
  refreshToken: number
}) {
  const [inventory, setInventory] = useState<KeeperCheckpointInventory | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [selectedIds, setSelectedIds] = useState<string[]>([])
  const [deleting, setDeleting] = useState(false)
  const [historyQuery, setHistoryQuery] = useState('')

  const loadInventory = () => {
    void (async () => {
      setLoading(true)
      setError(null)
      try {
        const next = await fetchKeeperCheckpoints(keeperName)
        setInventory(next)
        setSelectedIds(prev =>
          prev.filter(id => next.history.some(item => item.snapshot_id === id)),
        )
      } catch (err) {
        setError(err instanceof Error ? err.message : 'checkpoint inventory load failed')
      } finally {
        setLoading(false)
      }
    })()
  }

  useEffect(() => {
    setInventory(null)
    setSelectedIds([])
    loadInventory()
  }, [keeperName, refreshToken])

  const toggleSnapshot = (snapshotId: string, checked: boolean) => {
    setSelectedIds(prev =>
      checked
        ? (prev.includes(snapshotId) ? prev : [...prev, snapshotId])
        : prev.filter(id => id !== snapshotId),
    )
  }

  const deleteSelected = () => {
    void (async () => {
      if (selectedIds.length === 0) {
        showToast('삭제할 snapshot을 먼저 고르세요', 'warning')
        return
      }
      const confirmed = await requestConfirm({
        title: 'OAS snapshot 삭제',
        message: `${selectedIds.length}개 snapshot history를 삭제합니다.\n현재 active checkpoint는 건드리지 않습니다.`,
        tone: 'danger',
        confirmText: '삭제',
      })
      if (!confirmed) return
      setDeleting(true)
      try {
        const result = await deleteKeeperHistorySnapshots(keeperName, selectedIds)
        setInventory(result.inventory)
        setSelectedIds([])
        const missingSuffix =
          result.missing_snapshot_ids.length > 0
            ? ` (누락 ${result.missing_snapshot_ids.length})`
            : ''
        showToast(`${result.deleted_snapshot_ids.length}개 snapshot 삭제${missingSuffix}`, 'success')
      } catch (err) {
        showToast(err instanceof Error ? err.message : 'snapshot 삭제 실패', 'error')
      } finally {
        setDeleting(false)
      }
    })()
  }

  if (loading) {
    return html`
      <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-3 text-xs text-[var(--color-fg-muted)] v2-monitoring-panel" role="status">
        checkpoint inventory 로딩 중...
      </div>
    `
  }

  if (error) {
    return html`
      <div class="rounded-[var(--r-1)] border border-[var(--bad-30)] bg-[var(--bad-10)] px-3 py-3 text-xs text-[var(--rose-light)] v2-monitoring-panel">
        ${error}
        <${ActionButton}
          variant="ghost"
          size="md"
          class="ml-2 !px-2 !py-1"
          onClick=${loadInventory}
        >다시 로드<//>
      </div>
    `
  }

  if (!inventory) {
    return html`
      <div
        class="rounded-[var(--r-1)] border border-[var(--bad-30)] bg-[var(--bad-10)] px-3 py-3 text-xs text-[var(--rose-light)] v2-monitoring-panel"
        role="alert"
      >
        checkpoint inventory 응답이 없습니다.
      </div>
    `
  }

  return html`
    <div class="flex flex-col gap-3 v2-monitoring-panel">
      <div class="flex items-center justify-between gap-3 v2-monitoring-toolbar">
        <div class="text-2xs text-[var(--color-fg-muted)]">
          current OAS checkpoint와 OAS snapshot history만 노출합니다.
        </div>
        <div class="flex items-center gap-2">
          <${ActionButton}
            variant="ghost"
            size="md"
            onClick=${loadInventory}
          >새로고침<//>
          <button
            type="button"
            class="rounded-[var(--r-1)] border border-[var(--bad-30)] bg-[var(--bad-10)] px-3 py-1.5 text-2xs font-semibold text-[var(--rose-light)] hover:bg-[var(--bad-soft)] cursor-pointer disabled:cursor-not-allowed disabled:opacity-50 v2-monitoring-action"
            disabled=${deleting || selectedIds.length === 0}
            onClick=${deleteSelected}
          >${deleting ? '삭제 중...' : `선택 삭제 (${selectedIds.length})`}</button>
        </div>
      </div>

      <${CheckpointSummaryCard}
        title="현재 active checkpoint"
        summary=${inventory.current}
        status=${inventory.current_status}
        error=${inventory.current_error}
      />

      <${CheckpointHistoryFailures} failures=${inventory.history_errors} />

      <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] v2-monitoring-panel">
        <div class="flex flex-wrap items-center justify-between gap-2 border-b border-[var(--color-border-default)] px-3 py-2 v2-monitoring-toolbar">
          <div class="text-2xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">
            OAS Snapshot History
            ${inventory && inventory.history.length > 0 && historyQuery.trim() !== ''
              ? html`<span class="ml-2 text-3xs font-normal normal-case tracking-normal text-[var(--color-fg-disabled)]">${filterCheckpointHistory(inventory.history, historyQuery).length}/${inventory.history.length}</span>`
              : null}
          </div>
          <${TextInput}
            type="search"
            class="min-w-40 max-w-65 flex-1 !px-2 !py-1 !text-2xs"
            value=${historyQuery}
            placeholder="snapshot id / preview / 요약 필터"
            ariaLabel="OAS snapshot history 필터"
            onInput=${(e: Event) => { setHistoryQuery((e.target as HTMLInputElement).value) }}
          />
        </div>
        ${!inventory || inventory.history.length === 0
          ? html`<div class="px-3 py-3 text-xs text-[var(--color-fg-muted)] v2-monitoring-row">저장된 OAS history snapshot이 아직 없습니다.</div>`
          : (() => {
              const visibleHistory = filterCheckpointHistory(inventory.history, historyQuery)
              const isFiltering = historyQuery.trim() !== ''
              if (isFiltering && visibleHistory.length === 0) {
                return html`<div class="px-3 py-4 text-center text-2xs text-[var(--color-fg-disabled)] v2-monitoring-row">필터 결과 없음 (${inventory.history.length} items)</div>`
              }
              return html`
                <div class="flex flex-col">
                  ${visibleHistory.map(item => html`
                    <label class="v2-mobile-operator-target flex gap-3 border-b border-[var(--color-border-default)] px-3 py-3 text-xs last:border-b-0 v2-monitoring-row">
                      <${Checkbox}
                        class="mt-1"
                        checked=${selectedIds.includes(item.snapshot_id)}
                        ariaLabel=${`snapshot ${item.snapshot_id} 선택`}
                        onChange=${(checked: boolean) => toggleSnapshot(item.snapshot_id, checked)}
                      />
                      <div class="min-w-0 flex-1">
                        <div class="flex flex-wrap items-center gap-2">
                          <span class="font-mono text-[var(--color-fg-secondary)]">${item.snapshot_id}</span>
                          <${SnapshotBadge} tone="accent">gen ${item.generation}</${SnapshotBadge}>
                          <${SnapshotBadge} tone="neutral">${item.message_count} msgs</${SnapshotBadge}>
                          ${item.system_prompt_present
                            ? html`<${SnapshotBadge} tone="ok">system kept</${SnapshotBadge}>`
                            : null}
                        </div>
                        <div class="mt-1 text-2xs text-[var(--color-fg-muted)]">
                          ${formatCheckpointTime(item.created_at)}
                          ${item.file_stat?.size_bytes ? html` · ${(item.file_stat.size_bytes / 1024).toFixed(1)} KB` : null}
                        </div>
                        ${item.latest_preview
                          ? html`<div class="mt-2 text-xs leading-relaxed text-[var(--color-fg-primary)]">${item.latest_preview}</div>`
                          : null}
                      </div>
                    </label>
                  `)}
                </div>
              `
            })()}
      </div>
    </div>
  `
}
