import { html } from 'htm/preact'
import { useCallback, useEffect, useMemo, useRef, useState } from 'preact/hooks'
import {
  fetchExactLaneRun,
  fetchExactLaneRuns,
  fetchFusionRuns,
  fetchVerificationRuns,
  type ExactLaneRunRecord,
  type ExactLaneRunSummary,
  type FusionRunRecord,
  type VerificationRunRecord,
} from '../api/dashboard'
import {
  fetchKeeperMemoryJournal,
  type MemoryJournal,
  type MemoryJournalEntry,
} from '../api/dashboard-memory-journal'
import { KeeperTurnInspectorPanel } from './keeper-turn-inspector-panel'
import { ApiRequestError } from '../api/core'
import { registerInternalAgentRefresh } from '../sse-store'
import { Btn } from './btn'
import { EmptyState, ErrorState } from './common/feedback-state'
import { StatusBadge, type StatusBadgeTone } from './common/status-badge'
import { JsonViewerCard } from './common/json-viewer'
import { formatDateTimeKo, relativeTime } from '../lib/format-time'
import { hashForRoute } from '../router'
import { keepers as keeperRosterSignal, shellRuntimeResolution } from '../store'

type Filter =
  | 'all'
  | 'librarian'
  | 'auto-judge'
  | 'board-attention'
  | 'compaction'
  | 'verification'
  | 'fusion'
type Row =
  | { source: 'exact'; id: string; run: ExactLaneRunSummary }
  | { source: 'verification'; id: string; run: VerificationRunRecord }
  | { source: 'fusion'; id: string; run: FusionRunRecord }
type CommittedMemoryJournalEntry = Extract<MemoryJournalEntry, { ok: true; outcome: 'committed' }>
type FailedMemoryJournalEntry = Extract<MemoryJournalEntry, { ok: true; outcome: 'failed' }>

function isForbidden(reason: unknown): boolean {
  return reason instanceof ApiRequestError
    ? reason.status === 403
    : typeof reason === 'object'
      && reason !== null
      && 'status' in reason
      && reason.status === 403
}

const FILTERS: Array<{ id: Filter; label: string }> = [
  { id: 'all', label: 'All' },
  { id: 'librarian', label: 'Librarian' },
  { id: 'auto-judge', label: 'Auto Judge' },
  { id: 'board-attention', label: 'Board Attention' },
  { id: 'compaction', label: 'Compaction' },
  { id: 'verification', label: 'Verification' },
  { id: 'fusion', label: 'Fusion' },
]

function laneLabel(row: Row): string {
  if (row.source === 'verification') return 'Verification'
  if (row.source === 'fusion') return 'Fusion'
  switch (row.run.lane) {
    case 'librarian_exact': return 'Librarian'
    case 'hitl_auto_judge': return 'Auto Judge'
    case 'board_attention_exact': return 'Board Attention'
    case 'compaction_exact': return 'Compaction'
  }
}

function status(row: Row): string {
  return row.run.status
}

function tone(row: Row): StatusBadgeTone {
  const value = status(row)
  if (value === 'succeeded' || value === 'completed' || value === 'approved') return 'ok'
  if (value === 'running') return 'warn'
  if (value === 'rejected') return 'info'
  return 'bad'
}

function actor(row: Row): string {
  if (row.source === 'verification') return row.run.evaluatorRuntime ?? row.run.authorityActor
  if (row.source === 'fusion') return row.run.keeper
  return row.run.actor
}

function subject(row: Row): string {
  if (row.source === 'verification') return row.run.taskId
  if (row.source === 'fusion') return row.run.runId
  return row.run.subjectId
}

function startedAt(row: Row): number {
  return row.run.startedAt
}

function elapsed(row: Row): number | undefined {
  return row.source === 'fusion' ? undefined : row.run.elapsedSeconds
}

function formatElapsed(value: number | undefined): string {
  if (value == null) return '—'
  return value < 1 ? `${Math.round(value * 1000)}ms` : `${value.toFixed(1)}s`
}

function finishedAt(row: Row): number | undefined {
  const duration = elapsed(row)
  return duration == null ? undefined : startedAt(row) + duration
}

function rowKind(row: Row): Exclude<Filter, 'all'> {
  if (row.source === 'verification') return 'verification'
  if (row.source === 'fusion') return 'fusion'
  switch (row.run.lane) {
    case 'librarian_exact': return 'librarian'
    case 'hitl_auto_judge': return 'auto-judge'
    case 'board_attention_exact': return 'board-attention'
    case 'compaction_exact': return 'compaction'
    default: {
      const unreachable: never = row.run.lane
      return unreachable
    }
  }
}

function EvidenceBadge({ kind }: { kind: 'raw' | 'typed' | 'excerpt' }) {
  const style = kind === 'raw'
    ? 'border-[var(--status-warn)] text-[var(--status-warn)]'
    : kind === 'excerpt'
      ? 'border-[var(--color-danger)] text-[var(--color-danger)]'
      : 'border-[var(--color-accent)] text-[var(--color-accent)]'
  return html`<span class=${`inline-flex rounded border px-1.5 py-0.5 text-3xs font-semibold uppercase tracking-wide ${style}`}>${kind}</span>`
}

function keeperHref(name: string): string {
  return hashForRoute('monitoring', { section: 'agents', view: 'keepers', keeper: name })
}

function fusionHref(): string {
  return hashForRoute('fusion')
}

function librarianRevision(value: unknown): number | undefined {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return undefined
  const after = (value as Record<string, unknown>).after
  if (after === null || typeof after !== 'object' || Array.isArray(after)) return undefined
  const revision = (after as Record<string, unknown>).revision
  return typeof revision === 'number' && Number.isFinite(revision) ? revision : undefined
}

function librarianMemoryEvidence(value: unknown): { before: unknown; after: unknown } | null {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return null
  const fields = value as Record<string, unknown>
  if (!('before' in fields) || !('after' in fields)) return null
  return { before: fields.before, after: fields.after }
}

function LibrarianJournal({
  keeper,
  traceId,
  revision,
}: {
  keeper: string
  traceId: string
  revision?: number
}) {
  const [journal, setJournal] = useState<MemoryJournal | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    const controller = new AbortController()
    fetchKeeperMemoryJournal(keeper, 500, { signal: controller.signal })
      .then(setJournal)
      .catch((reason: unknown) => {
        if (controller.signal.aborted) return
        setError(isForbidden(reason)
          ? 'Admin 권한이 있어야 Memory before/after journal을 읽을 수 있습니다.'
          : reason instanceof Error ? reason.message : String(reason))
      })
    return () => controller.abort()
  }, [keeper])

  if (error !== null) {
    return html`<p class="text-xs text-[var(--color-danger)]">기억 저널을 읽지 못했습니다: ${error}</p>`
  }
  if (journal === null) {
    return html`<p class="text-xs text-[var(--color-fg-muted)]">기억 저널 읽는 중…</p>`
  }
  if (journal.entries.length === 0) {
    return html`
      <div class="rounded-[var(--r-1)] border border-[var(--status-warn)] bg-[var(--color-bg-elevated)] p-3 text-xs">
        <div class="flex items-center gap-2"><${EvidenceBadge} kind="typed" /><strong>Memory journal evidence 없음</strong></div>
        <p class="mt-1 text-[var(--color-fg-muted)]">이 실행의 revision 요약은 run registry에 있지만, 메모리 변경 원문을 담는 journal 행은 반환되지 않았습니다.</p>
      </div>
    `
  }

  const related = journal.entries.filter((entry): entry is CommittedMemoryJournalEntry =>
    entry.ok
    && entry.outcome === 'committed'
    && entry.traceId === traceId
    && entry.sourceKind === 'librarian'
    && revision != null
    && entry.revision === revision,
  )
  const traceOnlyCommits = journal.entries.filter((entry): entry is CommittedMemoryJournalEntry =>
    entry.ok
    && entry.outcome === 'committed'
    && entry.traceId === traceId
    && !related.includes(entry),
  )
  const traceOnlyFailures = journal.entries.filter((entry): entry is FailedMemoryJournalEntry =>
    entry.ok
    && entry.outcome === 'failed'
    && entry.traceId === traceId,
  )

  return html`
    <div class="grid gap-2">
      <div class="flex flex-wrap items-center gap-2 text-3xs uppercase tracking-wide text-[var(--color-fg-muted)]">
        <${EvidenceBadge} kind="typed" />
        <span>Memory journal · trace ${traceId}${revision == null ? '' : ` · revision ${revision}`}</span>
        ${journal.undecodableLines > 0
          ? html`<span class="text-[var(--color-danger)]"> · 읽지 못한 줄 ${journal.undecodableLines}</span>`
          : null}
      </div>
      <p class="text-xs text-[var(--color-fg-muted)]">정규화된 commit journal — RAW 원문은 Turn inspector에서</p>
      ${related.length === 0
        ? html`<p class="rounded border border-[var(--color-border-default)] p-3 text-xs text-[var(--color-fg-muted)]">정확히 조인되는 journal 행이 없습니다. trace만 같거나 시간상 가까운 행을 추정해서 붙이지 않았습니다.</p>`
        : null}
      <ol class="grid gap-1">
        ${related.map((entry, index) => {
          return html`<li key=${index} class="grid gap-3 rounded border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3 text-3xs">
            <div class="flex flex-wrap items-center gap-2">
              <code>${entry.sourceKind}</code>
              <strong>revision ${entry.revision}</strong>
              <time class="text-[var(--color-fg-muted)]" dateTime=${new Date(entry.recordedAt * 1000).toISOString()}>${formatDateTimeKo(entry.recordedAt)}</time>
              <span class="text-[var(--color-fg-muted)]">
                추가 ${entry.added.length} · 제거 ${entry.removed.length} · 유지 ${entry.retained}
              </span>
            </div>
            <div class="grid gap-3 lg:grid-cols-2">
              <${JsonViewerCard} title=${`추가된 기억 ${entry.added.length}건`} data=${entry.added} />
              <${JsonViewerCard} title=${`제거된 기억 ${entry.removed.length}건`} data=${entry.removed} />
            </div>
            <${JsonViewerCard} title=${`제거 판단 ${entry.drops.length}건`} data=${entry.drops} />
          </li>`
        })}
      </ol>
      ${traceOnlyCommits.length === 0 && traceOnlyFailures.length === 0
        ? null
        : html`<div class="grid gap-2 rounded border border-[var(--status-warn)] bg-[var(--color-bg-elevated)] p-3">
            <div class="flex flex-wrap items-center gap-2 text-xs">
              <${EvidenceBadge} kind="typed" />
              <strong>같은 trace · exact join 아님</strong>
            </div>
            <p class="text-xs text-[var(--color-fg-muted)]">trace만 일치 — 이 pass의 산출물로 보장되지 않음</p>
            <ol class="grid gap-2">
              ${traceOnlyCommits.map((entry, index) => html`
                <li key=${index} class="grid gap-2 rounded border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3 text-3xs">
                  <div class="flex flex-wrap items-center gap-2">
                    <code>${entry.sourceKind}</code>
                    <strong>revision ${entry.revision}</strong>
                    <time class="text-[var(--color-fg-muted)]" dateTime=${new Date(entry.recordedAt * 1000).toISOString()}>${formatDateTimeKo(entry.recordedAt)}</time>
                    <span class="text-[var(--color-fg-muted)]">추가 ${entry.added.length} · 제거 ${entry.removed.length} · 유지 ${entry.retained}</span>
                  </div>
                  <div class="grid gap-2 lg:grid-cols-2">
                    <${JsonViewerCard} title=${`별도 producer 추가 ${entry.added.length}건`} data=${entry.added} />
                    <${JsonViewerCard} title=${`별도 producer 제거 ${entry.removed.length}건`} data=${entry.removed} />
                  </div>
                </li>
              `)}
              ${traceOnlyFailures.map((entry, index) => html`
                <li key=${`failure-${index}`} class="rounded border border-[var(--color-danger)] p-2 text-3xs">
                  <div class="flex flex-wrap gap-2">
                    <code>librarian_failure</code>
                    <strong class="text-[var(--color-danger)]">${entry.kind}</strong>
                    <time dateTime=${new Date(entry.recordedAt * 1000).toISOString()}>${formatDateTimeKo(entry.recordedAt)}</time>
                    <span class="text-[var(--color-fg-muted)]">스냅샷 ${entry.snapshotPresent ? '있음' : '없음'}${entry.cadenceDeferred ? ' · 주기 연기' : ''}</span>
                  </div>
                  <span class="mt-1 block text-[var(--color-fg-muted)]">${entry.detail}</span>
                </li>
              `)}
            </ol>
          </div>`}
    </div>
  `
}

// The listing carries no payloads, so opening a row is what fetches them. The
// alternative — shipping every run's input and output with the list — is what
// made this panel download 246 MB before it could draw a single line.
function ExactRunDetail({ runId }: { runId: string }) {
  const [run, setRun] = useState<ExactLaneRunRecord | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    const controller = new AbortController()
    setRun(null)
    setError(null)
    fetchExactLaneRun(runId, { signal: controller.signal })
      .then(setRun)
      .catch((cause: unknown) => {
        if (controller.signal.aborted) return
        setError(String(cause))
      })
    return () => controller.abort()
  }, [runId])

  if (error !== null) {
    return html`
      <div class="grid gap-2 p-3 bg-[var(--color-bg-surface)] border-t border-[var(--color-border-default)] text-xs">
        <p class="text-[var(--color-danger)]">이 실행의 typed 값을 읽지 못했습니다: ${error}</p>
      </div>
    `
  }
  if (run === null) {
    return html`
      <div class="grid gap-2 p-3 bg-[var(--color-bg-surface)] border-t border-[var(--color-border-default)] text-xs">
        <p class="text-[var(--color-fg-muted)]">typed 입출력을 불러오는 중…</p>
      </div>
    `
  }
    const output = run.output ?? { code: run.code, detail: run.detail }
    const memoryEvidence = run.lane === 'librarian_exact'
      ? librarianMemoryEvidence(run.output)
      : null
    return html`
      <div class="grid gap-3 p-3 bg-[var(--color-bg-surface)] border-t border-[var(--color-border-default)]">
        <div class="flex flex-wrap items-center gap-2 text-xs">
          <${EvidenceBadge} kind="typed" />
          <strong>Exact-output registry metadata</strong>
          <span class="text-[var(--color-fg-muted)]">Admin-only 실제 typed 값 · Librarian exact에는 research RAW 입력 없음</span>
          ${run.selectedSlot === undefined
            ? null
            : html`<span class="text-[var(--color-fg-muted)]">선택 slot <code>${run.selectedSlot ?? '미기록'}</code></span>`}
          <a class="ml-auto text-[var(--color-accent)] hover:underline" href=${keeperHref(run.actor)}>Keeper 전체 evidence 열기 →</a>
        </div>
        <div class="grid gap-3 lg:grid-cols-2">
          <${JsonViewerCard} title="실제 입력 · typed" data=${run.input.payload} expandAll=${true} />
          <${JsonViewerCard} title="실제 출력 · typed" data=${output} expandAll=${true} />
        </div>
        ${run.persistenceError === undefined
          ? null
          : html`<p class="text-xs text-[var(--color-danger)]">완료 의도 <code>${run.intendedStatus}</code> · persistence <code>${run.persistenceState}</code>: ${run.persistenceError}${run.intendedCode ? ` · ${run.intendedCode}: ${run.intendedDetail}` : ''}</p>`}
        <p class="text-xs text-[var(--color-fg-muted)]"><span class="mr-2 inline-flex rounded border border-[var(--color-accent)] px-1.5 py-0.5 text-3xs font-semibold uppercase tracking-wide text-[var(--color-accent)]">TOOL-FREE</span>이 exact 실행은 immutable Librarian input만 사용하며 외부 research/RAW 입력을 받지 않습니다.</p>
        ${memoryEvidence === null
          ? null
          : html`<div class="grid gap-2 border-t border-[var(--color-border-default)] pt-3">
              <div class="flex items-center gap-2 text-xs"><${EvidenceBadge} kind="typed" /><strong>Memory before → after</strong><span class="text-[var(--color-fg-muted)]">registry에는 count/revision만, 실제 추가·제거는 아래 journal</span></div>
              <div class="grid gap-3 lg:grid-cols-2">
                <${JsonViewerCard} title="Before memory · typed" data=${memoryEvidence.before} expandAll=${true} />
                <${JsonViewerCard} title="After memory + change · typed" data=${memoryEvidence.after} expandAll=${true} />
              </div>
            </div>`}
        ${run.lane === 'librarian_exact'
          ? html`<div class="border-t border-[var(--color-border-default)] pt-3">
              <${LibrarianJournal}
                keeper=${run.actor}
                traceId=${run.subjectId}
                revision=${librarianRevision(run.output)}
              />
            </div>`
          : null}
      </div>
    `
}

function Details({ row }: { row: Row }) {
  if (row.source === 'verification') {
    const tools = row.run.tools ?? []
    return html`
      <div class="grid gap-3 p-3 bg-[var(--color-bg-surface)] border-t border-[var(--color-border-default)]">
        <div class="grid gap-2 rounded-[var(--r-1)] border border-[var(--color-border-default)] p-3">
          <div class="flex flex-wrap items-center gap-2"><${EvidenceBadge} kind="typed" /><strong class="text-xs">Execution path</strong></div>
          <div class="flex flex-wrap items-center gap-2 text-xs">
            <code>${row.run.producer}</code><span aria-hidden="true">→</span>
            <code>${row.run.authorityKind}</code><span aria-hidden="true">→</span>
            <code>${row.run.authorityActor}</code><span aria-hidden="true">→</span>
            <strong>${row.run.status}</strong>
          </div>
          <div class="flex flex-wrap gap-3 text-3xs text-[var(--color-fg-muted)]">
            <span>시작 <time dateTime=${new Date(row.run.startedAt * 1000).toISOString()}>${formatDateTimeKo(row.run.startedAt)}</time></span>
            ${finishedAt(row) == null ? null : html`<span>종료 <time dateTime=${new Date(finishedAt(row)! * 1000).toISOString()}>${formatDateTimeKo(finishedAt(row)!)}</time></span>`}
            ${row.run.evaluatorRuntime ? html`<span>runtime <code>${row.run.evaluatorRuntime}</code></span>` : null}
          </div>
          ${row.run.cause ? html`<p class="text-xs text-[var(--color-danger)]">${row.run.gate ? `${row.run.gate}: ` : ''}${row.run.cause}</p>` : null}
          <p class="text-3xs text-[var(--color-fg-muted)]">Review 원문은 저장되지 않음 · 출력은 1,024B excerpt</p>
        </div>
        <div>
          <div class="text-3xs uppercase tracking-wide text-[var(--color-fg-muted)] mb-1">Internal tool agents (${tools.length})</div>
          ${tools.length === 0
            ? html`<p class="text-xs text-[var(--color-fg-muted)]">No tools invoked in this verification run.</p>`
            : html`<ol class="grid gap-2">
                ${tools.map((tool, index) => html`
                  <li key=${`${row.id}-${index}`} class="rounded border border-[var(--color-border-default)] p-2">
                    <div class="flex flex-wrap items-center gap-2 text-xs">
                      <strong>${index + 1}. ${tool.toolName}</strong>
                      <code>${tool.disposition}</code>
                      <time class="text-[var(--color-fg-muted)]" dateTime=${new Date(tool.finishedAt * 1000).toISOString()}>종료 ${formatDateTimeKo(tool.finishedAt)}</time>
                      <span class="text-[var(--color-fg-muted)]">${tool.durationMs.toFixed(0)}ms</span>
                    </div>
                    <div class="grid gap-2 mt-2 md:grid-cols-2">
                      <div class="grid gap-1"><div class="flex items-center gap-2"><${EvidenceBadge} kind="typed" /><span class="text-3xs">입력 preview</span></div><${JsonViewerCard} data=${tool.input} /></div>
                      <div class="grid gap-1">
                        <div class="flex items-center gap-2"><${EvidenceBadge} kind="excerpt" /><span class="text-3xs">출력 ${tool.outputTruncated ? '· truncated' : '· complete excerpt'}</span></div>
                        <pre class="max-h-80 overflow-auto whitespace-pre-wrap break-words rounded border border-[var(--color-border-default)] bg-[var(--color-bg-page)] p-3 text-3xs">${tool.outputExcerpt}${tool.outputTruncated ? '\n… 1,024 byte 이후는 registry에 보존되지 않음' : ''}</pre>
                      </div>
                    </div>
                  </li>
                `)}
              </ol>`}
        </div>
      </div>
    `
  }
  if (row.source === 'exact') {
    return html`<${ExactRunDetail} runId=${row.run.runId} />`
  }
  return html`
    <div class="grid gap-2 p-3 bg-[var(--color-bg-surface)] border-t border-[var(--color-border-default)] text-xs">
      <div class="flex items-center gap-2"><${EvidenceBadge} kind="typed" /><strong>Fusion registry summary</strong></div>
      <p>Preset <code>${row.run.preset}</code> · status <code>${row.run.status}</code></p>
      ${row.run.error ? html`<p class="mt-1 text-[var(--color-danger)]">${row.run.failureCode}: ${row.run.error}</p>` : null}
      <p class="text-[var(--color-fg-muted)]">input/output 미보존 — 상세는 Fusion 화면에서</p>
      <a class="w-fit text-[var(--color-accent)] hover:underline" href=${fusionHref()}>Fusion evidence 열기 →</a>
    </div>
  `
}

function matches(row: Row, filter: Filter): boolean {
  if (filter === 'all') return true
  return rowKind(row) === filter
}

type KeeperIdentity = { name: string; agent_name?: string | null }

function recordedOwner(row: Row): string {
  if (row.source === 'verification') return row.run.producer
  if (row.source === 'fusion') return row.run.keeper
  return row.run.actor
}

function resolvedOwner(row: Row, roster: readonly KeeperIdentity[]): string {
  const recorded = recordedOwner(row)
  return roster.find(keeper => keeper.name === recorded || keeper.agent_name === recorded)?.name ?? recorded
}

export function InternalAgentsMonitor() {
  const [rows, setRows] = useState<Row[]>([])
  const [filter, setFilter] = useState<Filter>('all')
  const [expanded, setExpanded] = useState<string | null>(null)
  const [loading, setLoading] = useState(false)
  const [errors, setErrors] = useState<string[]>([])
  const refreshVersion = useRef(0)

  const refresh = useCallback(async () => {
    const version = ++refreshVersion.current
    setLoading(true)
    const [exact, verification, fusion] = await Promise.allSettled([
      fetchExactLaneRuns(),
      fetchVerificationRuns(),
      fetchFusionRuns(),
    ])
    const next: Row[] = []
    const failures: string[] = []
    if (exact.status === 'fulfilled') {
      next.push(...exact.value.runs.map(run => ({ source: 'exact' as const, id: `exact:${run.runId}`, run })))
    } else failures.push(isForbidden(exact.reason)
      ? 'Exact lanes + RAW: Admin 권한 필요 (Settings에서 Admin bearer token을 사용하세요).'
      : `Exact lanes: ${String(exact.reason)}`)
    if (verification.status === 'fulfilled') {
      next.push(...verification.value.runs.map(run => ({ source: 'verification' as const, id: `verification:${run.verificationId}`, run })))
    } else failures.push(`Verification: ${String(verification.reason)}`)
    if (fusion.status === 'fulfilled') {
      next.push(...fusion.value.runs.map(run => ({ source: 'fusion' as const, id: `fusion:${run.runId}`, run })))
    } else failures.push(`Fusion: ${String(fusion.reason)}`)
    if (version !== refreshVersion.current) return
    next.sort((a, b) => startedAt(b) - startedAt(a))
    setRows(next)
    setErrors(failures)
    setLoading(false)
  }, [])

  useEffect(() => {
    void refresh()
    const unregister = registerInternalAgentRefresh(() => { void refresh() })
    return () => {
      unregister()
      refreshVersion.current += 1
    }
  }, [refresh])

  const visible = useMemo(() => rows.filter(row => matches(row, filter)), [rows, filter])
  const roster = keeperRosterSignal.value
  const pausedKeeperNames = shellRuntimeResolution.value?.fleet_safety?.paused_keepers_health?.names ?? []
  const keepers = useMemo(() => {
    const names = new Set(roster.map(keeper => keeper.name))
    for (const name of pausedKeeperNames) names.add(name)
    for (const row of rows) names.add(resolvedOwner(row, roster))
    return Array.from(names).sort()
  }, [pausedKeeperNames, rows, roster])
  const inventory = FILTERS.filter(item => item.id !== 'all').map(item => {
    const kind = item.id as Exclude<Filter, 'all'>
    const matching = rows.filter(row => rowKind(row) === kind)
    return {
      ...item,
      count: matching.length,
      latest: matching.reduce<number | null>((value, row) => value == null ? startedAt(row) : Math.max(value, startedAt(row)), null),
    }
  })
  const owners = keepers.map(name => {
    const owned = rows.filter(row => resolvedOwner(row, roster) === name)
    return {
      name,
      total: owned.length,
      counts: Object.fromEntries(inventory.map(item => [item.id, owned.filter(row => rowKind(row) === item.id).length])) as Record<Exclude<Filter, 'all'>, number>,
      latest: owned.reduce<number | null>((value, row) => value == null ? startedAt(row) : Math.max(value, startedAt(row)), null),
    }
  })

  return html`
    <section class="v2-monitoring-surface grid gap-5" data-testid="internal-agents-monitor">
      <div class="flex flex-wrap items-start gap-3">
        <div>
          <h2 class="text-lg font-semibold text-[var(--color-fg-primary)]">Internal execution evidence</h2>
          <p class="mt-1 text-xs text-[var(--color-fg-muted)]">Run registry, Memory OS journal, Keeper retained trace를 출처별로 분리하고 producer가 보존한 typed identity만으로 읽습니다.</p>
        </div>
        <span class="rounded border border-[var(--color-border-default)] px-2 py-1 text-xs text-[var(--color-fg-muted)]">${rows.length} runs · ${keepers.length} owners</span>
        <${Btn} class="v2-monitoring-action ml-auto" onClick=${() => void refresh()} disabled=${loading}>
          ${loading ? 'Loading…' : 'Refresh'}
        <//>
      </div>

      <div class="v2-monitoring-card flex flex-wrap gap-4 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3 text-xs">
        <span class="flex items-center gap-2"><${EvidenceBadge} kind="raw" /> Admin 전용 retained JSONL 실제 행 · 민감값 포함 가능</span>
        <span class="flex items-center gap-2"><${EvidenceBadge} kind="typed" /> schema-typed registry 값 · 권한/retention 계약에 따라 실제값 포함</span>
        <span class="flex items-center gap-2"><${EvidenceBadge} kind="excerpt" /> 원문 전체가 아닌 제한된 출력</span>
      </div>

      <section class="grid gap-2" aria-labelledby="internal-agent-inventory-title">
        <div class="flex items-end gap-2">
          <h3 id="internal-agent-inventory-title" class="text-sm font-semibold text-[var(--color-fg-primary)]">Observed run inventory</h3>
          <span class="text-3xs text-[var(--color-fg-muted)]">0건인 lane도 숨기지 않습니다.</span>
        </div>
        <div class="grid gap-2 sm:grid-cols-2 xl:grid-cols-6">
          ${inventory.map(item => html`
            <button
              key=${item.id}
              type="button"
              class=${`v2-monitoring-card grid gap-1 rounded-[var(--r-1)] border p-3 text-left ${filter === item.id ? 'border-[var(--color-accent)] bg-[var(--color-bg-elevated)]' : 'border-[var(--color-border-default)] bg-[var(--color-bg-surface)]'}`}
              aria-pressed=${filter === item.id}
              onClick=${() => setFilter(item.id)}
            >
              <span class="text-xs font-semibold">${item.label}</span>
              <strong class="text-xl tabular-nums">${item.count}</strong>
              <span class="text-3xs text-[var(--color-fg-muted)]">${item.latest == null ? '관측 기록 없음' : `최근 ${formatDateTimeKo(item.latest)}`}</span>
            </button>
          `)}
        </div>
      </section>

      <section class="grid gap-2" aria-labelledby="internal-agent-owner-title">
        <div class="flex items-end gap-2">
          <h3 id="internal-agent-owner-title" class="text-sm font-semibold text-[var(--color-fg-primary)]">Owner × execution kind</h3>
          <span class="text-3xs text-[var(--color-fg-muted)]">Keeper Fleet와 exact identity로 조인합니다.</span>
        </div>
        <div class="v2-monitoring-card overflow-x-auto rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)]">
          <table class="w-full min-w-[48rem] text-left text-xs">
            <thead class="border-b border-[var(--color-border-default)] text-3xs uppercase tracking-wide text-[var(--color-fg-muted)]">
              <tr><th class="px-3 py-2">Owner</th>${inventory.map(item => html`<th key=${item.id} class="px-2 py-2 text-right">${item.label}</th>`)}<th class="px-3 py-2 text-right">Last observed</th></tr>
            </thead>
            <tbody>
              ${owners.map(owner => html`
                <tr key=${owner.name} class="border-b border-[var(--color-border-subtle)] last:border-b-0">
                  <th class="px-3 py-2 font-medium"><a class="text-[var(--color-accent)] hover:underline" href=${keeperHref(owner.name)}>${owner.name}</a><span class="ml-2 text-3xs text-[var(--color-fg-muted)]">${owner.total}</span></th>
                  ${inventory.map(item => html`<td key=${item.id} class=${`px-2 py-2 text-right tabular-nums ${owner.counts[item.id as Exclude<Filter, 'all'>] === 0 ? 'text-[var(--color-fg-disabled)]' : ''}`}>${owner.counts[item.id as Exclude<Filter, 'all'>]}</td>`)}
                  <td class="px-3 py-2 text-right text-3xs text-[var(--color-fg-muted)]">${owner.latest == null ? '없음' : formatDateTimeKo(owner.latest)}</td>
                </tr>
              `)}
            </tbody>
          </table>
        </div>
      </section>

      <div class="flex flex-wrap gap-1" role="group" aria-label="Internal agent filters">
        ${FILTERS.map(item => html`
          <button
            key=${item.id}
            type="button"
            class=${`rounded px-2 py-1 text-xs border ${filter === item.id ? 'border-[var(--color-accent)] text-[var(--color-fg-primary)]' : 'border-[var(--color-border-default)] text-[var(--color-fg-muted)]'}`}
            aria-pressed=${filter === item.id}
            onClick=${() => setFilter(item.id)}
          >${item.label} ${item.id === 'all' ? rows.length : inventory.find(entry => entry.id === item.id)?.count ?? 0}</button>
        `)}
      </div>
      ${errors.length > 0 ? html`<${ErrorState} message=${errors.join(' · ')} />` : null}
      <div class="v2-monitoring-card rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3">
        <${KeeperTurnInspectorPanel} keepers=${keepers} />
      </div>
      <div class="flex items-end gap-2">
        <h3 class="text-sm font-semibold text-[var(--color-fg-primary)]">Run timeline</h3>
        <span class="text-3xs text-[var(--color-fg-muted)]">절대 시각 + 상대 시각 + elapsed</span>
      </div>
      ${!loading && visible.length === 0
        ? html`<${EmptyState}>No internal agent runs for this filter.<//>`
        : html`<div class="relative ml-2 grid gap-2 border-l border-[var(--color-border-default)] pl-5">
            ${visible.map(row => {
              const open = expanded === row.id
              const startIso = new Date(startedAt(row) * 1000).toISOString()
              return html`
                <article key=${row.id} class="v2-monitoring-card relative rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] overflow-hidden before:absolute before:-left-[1.55rem] before:top-5 before:h-2 before:w-2 before:rounded-full before:bg-[var(--color-accent)]">
                  <button
                    type="button"
                    class="w-full grid grid-cols-[8.5rem_auto_1fr_auto] gap-3 items-center p-3 text-left"
                    aria-expanded=${open}
                    onClick=${() => setExpanded(open ? null : row.id)}
                  >
                    <span class="text-3xs text-[var(--color-fg-muted)]"><time dateTime=${startIso}>${formatDateTimeKo(startedAt(row))}</time><span class="block">${relativeTime(startIso)}</span></span>
                    <${StatusBadge} tone=${tone(row)} label=${status(row)} />
                    <span class="min-w-0">
                      <strong class="block text-xs text-[var(--color-fg-primary)]">${laneLabel(row)}</strong>
                      <code class="block truncate text-3xs text-[var(--color-fg-muted)]" title=${subject(row)}>${subject(row)}</code>
                      ${row.source === 'exact' && row.run.lane === 'librarian_exact'
                        ? html`<code translate="no" class="block truncate text-3xs text-[var(--color-fg-muted)]" title=${row.run.runId}>run_id · ${row.run.runId}</code>`
                        : null}
                    </span>
                    <span class="text-right text-3xs text-[var(--color-fg-muted)]">
                      <span class="block">${actor(row)}</span>
                      <span class="block">elapsed ${formatElapsed(elapsed(row))}</span>
                    </span>
                  </button>
                  ${open ? html`<${Details} row=${row} />` : null}
                </article>
              `
            })}
          </div>`}
    </section>
  `
}
