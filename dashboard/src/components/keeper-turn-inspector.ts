// Keeper Turn Inspector (RFC-0233 PR-4) — one row per keeper turn from
// GET /api/v1/keepers/:name/turn-records, with the server-computed
// block diff between consecutive turns of the same trace. Answers the
// operator question "which instruction blocks entered, left, or changed
// between turns" without reading source.

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { fetchKeeperTurnRecords } from '../api/dashboard'
import type {
  MemoryOsEpisodeSummary,
  MemoryOsTurnRecordSnapshot,
  TurnBlock,
  TurnBlockDiff,
  TurnRecordRow,
  TurnRecordsResponse,
  TelemetryFreshnessMetadata,
} from '../api/dashboard'
import { formatTimeHms } from '../lib/format-time'
import { LoadingState } from './common/feedback-state'
import { useManagedAsyncResource } from '../lib/use-managed-async-resource'
import { coverageGapDisplay, sourceHealthClass, freshnessText } from './common/source-health'

function FreshnessLine({ data }: { data: TelemetryFreshnessMetadata }) {
  const gap = coverageGapDisplay(data)
  return html`
    <div class="text-3xs text-[var(--color-fg-disabled)]">
      <span class="font-mono">${data.source ?? '(unknown source)'}</span>
      <span class="mx-1" aria-hidden="true">·</span>
      <span class="font-mono ${sourceHealthClass(data.health)}">${data.health ?? 'unknown'}</span>
      <span class="mx-1" aria-hidden="true">·</span>
      <span>${freshnessText(data)}</span>
      ${gap ? html`<span class="mx-1" aria-hidden="true">·</span><span>${gap}</span>` : null}
    </div>
  `
}

function BlockRow({ block }: { block: TurnBlock }) {
  return html`
    <div class="flex items-center gap-2 text-2xs font-mono">
      <span class="text-[var(--color-fg-default)]">${block.block}</span>
      <span class="text-[var(--color-fg-muted)]">${block.bytes}B</span>
      <span class="text-[var(--color-fg-disabled)]" title=${block.digest}>
        ${block.digest.slice(0, 12)}
      </span>
    </div>
  `
}

function latestMemoryOsBlock(rows: TurnRecordRow[]): TurnBlock | null {
  for (const row of [...rows].reverse()) {
    const block = row.record.blocks.find(item => item.block === 'memory_os_recall')
    if (block) return block
  }
  return null
}

function compactIso(value: string | null): string {
  if (!value) return 'none'
  return value.replace('T', ' ').replace(/Z$/, 'Z')
}

function episodeTtlLabel(episode: MemoryOsEpisodeSummary): string {
  if (!episode.valid_until_iso) return 'no TTL'
  return episode.current
    ? `until ${compactIso(episode.valid_until_iso)}`
    : `expired ${compactIso(episode.valid_until_iso)}`
}

function MemoryOsEpisodeRow({ episode }: { episode: MemoryOsEpisodeSummary }) {
  return html`
    <div class="min-w-0 border-t border-[var(--color-border-muted)] py-2 first:border-t-0">
      <div class="mb-1 flex min-w-0 flex-wrap items-center gap-2">
        <span class="font-mono text-2xs text-[var(--color-fg-default)]">
          ${episode.trace_id} g${episode.generation.toString().padStart(4, '0')}
        </span>
        <span class="text-3xs font-mono ${episode.current ? 'text-[var(--color-status-ok)]' : 'text-[var(--color-status-warn)]'}">
          ${episodeTtlLabel(episode)}
        </span>
        ${episode.terminal_marker
          ? html`<span class="rounded-[var(--r-1)] bg-[var(--accent-12)] px-1.5 py-0.5 text-3xs font-mono text-[var(--color-accent-fg)]">
              terminal=${episode.terminal_marker}
            </span>`
          : null}
        <span class="text-3xs text-[var(--color-fg-disabled)]">${episode.claim_count} claims</span>
      </div>
      <div class="line-clamp-2 text-2xs leading-relaxed text-[var(--color-fg-muted)]">
        ${episode.summary}
      </div>
    </div>
  `
}

function MemoryOsRecallSourcePanel({
  snapshot,
  rows,
}: {
  snapshot: MemoryOsTurnRecordSnapshot
  rows: TurnRecordRow[]
}) {
  const latestBlock = latestMemoryOsBlock(rows)
  const episodes = [...snapshot.episodes.items].reverse().slice(0, 5)
  const readErrorText = snapshot.read_errors.map(item => `${item.scope}: ${item.error}`).join(' · ')

  return html`
    <section
      class="mb-3 border-y border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2 py-3"
      data-testid="memory-os-recall-source"
    >
      <div class="flex min-w-0 flex-wrap items-start gap-3">
        <div class="min-w-0 flex-1">
          <div class="text-xs font-semibold text-[var(--color-fg-primary)]">Memory OS recall</div>
          <div class="mt-0.5 text-3xs text-[var(--color-fg-muted)]">
            ${snapshot.recall_enabled ? 'enabled' : 'disabled'}
            <span class="mx-1" aria-hidden="true">·</span>
            ${latestBlock
              ? html`latest block <span class="font-mono">${latestBlock.bytes}B</span> <span class="font-mono text-[var(--color-fg-disabled)]">${latestBlock.digest.slice(0, 12)}</span>`
              : 'latest block 없음'}
          </div>
        </div>
        <div class="flex flex-wrap gap-2 text-3xs">
          <span class="font-mono text-[var(--color-fg-muted)]">
            ep ${snapshot.episodes.current}/${snapshot.episodes.shown}
          </span>
          <span class="font-mono text-[var(--color-fg-muted)]">
            expired ${snapshot.episodes.expired}
          </span>
          <span class="font-mono text-[var(--color-fg-muted)]">
            terminal ${snapshot.episodes.terminal_markers}
          </span>
          <span class="font-mono text-[var(--color-fg-muted)]">
            facts ${snapshot.facts.current}/${snapshot.facts.shown}
          </span>
        </div>
      </div>

      ${readErrorText
        ? html`<div class="mt-2 text-2xs text-[var(--color-status-err)]">${readErrorText}</div>`
        : null}

      <div class="mt-2 divide-y divide-[var(--color-border-muted)]">
        ${episodes.length === 0
          ? html`<div class="py-2 text-2xs text-[var(--color-fg-disabled)]">recent episodes 없음</div>`
          : episodes.map(episode => html`<${MemoryOsEpisodeRow} key=${`${episode.trace_id}-${episode.generation}-${episode.created_at}`} episode=${episode} />`)}
      </div>

      <details class="mt-2 text-3xs text-[var(--color-fg-disabled)]">
        <summary class="cursor-pointer">stores</summary>
        <div class="mt-1 break-all font-mono">facts: ${snapshot.facts_store}</div>
        <div class="mt-1 break-all font-mono">episodes: ${snapshot.episodes_store}</div>
      </details>
    </section>
  `
}

export function KeeperMemoryOsRecallPanel({ keeperName }: { keeperName: string }) {
  const resource = useManagedAsyncResource<TurnRecordsResponse | null>(null)

  useEffect(() => {
    void resource.load(async (signal) => {
      return await fetchKeeperTurnRecords(keeperName, 12, { signal })
    })
    return () => {
      resource.cancel()
    }
  }, [keeperName, resource])

  const response = resource.state.value.data

  if (resource.state.value.loading) {
    return html`<${LoadingState}>Memory OS recall 불러오는 중...<//>`
  }

  if (resource.state.value.error) {
    return html`<div class="text-xs text-[var(--color-status-err)] p-3" role="alert">${resource.state.value.error}</div>`
  }

  if (!response?.memory_os) {
    return html`
      <div class="p-3 text-xs text-[var(--color-fg-muted)]">
        Memory OS recall source 없음
      </div>
    `
  }

  return html`
    <div class="p-2">
      <${MemoryOsRecallSourcePanel} snapshot=${response.memory_os} rows=${response.entries} />
    </div>
  `
}

function DiffSection({ diff }: { diff: TurnBlockDiff }) {
  const empty =
    diff.added.length === 0 && diff.removed.length === 0 && diff.changed.length === 0
  if (empty) {
    return html`<div class="text-2xs text-[var(--color-fg-disabled)]">이전 턴과 블록 변화 없음</div>`
  }
  return html`
    <div class="space-y-1">
      ${diff.added.map(block => html`
        <div class="flex items-center gap-2 text-2xs font-mono text-[var(--color-status-ok)]">
          <span>+</span>
          <span>${block.block}</span>
          <span class="opacity-70">${block.bytes}B</span>
        </div>
      `)}
      ${diff.removed.map(block => html`
        <div class="flex items-center gap-2 text-2xs font-mono text-[var(--color-status-err)]">
          <span>−</span>
          <span>${block.block}</span>
          <span class="opacity-70">${block.bytes}B</span>
        </div>
      `)}
      ${diff.changed.map(({ prev, next }) => html`
        <div class="flex items-center gap-2 text-2xs font-mono text-[var(--color-status-warn)]">
          <span>Δ</span>
          <span>${next.block}</span>
          <span class="opacity-70">${prev.bytes}B → ${next.bytes}B</span>
          <span class="opacity-50" title="${prev.digest} → ${next.digest}">
            ${prev.digest.slice(0, 8)} → ${next.digest.slice(0, 8)}
          </span>
        </div>
      `)}
    </div>
  `
}

function TurnRow({ row }: { row: TurnRecordRow }) {
  const record = row.record
  const tokens =
    record.input_tokens != null || record.output_tokens != null
      ? `${record.input_tokens ?? '?'}→${record.output_tokens ?? '?'} tok`
      : null
  const sampling = [
    record.temperature != null ? `t=${record.temperature}` : null,
    record.thinking_budget != null ? `think=${record.thinking_budget}` : null,
    record.enable_thinking === false ? 'no-think' : null,
  ].filter(Boolean)

  return html`
    <details class="rounded-[var(--r-1)] hover:bg-[var(--color-bg-surface)] transition-colors">
      <summary class="list-none cursor-pointer flex items-center gap-2 py-1.5 px-2 flex-wrap">
        <span class="text-xs font-mono font-medium text-[var(--color-fg-default)]">
          T${record.absolute_turn}
        </span>
        <span class="text-3xs text-[var(--color-fg-disabled)]">${formatTimeHms(record.ts)}</span>
        <span class="text-3xs font-mono text-[var(--color-fg-muted)]">${record.runtime_profile}</span>
        ${tokens ? html`<span class="text-3xs font-mono text-[var(--color-fg-muted)]">${tokens}</span>` : null}
        ${sampling.length > 0
          ? html`<span class="text-3xs font-mono text-[var(--color-fg-disabled)]">${sampling.join(' ')}</span>`
          : null}
        <span class="text-3xs text-[var(--color-fg-disabled)]">
          블록 ${record.blocks.length} · 도구 ${record.execution_ids.length}
        </span>
        ${row.diff_vs_prev
          && (row.diff_vs_prev.added.length > 0
            || row.diff_vs_prev.removed.length > 0
            || row.diff_vs_prev.changed.length > 0)
          ? html`<span class="text-3xs font-mono text-[var(--color-status-warn)]">
              +${row.diff_vs_prev.added.length} −${row.diff_vs_prev.removed.length} Δ${row.diff_vs_prev.changed.length}
            </span>`
          : null}
      </summary>
      <div class="px-3 pb-2 space-y-2">
        <div>
          <div class="text-3xs uppercase tracking-wider text-[var(--color-fg-disabled)] mb-1">
            컨텍스트 블록 (조립 순서)
          </div>
          ${record.blocks.length === 0
            ? html`<div class="text-2xs text-[var(--color-fg-disabled)]">기록된 블록 없음</div>`
            : record.blocks.map(block => html`<${BlockRow} block=${block} />`)}
        </div>
        <div>
          <div class="text-3xs uppercase tracking-wider text-[var(--color-fg-disabled)] mb-1">
            이전 턴 대비
          </div>
          ${row.diff_vs_prev
            ? html`<${DiffSection} diff=${row.diff_vs_prev} />`
            : html`<div class="text-2xs text-[var(--color-fg-disabled)]">같은 trace의 이전 턴 없음</div>`}
        </div>
        ${record.execution_ids.length > 0
          ? html`
            <div>
              <div class="text-3xs uppercase tracking-wider text-[var(--color-fg-disabled)] mb-1">
                execution_ids
              </div>
              <div class="text-2xs font-mono text-[var(--color-fg-muted)] break-all">
                ${record.execution_ids.join(', ')}
              </div>
            </div>
          `
          : null}
      </div>
    </details>
  `
}

export function KeeperTurnInspector({ keeperName }: { keeperName: string }) {
  const resource = useManagedAsyncResource<TurnRecordsResponse | null>(null)

  useEffect(() => {
    void resource.load(async (signal) => {
      return await fetchKeeperTurnRecords(keeperName, 50, { signal })
    })
    return () => {
      resource.cancel()
    }
  }, [keeperName, resource])

  const response = resource.state.value.data

  if (resource.state.value.loading) {
    return html`<${LoadingState}>턴 레코드 불러오는 중...<//>`
  }

  if (resource.state.value.error) {
    return html`<div class="text-xs text-[var(--color-status-err)] p-4" role="alert">${resource.state.value.error}</div>`
  }

  const rows = response?.entries ?? []
  const memoryOsPanel = response?.memory_os
    ? html`<${MemoryOsRecallSourcePanel} snapshot=${response.memory_os} rows=${rows} />`
    : null

  if (rows.length === 0) {
    return html`
      <div class="p-4 space-y-1">
        ${memoryOsPanel}
        <div class="text-xs text-[var(--color-fg-muted)]">턴 레코드 없음 (서버 재시작 이후 keeper 턴부터 기록됩니다)</div>
        <${FreshnessLine} data=${response ?? { source: 'turn_record' }} />
      </div>
    `
  }

  // Server returns oldest-first; show newest first.
  const sorted = [...rows].reverse()

  return html`
    <div class="p-2 space-y-1">
      <div class="flex items-center justify-between px-1">
        <${FreshnessLine} data=${response} />
        ${response && response.skipped_rows > 0
          ? html`<span class="text-3xs text-[var(--color-status-warn)]">
              malformed ${response.skipped_rows}행 제외됨
            </span>`
          : null}
      </div>
      ${memoryOsPanel}
      ${sorted.map(row => html`<${TurnRow} key=${`${row.record.trace_id}-${row.record.absolute_turn}`} row=${row} />`)}
    </div>
  `
}
