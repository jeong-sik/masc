import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { ActionButton } from './common/button'
import { requestConfirm } from './common/confirm-dialog'
import {
  deleteKeeperHistorySnapshots,
  fetchKeeperCheckpoints,
  type KeeperCheckpointInventory,
  type KeeperCheckpointSummary,
} from '../api/keeper'
import { TextInput } from './common/input'
import { Checkbox } from './common/checkbox'
import { TimeAgo } from './common/time-ago'
import { keeperStatusDetails } from '../keeper-state'
import { isRecord } from './common/normalize'
import { showToast } from './common/toast'
import { KeeperDetailSectionCard } from './keeper-detail-layout'

function formatCheckpointTime(timestamp: number): string {
  if (!Number.isFinite(timestamp) || timestamp <= 0) return '-'
  return new Date(timestamp * 1000).toLocaleString('ko-KR', {
    hour12: false,
  })
}

/**
 * Pure filter for OAS snapshot history rows.
 *
 * Case-insensitive substring match on `snapshot_id`, `source_kind`,
 * `latest_preview`, and `continuity_summary` so operators can locate a
 * snapshot by partial id, by the preview/summary text that described the
 * turn, or by its source kind (`oas_current` / `oas_history`).
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
    if (row.continuity_summary && row.continuity_summary.toLowerCase().includes(needle)) return true
    return false
  })
}

function CheckpointSummaryCard({
  title,
  summary,
}: {
  title: string
  summary: KeeperCheckpointSummary | null
}) {
  if (!summary) {
    return html`
      <div class="rounded border border-[var(--color-border-default)] bg-[var(--white-2)] px-3 py-3 text-xs text-[var(--color-fg-muted)]">
        ${title}: 저장된 checkpoint 없음
      </div>
    `
  }

  return html`
    <div class="rounded border border-[var(--color-border-default)] bg-[var(--white-2)] px-3 py-3">
      <div class="flex flex-wrap items-center gap-2">
        <span class="text-xs font-semibold text-[var(--color-fg-secondary)]">${title}</span>
        <span class="inline-flex items-center rounded-sm px-2 py-0.5 text-3xs font-semibold bg-[var(--accent-12)] text-[var(--color-accent-fg)] border border-[var(--accent-18)]">
          gen ${summary.generation}
        </span>
        <span class="inline-flex items-center rounded-sm px-2 py-0.5 text-3xs font-semibold border border-[var(--white-8)] bg-[var(--white-3)] text-[var(--color-fg-muted)]">
          ${summary.message_count} msgs
        </span>
        ${summary.system_prompt_present
          ? html`<span class="inline-flex items-center rounded-sm px-2 py-0.5 text-3xs font-semibold border border-[var(--ok-20)] bg-[var(--ok-10)] text-[var(--color-status-ok)]">system kept</span>`
          : null}
      </div>
      <div class="mt-2 text-2xs text-[var(--color-fg-muted)]">
        ${formatCheckpointTime(summary.created_at)}
      </div>
      ${summary.latest_preview
        ? html`<div class="mt-2 text-xs leading-relaxed text-[var(--color-fg-primary)]">${summary.latest_preview}</div>`
        : null}
      ${summary.continuity_summary
        ? html`<pre class="mt-2 whitespace-pre-wrap rounded border border-[var(--white-8)] bg-[var(--white-3)] px-3 py-2 text-2xs leading-relaxed text-[var(--color-fg-muted)]">${summary.continuity_summary}</pre>`
        : html`<div class="mt-2 text-2xs text-[var(--color-fg-disabled)]">continuity snapshot 없음</div>`}
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
      <div class="rounded border border-[var(--color-border-default)] bg-[var(--white-2)] px-3 py-3 text-xs text-[var(--color-fg-muted)]" role="status">
        checkpoint inventory 로딩 중...
      </div>
    `
  }

  if (error) {
    return html`
      <div class="rounded border border-[var(--bad-30)] bg-[var(--bad-10)] px-3 py-3 text-xs text-[#fda4af]">
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

  return html`
    <div class="flex flex-col gap-3">
      <div class="flex items-center justify-between gap-3">
        <div class="text-2xs text-[var(--color-fg-muted)]">
          current OAS checkpoint와 OAS snapshot history만 노출합니다.
          ${inventory && inventory.legacy_shadow_count > 0
            ? html`<span class="block mt-1 text-[var(--color-status-warn)]">legacy shadow ${inventory.legacy_shadow_count}개는 picker에서 제외됩니다.</span>`
            : null}
        </div>
        <div class="flex items-center gap-2">
          <${ActionButton}
            variant="ghost"
            size="md"
            onClick=${loadInventory}
          >새로고침<//>
          <button
            type="button"
            class="rounded border border-[var(--bad-30)] bg-[var(--bad-10)] px-3 py-1.5 text-2xs font-semibold text-[var(--rose-light)] hover:bg-[var(--bad-soft)] cursor-pointer disabled:cursor-not-allowed disabled:opacity-50"
            disabled=${deleting || selectedIds.length === 0}
            onClick=${deleteSelected}
          >${deleting ? '삭제 중...' : `선택 삭제 (${selectedIds.length})`}</button>
        </div>
      </div>

      <${CheckpointSummaryCard}
        title="현재 active checkpoint"
        summary=${inventory?.current ?? null}
      />

      <div class="rounded border border-[var(--color-border-default)] bg-[var(--white-2)]">
        <div class="flex flex-wrap items-center justify-between gap-2 border-b border-[var(--color-border-default)] px-3 py-2">
          <div class="text-2xs font-semibold uppercase tracking-1 text-[var(--color-fg-muted)]">
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
          ? html`<div class="px-3 py-3 text-xs text-[var(--color-fg-muted)]">저장된 OAS history snapshot이 아직 없습니다.</div>`
          : (() => {
              const visibleHistory = filterCheckpointHistory(inventory.history, historyQuery)
              const isFiltering = historyQuery.trim() !== ''
              if (isFiltering && visibleHistory.length === 0) {
                return html`<div class="px-3 py-4 text-center text-2xs text-[var(--color-fg-disabled)]">필터 결과 없음 (${inventory.history.length} items)</div>`
              }
              return html`
                <div class="flex flex-col">
                  ${visibleHistory.map(item => html`
                    <label class="flex gap-3 border-b border-[var(--color-border-default)] px-3 py-3 text-xs last:border-b-0">
                      <${Checkbox}
                        class="mt-1"
                        checked=${selectedIds.includes(item.snapshot_id)}
                        ariaLabel=${`snapshot ${item.snapshot_id} 선택`}
                        onChange=${(checked: boolean) => toggleSnapshot(item.snapshot_id, checked)}
                      />
                      <div class="min-w-0 flex-1">
                        <div class="flex flex-wrap items-center gap-2">
                          <span class="font-mono text-[var(--color-fg-secondary)]">${item.snapshot_id}</span>
                          <span class="inline-flex items-center rounded-sm px-2 py-0.5 text-3xs font-semibold bg-[var(--accent-12)] text-[var(--color-accent-fg)] border border-[var(--accent-18)]">
                            gen ${item.generation}
                          </span>
                          <span class="inline-flex items-center rounded-sm px-2 py-0.5 text-3xs font-semibold border border-[var(--white-8)] bg-[var(--white-3)] text-[var(--color-fg-muted)]">
                            ${item.message_count} msgs
                          </span>
                          ${item.system_prompt_present
                            ? html`<span class="inline-flex items-center rounded-sm px-2 py-0.5 text-3xs font-semibold border border-[var(--ok-20)] bg-[var(--ok-10)] text-[var(--color-status-ok)]">system kept</span>`
                            : null}
                        </div>
                        <div class="mt-1 text-2xs text-[var(--color-fg-muted)]">
                          ${formatCheckpointTime(item.created_at)}
                          ${item.file_stat?.size_bytes ? html` · ${(item.file_stat.size_bytes / 1024).toFixed(1)} KB` : null}
                        </div>
                        ${item.latest_preview
                          ? html`<div class="mt-2 text-xs leading-relaxed text-[var(--color-fg-primary)]">${item.latest_preview}</div>`
                          : null}
                        ${item.continuity_summary
                          ? html`<pre class="mt-2 whitespace-pre-wrap rounded border border-[var(--white-8)] bg-[var(--white-3)] px-3 py-2 text-2xs leading-relaxed text-[var(--color-fg-muted)]">${item.continuity_summary}</pre>`
                          : html`<div class="mt-2 text-2xs text-[var(--color-fg-disabled)]">continuity snapshot 없음</div>`}
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

interface LineageJudgment {
  verdict: string
  similarity?: number | null
}

interface LineageDelta {
  inherited_fields: string[]
  changed_fields: string[]
  dropped_fields: string[]
}

interface GenerationLineageManifest {
  generation: number
  trace_id: string
  generation_id?: string
  parent_generation?: number | null
  parent_trace_id?: string | null
  created_at?: string
  trigger_reason?: string
  context_ratio?: number
  continuity_judgment?: LineageJudgment
  inheritance_delta?: LineageDelta
}

interface GenerationLineageEntry {
  generation: number
  trace_id: string
  generation_id?: string
  parent_generation?: number | null
  parent_trace_id?: string | null
  created_at?: string
  trigger_reason?: string
  context_ratio?: number
  continuity_verdict?: string
  continuity_similarity?: number | null
  identity_changed_fields?: string[]
  identity_dropped_fields?: string[]
}

interface LineageVerdictMeta {
  badgeLabel: string
  detail: string
}

function isStringArray(value: unknown): value is string[] {
  return Array.isArray(value) && value.every(item => typeof item === 'string')
}

function isLineageJudgment(value: unknown): value is LineageJudgment {
  if (!isRecord(value)) return false
  return typeof value.verdict === 'string'
}

function isLineageDelta(value: unknown): value is LineageDelta {
  if (!isRecord(value)) return false
  return isStringArray(value.inherited_fields)
    && isStringArray(value.changed_fields)
    && isStringArray(value.dropped_fields)
}

function isGenerationLineageManifest(value: unknown): value is GenerationLineageManifest {
  if (!isRecord(value)) return false
  return typeof value.generation === 'number'
    && typeof value.trace_id === 'string'
    && (value.parent_generation == null || typeof value.parent_generation === 'number')
    && (value.parent_trace_id == null || typeof value.parent_trace_id === 'string')
    && (value.created_at == null || typeof value.created_at === 'string')
    && (value.trigger_reason == null || typeof value.trigger_reason === 'string')
    && (value.context_ratio == null || typeof value.context_ratio === 'number')
    && (value.continuity_judgment == null || isLineageJudgment(value.continuity_judgment))
    && (value.inheritance_delta == null || isLineageDelta(value.inheritance_delta))
}

function isGenerationLineageEntry(value: unknown): value is GenerationLineageEntry {
  if (!isRecord(value)) return false
  return typeof value.generation === 'number'
    && typeof value.trace_id === 'string'
    && (value.parent_generation == null || typeof value.parent_generation === 'number')
    && (value.parent_trace_id == null || typeof value.parent_trace_id === 'string')
    && (value.created_at == null || typeof value.created_at === 'string')
    && (value.trigger_reason == null || typeof value.trigger_reason === 'string')
    && (value.context_ratio == null || typeof value.context_ratio === 'number')
    && (value.continuity_verdict == null || typeof value.continuity_verdict === 'string')
    && (value.continuity_similarity == null || typeof value.continuity_similarity === 'number')
    && (value.identity_changed_fields == null || isStringArray(value.identity_changed_fields))
    && (value.identity_dropped_fields == null || isStringArray(value.identity_dropped_fields))
}

function compactTraceId(traceId: string): string {
  return traceId.length > 28
    ? `${traceId.slice(0, 12)}…${traceId.slice(-8)}`
    : traceId
}

function formatLineageRatio(value: number | undefined): string {
  return typeof value === 'number' ? `${(value * 100).toFixed(1)}%` : '-'
}

export function lineageVerdictMeta(verdict: string | undefined): LineageVerdictMeta {
  switch (verdict) {
    case 'verified':
      return {
        badgeLabel: '상태 보존',
        detail: 'keeper 목표, 지침, 저장된 상태 요약이 핸드오프를 통해 전달됐는지 continuity 가 검사합니다.',
      }
    case 'drift_detected':
      return {
        badgeLabel: '드리프트 검토',
        detail: '핸드오프는 완료됐지만 저장된 continuity 요약이 충분히 변경되어 operator 의 검토가 필요합니다.',
      }
    case 'unavailable':
      return {
        badgeLabel: '증거 필요',
        detail: '핸드오프는 완료됐지만 generation 비교에 필요한 continuity 데이터가 충분하지 않습니다.',
      }
    default:
      return {
        badgeLabel: '알 수 없음',
        detail: 'continuity 신호는 존재하지만 본 판정이 아직 operator-facing 설명에 매핑되지 않았습니다.',
      }
  }
}

export function lineageTransitionLabel(parentGeneration: number | null | undefined, generation: number): string {
  return `${parentGeneration != null ? `gen ${parentGeneration}` : 'root'} -> gen ${generation}`
}

function verdictBadgeClass(verdict: string | undefined): string {
  switch (verdict) {
    case 'verified':
      return 'bg-[var(--ok-10)] text-[var(--color-status-ok)] border border-[var(--ok-20)]'
    case 'drift_detected':
      return 'bg-[var(--warn-10)] text-[var(--color-status-warn)] border border-[var(--warn-20)]'
    case 'unavailable':
      return 'bg-[var(--white-5)] text-[var(--color-fg-muted)] border border-[var(--white-8)]'
    default:
      return 'bg-[var(--white-5)] text-[var(--color-fg-muted)] border border-[var(--white-8)]'
  }
}

export function GenerationLineagePanel({ keeperName }: { keeperName: string }) {
  const detail = keeperStatusDetails.value[keeperName]
  if (!detail?.rawStatus) return null
  const raw = detail.rawStatus
  if (!isRecord(raw) || !isRecord(raw.generation_lineage)) return null

  const lineage = raw.generation_lineage
  const currentGeneration = typeof lineage.current_generation === 'number' ? lineage.current_generation : null
  const currentTraceId = typeof lineage.current_trace_id === 'string' ? lineage.current_trace_id : null
  const generationId = typeof lineage.generation_id === 'string' ? lineage.generation_id : null
  const traceHistoryCount = typeof lineage.trace_history_count === 'number' ? lineage.trace_history_count : 0
  const manifestPath = typeof lineage.manifest_path === 'string' ? lineage.manifest_path : null
  const indexPath = typeof lineage.index_path === 'string' ? lineage.index_path : null
  const manifest = isGenerationLineageManifest(lineage.manifest) ? lineage.manifest : null
  const recent = (Array.isArray(lineage.recent) ? lineage.recent : []).filter(isGenerationLineageEntry)

  if (currentGeneration == null && currentTraceId == null && recent.length === 0) return null

  const delta = manifest?.inheritance_delta ?? null
  const continuity = manifest?.continuity_judgment
  const continuityMeta = lineageVerdictMeta(continuity?.verdict)
  const latestEntry = recent[0] ?? null
  const latestEntryMeta = latestEntry ? lineageVerdictMeta(latestEntry.continuity_verdict) : null

  return html`
    <div class="md:col-span-2">
      <${KeeperDetailSectionCard} title="생성 계보">
        <div class="text-2xs text-[var(--color-fg-muted)] mb-3">
          Track keeper state transfer across successful handoffs. Lineage telemetry is append-only, shows the latest rollover first, and helps explain whether the same keeper identity carried into the new trace.
        </div>

        ${latestEntry
          ? html`
            <div class="rounded border border-[var(--accent-20)] bg-[var(--accent-8)] p-3 mb-3">
              <div class="flex flex-wrap items-center gap-2 mb-1">
                <span class="text-3xs font-semibold uppercase tracking-wider text-[var(--color-accent-fg)]">최신 핸드오프</span>
                <span class="text-3xs font-mono px-1.5 py-0.5 rounded bg-[var(--accent-12)] text-[var(--color-accent-fg)] border border-[var(--accent-15)]">
                  ${lineageTransitionLabel(latestEntry.parent_generation, latestEntry.generation)}
                </span>
                <span class="text-3xs px-1.5 py-0.5 rounded ${verdictBadgeClass(latestEntry.continuity_verdict)}">
                  ${latestEntryMeta?.badgeLabel}
                </span>
                ${latestEntry.created_at
                  ? html`<span class="text-3xs text-[var(--color-fg-disabled)]">recorded <${TimeAgo} timestamp=${latestEntry.created_at} /></span>`
                  : null}
              </div>
              <div class="text-2xs text-[var(--color-fg-primary)]">
                ${latestEntry.trigger_reason ? `trigger ${latestEntry.trigger_reason} · ` : ''}context ratio ${formatLineageRatio(latestEntry.context_ratio)}
              </div>
              <div class="mt-1 text-2xs text-[var(--color-fg-disabled)]">
                ${latestEntryMeta?.detail}
              </div>
            </div>
          `
          : null}

        <div class="grid grid-cols-1 sm:grid-cols-3 gap-2 mb-3">
          <div class="px-3 py-2 rounded border border-[var(--white-8)] bg-[var(--white-2)]">
            <div class="text-3xs font-semibold uppercase tracking-wider text-[var(--color-fg-muted)]">현재 세대</div>
            <div class="mt-1 text-lg font-semibold text-[var(--color-fg-secondary)]">${currentGeneration ?? '-'}</div>
            ${generationId ? html`<div class="text-3xs text-[var(--color-fg-disabled)] font-mono truncate" title=${generationId}>${generationId}</div>` : null}
          </div>
          <div class="px-3 py-2 rounded border border-[var(--white-8)] bg-[var(--white-2)]">
            <div class="text-3xs font-semibold uppercase tracking-wider text-[var(--color-fg-muted)]">추적 계보</div>
            <div class="mt-1 text-lg font-semibold text-[var(--color-fg-secondary)]">${traceHistoryCount}</div>
            <div class="text-3xs text-[var(--color-fg-disabled)]">historical traces retained in meta.trace_history</div>
          </div>
          <div class="px-3 py-2 rounded border border-[var(--white-8)] bg-[var(--white-2)]">
            <div class="text-3xs font-semibold uppercase tracking-wider text-[var(--color-fg-muted)]">현재 추적</div>
            <div class="mt-1 text-sm font-mono text-[var(--color-fg-secondary)] truncate" title=${currentTraceId ?? ''}>${currentTraceId ? compactTraceId(currentTraceId) : '-'}</div>
            <div class="text-3xs text-[var(--color-fg-disabled)]">artifact appears after the first successful handoff</div>
          </div>
        </div>

        ${manifest
          ? html`
            <div class="rounded border border-[var(--white-8)] bg-[var(--white-2)] p-3 mb-3">
              <div class="flex flex-wrap items-center gap-2 mb-2">
                <span class="text-3xs font-semibold uppercase tracking-wider text-[var(--color-fg-muted)]">현재 매니페스트</span>
                <span class="text-3xs font-mono px-1.5 py-0.5 rounded bg-[var(--accent-12)] text-[var(--color-accent-fg)] border border-[var(--accent-15)]">gen ${manifest.generation}</span>
                ${continuity?.verdict
                  ? html`<span class="text-3xs px-1.5 py-0.5 rounded ${verdictBadgeClass(continuity.verdict)}">${continuityMeta.badgeLabel}</span>`
                  : null}
                ${manifest.created_at
                  ? html`<span class="text-3xs text-[var(--color-fg-disabled)]">created <${TimeAgo} timestamp=${manifest.created_at} /></span>`
                  : null}
              </div>
              <div class="grid grid-cols-1 sm:grid-cols-2 gap-2 text-2xs">
                <div class="rounded border border-[var(--white-8)] bg-[var(--white-2)] px-3 py-2">
                  <div class="text-3xs text-[var(--color-fg-muted)] uppercase tracking-wider mb-1">부모</div>
                  <div class="text-[var(--color-fg-secondary)]">${manifest.parent_generation != null ? `gen ${manifest.parent_generation}` : 'root generation'}</div>
                  ${manifest.parent_trace_id
                    ? html`<div class="font-mono text-[var(--color-fg-disabled)] truncate" title=${manifest.parent_trace_id}>${compactTraceId(manifest.parent_trace_id)}</div>`
                    : null}
                </div>
                <div class="rounded border border-[var(--white-8)] bg-[var(--white-2)] px-3 py-2">
                  <div class="text-3xs text-[var(--color-fg-muted)] uppercase tracking-wider mb-1">트리거</div>
                  <div class="text-[var(--color-fg-secondary)]">${manifest.trigger_reason ?? '-'}</div>
                  <div class="text-[var(--color-fg-disabled)]">context ratio ${formatLineageRatio(manifest.context_ratio)}</div>
                </div>
              </div>
              <div class="mt-3 flex flex-wrap gap-2">
                ${delta
                  ? html`
                    <span class="text-3xs px-2 py-1 rounded border border-[var(--white-8)] bg-[var(--white-2)] text-[var(--color-fg-muted)]">
                      inherited ${delta.inherited_fields.length}
                    </span>
                    <span class="text-3xs px-2 py-1 rounded border border-[var(--white-8)] bg-[var(--white-2)] text-[var(--color-fg-muted)]">
                      changed ${delta.changed_fields.length}
                    </span>
                    <span class="text-3xs px-2 py-1 rounded border border-[var(--white-8)] bg-[var(--white-2)] text-[var(--color-fg-muted)]">
                      dropped ${delta.dropped_fields.length}
                    </span>
                  `
                  : null}
                ${continuity?.similarity != null
                  ? html`<span class="text-3xs px-2 py-1 rounded border border-[var(--white-8)] bg-[var(--white-2)] text-[var(--color-fg-muted)]">similarity ${(continuity.similarity * 100).toFixed(1)}%</span>`
                  : null}
              </div>
              ${continuity?.verdict
                ? html`<div class="mt-2 text-2xs text-[var(--color-fg-disabled)]">${continuityMeta.detail}</div>`
                : null}
              ${delta && delta.changed_fields.length === 0 && delta.dropped_fields.length === 0
                ? html`<div class="mt-2 text-2xs text-[var(--color-fg-disabled)]">identity-only inheritance stayed intact across the rollover.</div>`
                : null}
            </div>
          `
          : html`
            <div class="rounded border border-[var(--white-8)] bg-[var(--white-2)] p-3 mb-3 text-2xs text-[var(--color-fg-muted)]">
              아직 handoff lineage manifest가 없습니다. generation 0에서는 현재 trace만 유지되고, 첫 successful handoff 이후부터 manifest/index가 생깁니다.
            </div>
          `}

        <div>
          <div class="text-3xs font-semibold uppercase tracking-wider text-[var(--color-fg-muted)] mb-1">최근 핸드오프</div>
          <div class="text-2xs text-[var(--color-fg-disabled)] mb-2">Latest recorded rollover appears first so operators can compare the current trace against recent history.</div>
          ${recent.length > 0
            ? html`
              <div class="flex flex-col gap-2">
                ${recent.map((entry, index) => {
                  const isLatest = index === 0
                  const entryMeta = lineageVerdictMeta(entry.continuity_verdict)
                  return html`
                    <div class=${`px-3 py-2 rounded border ${isLatest ? 'border-[var(--accent-22)] bg-[var(--accent-8)]' : 'border-[var(--white-8)] bg-[var(--white-2)]'}`}>
                      <div class="flex flex-wrap items-center gap-2">
                        <span class="text-3xs font-mono px-1.5 py-0.5 rounded bg-[var(--accent-12)] text-[var(--color-accent-fg)] border border-[var(--accent-15)]">gen ${entry.generation}</span>
                        ${isLatest
                          ? html`<span class="text-3xs px-1.5 py-0.5 rounded border border-[var(--accent-18)] bg-[var(--accent-12)] text-[var(--color-accent-fg)]">latest</span>`
                          : null}
                        ${entry.continuity_verdict
                          ? html`<span class="text-3xs px-1.5 py-0.5 rounded ${verdictBadgeClass(entry.continuity_verdict)}">${entryMeta.badgeLabel}</span>`
                          : null}
                        ${entry.created_at
                          ? html`<span class="text-3xs text-[var(--color-fg-disabled)]"><${TimeAgo} timestamp=${entry.created_at} /></span>`
                          : null}
                      </div>
                      <div class="mt-1 text-2xs text-[var(--color-fg-primary)]">
                        ${lineageTransitionLabel(entry.parent_generation, entry.generation)}
                        ${entry.trigger_reason ? ` · ${entry.trigger_reason}` : ''}
                        ${entry.context_ratio != null ? ` · ratio ${formatLineageRatio(entry.context_ratio)}` : ''}
                      </div>
                      <div class="mt-1 text-3xs font-mono text-[var(--color-fg-disabled)] truncate" title=${entry.trace_id}>
                        ${compactTraceId(entry.trace_id)}
                      </div>
                      ${entry.continuity_verdict
                        ? html`<div class="mt-1 text-3xs text-[var(--color-fg-disabled)]">${entryMeta.detail}</div>`
                        : null}
                      ${(entry.identity_changed_fields?.length ?? 0) > 0 || (entry.identity_dropped_fields?.length ?? 0) > 0
                        ? html`
                          <div class="mt-1 text-3xs text-[var(--color-fg-disabled)]">
                            ${entry.identity_changed_fields && entry.identity_changed_fields.length > 0 ? `changed: ${entry.identity_changed_fields.join(', ')}` : ''}
                            ${entry.identity_changed_fields && entry.identity_changed_fields.length > 0 && entry.identity_dropped_fields && entry.identity_dropped_fields.length > 0 ? ' · ' : ''}
                            ${entry.identity_dropped_fields && entry.identity_dropped_fields.length > 0 ? `dropped: ${entry.identity_dropped_fields.join(', ')}` : ''}
                          </div>
                        `
                        : null}
                    </div>
                  `
                })}
              </div>
            `
            : html`<div class="text-2xs text-[var(--color-fg-muted)]">기록된 핸드오프 항목이 아직 없습니다.</div>`}
        </div>

        ${manifestPath || indexPath
          ? html`
            <div class="mt-3 flex flex-col gap-1 text-3xs text-[var(--color-fg-disabled)]">
              ${manifestPath ? html`<div class="font-mono truncate" title=${manifestPath}>manifest ${manifestPath}</div>` : null}
              ${indexPath ? html`<div class="font-mono truncate" title=${indexPath}>index ${indexPath}</div>` : null}
            </div>
          `
          : null}
      <//>
    </div>
  `
}
