import { html } from 'htm/preact'
import { useCallback, useEffect, useMemo, useRef, useState } from 'preact/hooks'
import {
  fetchExactLaneRun,
  fetchExactLaneRuns,
  fetchFusionRuns,
  fetchStandaloneLanes,
  fetchVerificationRuns,
  type ExactLaneRunRecord,
  type ExactLaneRunSummary,
  type FusionRunRecord,
  type StandaloneLanesSnapshot,
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
import { ErrorState } from './common/feedback-state'
import type { StatusBadgeTone } from './common/status-badge'
import { JsonViewerCard } from './common/json-viewer'
import { formatDateTimeKo, relativeTime } from '../lib/format-time'
import { hashForRoute } from '../router'
import { keepers as keeperRosterSignal, shellRuntimeResolution } from '../store'

type Filter =
  | 'all'
  | 'librarian'
  | 'auto-judge'
  | 'board-attention'
  | 'verification'
  | 'fusion'
type Row =
  | { source: 'exact'; id: string; run: ExactLaneRunSummary }
  | { source: 'verification'; id: string; run: VerificationRunRecord }
  | { source: 'fusion'; id: string; run: FusionRunRecord }
type CommittedMemoryJournalEntry = Extract<MemoryJournalEntry, { ok: true; outcome: 'committed' }>
type FailedMemoryJournalEntry = Extract<MemoryJournalEntry, { ok: true; outcome: 'failed' }>

type LibrarianInputEvidence = {
  promptKey: string
  promptSource: string
  promptFilePath: string | null
  effectiveTemplate: string
  renderedBytes: number
  renderedSha256: string
  variables: Record<string, string>
  messageCount: number | null
}

function record(value: unknown): Record<string, unknown> | null {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null
}

export function librarianInputEvidence(value: unknown): LibrarianInputEvidence | null {
  const root = record(value)
  const actual = record(root?.actual_input)
  const prompt = record(actual?.prompt)
  const rawVariables = record(actual?.rendered_prompt_variables)
  if (!root || !actual || !prompt || !rawVariables) return null
  const promptKey = typeof prompt.key === 'string' ? prompt.key : null
  const promptSource = typeof prompt.source === 'string' ? prompt.source : null
  const effectiveTemplate = typeof prompt.effective_template === 'string' ? prompt.effective_template : null
  const renderedBytes = typeof prompt.rendered_bytes === 'number' ? prompt.rendered_bytes : null
  const renderedSha256 = typeof prompt.rendered_sha256 === 'string' ? prompt.rendered_sha256 : null
  if (
    promptKey === null
    || promptSource === null
    || effectiveTemplate === null
    || renderedBytes === null
    || renderedSha256 === null
  ) return null
  const variables: Record<string, string> = {}
  for (const [key, item] of Object.entries(rawVariables)) {
    if (typeof item !== 'string') return null
    variables[key] = item
  }
  return {
    promptKey,
    promptSource,
    promptFilePath: typeof prompt.file_path === 'string' ? prompt.file_path : null,
    effectiveTemplate,
    renderedBytes,
    renderedSha256,
    variables,
    messageCount: typeof root.message_count === 'number' ? root.message_count : null,
  }
}

export function renderCapturedLibrarianPrompt(evidence: LibrarianInputEvidence): string {
  return evidence.effectiveTemplate.replace(/\{\{([^}]+)\}\}/g, (whole, rawName: string) => {
    const name = rawName.trim()
    const value = evidence.variables[name]
    return value === undefined ? whole : value
  })
}

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
  return row.run.subjectId ?? '—'
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
                추가 ${entry.added.length} · 제거 ${entry.removed.length} · 지지 무효화 ${entry.invalidated.length} · 유지 ${entry.retained}
              </span>
            </div>
            <div class="grid gap-3 lg:grid-cols-2">
              <${JsonViewerCard} title=${`추가된 기억 ${entry.added.length}건`} data=${entry.added} />
              <${JsonViewerCard} title=${`제거된 기억 ${entry.removed.length}건`} data=${entry.removed} />
            </div>
            <${JsonViewerCard} title=${`지지 무효화 ${entry.invalidated.length}건`} data=${entry.invalidated} />
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
                    <span class="text-[var(--color-fg-muted)]">추가 ${entry.added.length} · 제거 ${entry.removed.length} · 지지 무효화 ${entry.invalidated.length} · 유지 ${entry.retained}</span>
                  </div>
                  <div class="grid gap-2 lg:grid-cols-2">
                    <${JsonViewerCard} title=${`별도 producer 추가 ${entry.added.length}건`} data=${entry.added} />
                    <${JsonViewerCard} title=${`별도 producer 제거 ${entry.removed.length}건`} data=${entry.removed} />
                  </div>
                  <${JsonViewerCard} title=${`별도 producer 지지 무효화 ${entry.invalidated.length}건`} data=${entry.invalidated} />
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
  const [showRenderedPrompt, setShowRenderedPrompt] = useState(false)

  useEffect(() => {
    const controller = new AbortController()
    setRun(null)
    setError(null)
    setShowRenderedPrompt(false)
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
      <div class="ia-detail">
        <p class="ia-err">이 실행의 typed 값을 읽지 못했습니다: ${error}</p>
      </div>
    `
  }
  if (run === null) {
    return html`
      <div class="ia-detail">
        <p class="ia-note">typed 입출력을 불러오는 중…</p>
      </div>
    `
  }
    const output = run.output ?? { code: run.code, detail: run.detail }
    const memoryEvidence = run.lane === 'librarian_exact'
      ? librarianMemoryEvidence(run.output)
      : null
    const inputEvidence = run.lane === 'librarian_exact'
      ? librarianInputEvidence(run.input.payload)
      : null
    return html`
      <div class="ia-detail">
        <div class="ia-evi">
          <div class="ia-k"><${EvidenceBadge} kind="typed" /> Exact-output registry metadata</div>
          <p class="ia-note">
            Admin-only 실제 typed 값 · Librarian exact에는 research RAW 입력 없음
            ${run.selectedSlot === undefined
              ? null
              : html` · 선택 slot <code>${run.selectedSlot ?? '미기록'}</code>`}
             · <a class="text-[var(--color-accent)] hover:underline" href=${keeperHref(run.actor)}>Keeper 전체 evidence 열기 →</a>
          </p>
        </div>
        <div class="ia-tool-io">
          <${JsonViewerCard} title="실제 입력 · typed" data=${run.input.payload} expandAll=${true} />
          <${JsonViewerCard} title="실제 출력 · typed" data=${output} expandAll=${true} />
        </div>
        ${inputEvidence === null ? null : html`
          <div class="ia-evi" data-librarian-input-evidence>
            <div class="ia-k"><${EvidenceBadge} kind="typed" /> Librarian prompt + input provenance</div>
            <p class="ia-note">
              <code>${inputEvidence.promptKey}</code> · source <code>${inputEvidence.promptSource}</code>
              ${inputEvidence.promptFilePath ? html` · <code>${inputEvidence.promptFilePath}</code>` : null}
              · ${inputEvidence.renderedBytes.toLocaleString()} bytes · sha256 <code>${inputEvidence.renderedSha256.slice(0, 12)}</code>
              ${inputEvidence.messageCount === null ? null : ` · ${inputEvidence.messageCount} messages`}
            </p>
            <div class="ia-tool-io">
              <${JsonViewerCard} title="실행 당시 effective template" data=${inputEvidence.effectiveTemplate} />
              <${JsonViewerCard} title="실제 치환 input sections" data=${inputEvidence.variables} />
            </div>
            <${Btn} variant="ghost" onClick=${() => setShowRenderedPrompt(value => !value)}>
              ${showRenderedPrompt ? '최종 rendered prompt 닫기' : '최종 rendered prompt 보기'}
            <//>
            ${showRenderedPrompt
              ? html`<pre class="mono mt-2 max-h-120 overflow-auto whitespace-pre-wrap rounded border border-[var(--color-border-default)] p-3">${renderCapturedLibrarianPrompt(inputEvidence)}</pre>`
              : null}
          </div>
        `}
        ${run.persistenceError === undefined
          ? null
          : html`<p class="ia-err">완료 의도 <code>${run.intendedStatus}</code> · persistence <code>${run.persistenceState}</code>: ${run.persistenceError}${run.intendedCode ? ` · ${run.intendedCode}: ${run.intendedDetail}` : ''}</p>`}
        <p class="ia-note"><span class="mr-2 inline-flex rounded border border-[var(--color-accent)] px-1.5 py-0.5 text-3xs font-semibold uppercase tracking-wide text-[var(--color-accent)]">TOOL-FREE</span>이 exact 실행은 immutable Librarian input만 사용하며 외부 research/RAW 입력을 받지 않습니다.</p>
        ${memoryEvidence === null
          ? null
          : html`<div class="ia-evi">
              <div class="ia-k"><${EvidenceBadge} kind="typed" /> Memory before → after</div>
              <p class="ia-note">registry에는 count/revision만, 실제 추가·제거는 아래 journal</p>
              <div class="ia-tool-io">
                <${JsonViewerCard} title="Before memory · typed" data=${memoryEvidence.before} expandAll=${true} />
                <${JsonViewerCard} title="After memory + change · typed" data=${memoryEvidence.after} expandAll=${true} />
              </div>
            </div>`}
        ${run.lane === 'librarian_exact' && run.subjectId !== null
          ? html`<div class="ia-evi">
              <${LibrarianJournal}
                keeper=${run.actor}
                traceId=${run.subjectId}
                revision=${librarianRevision(run.output)}
              />
            </div>`
          : run.lane === 'librarian_exact'
            ? html`<p class="ia-note">이 exact-run registry 세대는 subject_id를 기록하지 않아 Memory journal을 trace로 결합하지 않습니다.</p>`
            : null}
      </div>
    `
}

function Details({ row }: { row: Row }) {
  if (row.source === 'verification') {
    const tools = row.run.tools ?? []
    return html`
      <div class="ia-detail">
        <div class="ia-evi">
          <div class="ia-k"><${EvidenceBadge} kind="typed" /> Execution path</div>
          <code class="mono">${row.run.producer} → ${row.run.authorityKind} → ${row.run.authorityActor} → ${row.run.status}</code>
          <p class="ia-note">
            시작 <time dateTime=${new Date(row.run.startedAt * 1000).toISOString()}>${formatDateTimeKo(row.run.startedAt)}</time>
            ${finishedAt(row) == null ? null : html` · 종료 <time dateTime=${new Date(finishedAt(row)! * 1000).toISOString()}>${formatDateTimeKo(finishedAt(row)!)}</time>`}
            ${row.run.evaluatorRuntime ? html` · runtime <code>${row.run.evaluatorRuntime}</code>` : null}
          </p>
          ${row.run.cause ? html`<p class="ia-err">${row.run.gate ? `${row.run.gate}: ` : ''}${row.run.cause}</p>` : null}
          <p class="ia-note">Review 원문은 저장되지 않음 · 출력은 1,024B excerpt</p>
        </div>
        <div class="ia-evi">
          <div class="ia-k">Internal tool agents (${tools.length})</div>
          ${tools.length === 0
            ? html`<p class="ia-note">No tools invoked in this verification run.</p>`
            : html`<ol class="ia-tools">
                ${tools.map((tool, index) => html`
                  <li key=${`${row.id}-${index}`} class="ia-tool">
                    <div class="ia-tool-h">
                      <b>${index + 1}. ${tool.toolName}</b>
                      <code class="mono">${tool.disposition}</code>
                      <time class="ia-ms mono" dateTime=${new Date(tool.finishedAt * 1000).toISOString()}>종료 ${formatDateTimeKo(tool.finishedAt)}</time>
                      <span class="ia-ms mono">${tool.durationMs.toFixed(0)}ms</span>
                    </div>
                    <div class="ia-tool-io">
                      <div>
                        <div class="ia-k"><${EvidenceBadge} kind="typed" /> 입력 preview</div>
                        <${JsonViewerCard} data=${tool.input} />
                      </div>
                      <div>
                        <div class="ia-k"><${EvidenceBadge} kind="excerpt" /> 출력 ${tool.outputTruncated ? '· truncated' : '· complete excerpt'}</div>
                        <pre class="mono max-h-80">${tool.outputExcerpt}${tool.outputTruncated ? '\n… 1,024 byte 이후는 registry에 보존되지 않음' : ''}</pre>
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
    <div class="ia-detail">
      <div class="ia-evi">
        <div class="ia-k"><${EvidenceBadge} kind="typed" /> Fusion registry summary</div>
        <code class="mono">preset ${row.run.preset} · status ${row.run.status}</code>
        ${row.run.error ? html`<div class="ia-err">${row.run.failureCode}: ${row.run.error}</div>` : null}
        <p class="ia-note">input/output 미보존 — 상세는 Fusion 화면에서 · <a class="text-[var(--color-accent)] hover:underline" href=${fusionHref()}>Fusion evidence 열기 →</a></p>
      </div>
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
  const [laneMatrix, setLaneMatrix] = useState<StandaloneLanesSnapshot | null>(null)
  const [filter, setFilter] = useState<Filter>('all')
  const [expanded, setExpanded] = useState<string | null>(null)
  const [loading, setLoading] = useState(false)
  const [errors, setErrors] = useState<string[]>([])
  const refreshVersion = useRef(0)

  const refresh = useCallback(async () => {
    const version = ++refreshVersion.current
    setLoading(true)
    const [exact, verification, fusion, standalone] = await Promise.allSettled([
      fetchExactLaneRuns(),
      fetchVerificationRuns(),
      fetchFusionRuns(),
      fetchStandaloneLanes(),
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
    if (standalone.status === 'rejected') {
      failures.push(isForbidden(standalone.reason)
        ? 'Standalone lane matrix: Admin 권한 필요.'
        : `Standalone lane matrix: ${String(standalone.reason)}`)
    }
    if (version !== refreshVersion.current) return
    if (standalone.status === 'fulfilled') setLaneMatrix(standalone.value)
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
    <section class="v2-monitoring-surface ia-wrap" data-testid="internal-agents-monitor">
      <div class="ia-head">
        <h3>Internal execution evidence</h3>
        <span class="ia-count mono">${rows.length} runs · ${keepers.length} owners</span>
        <span class="ia-route mono">monitoring?section=internal-agents</span>
        <${Btn} class="v2-monitoring-action" onClick=${() => void refresh()} disabled=${loading}>
          ${loading ? 'Loading…' : 'Refresh'}
        <//>
      </div>
      <p class="ia-lede">Run registry, Memory OS journal, Keeper retained trace를 출처별로 분리하고 producer가 보존한 typed identity만으로 읽습니다.</p>

      <div class="v2-monitoring-card flex flex-wrap gap-4 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3 text-xs">
        <span class="flex items-center gap-2"><${EvidenceBadge} kind="raw" /> Admin 전용 retained JSONL 실제 행 · 민감값 포함 가능</span>
        <span class="flex items-center gap-2"><${EvidenceBadge} kind="typed" /> schema-typed registry 값 · 권한/retention 계약에 따라 실제값 포함</span>
        <span class="flex items-center gap-2"><${EvidenceBadge} kind="excerpt" /> 원문 전체가 아닌 제한된 출력</span>
      </div>

      <section class="grid gap-2" aria-labelledby="standalone-lane-matrix-title">
        <div class="flex flex-wrap items-end gap-2">
          <h3 id="standalone-lane-matrix-title" class="text-sm font-semibold text-[var(--color-fg-primary)]">Standalone LLM lane matrix</h3>
          <span class="rounded border border-[var(--color-accent)] px-1.5 py-0.5 text-3xs font-semibold text-[var(--color-accent)]">READ-ONLY OBSERVATION</span>
          <span class="text-3xs text-[var(--color-fg-muted)]">설정됐지만 현재 retained 관측이 없는 lane도 표시합니다.</span>
        </div>
        ${laneMatrix === null
          ? html`<div class="ia-empty">Standalone lane 관측 정보를 읽는 중이거나 사용할 수 없습니다.</div>`
          : html`
            ${laneMatrix.exactRunProjectionTruncated
              ? html`<div class="rounded border border-[var(--status-warn)] p-2 text-xs text-[var(--status-warn)]">Exact run window ${laneMatrix.exactRunProjectionCount} / ${laneMatrix.exactRunSourceTotal} · 표의 exact counts/p50는 최신 bounded window 기준입니다.</div>`
              : null}
            <div class="ai-tablewrap">
              <table class="ai-table" data-testid="standalone-lane-matrix">
                <thead>
                  <tr><th>Lane</th><th>State</th><th>Admitted slots</th><th class="r">Running</th><th class="r">Retained</th><th class="r">Last terminal</th><th class="r">p50</th><th>Observed slots</th></tr>
                </thead>
                <tbody>
                  ${laneMatrix.lanes.map(lane => {
                    const statusLabel = lane.status === 'no_retained_observation'
                      ? 'No retained observation'
                      : lane.status.charAt(0).toUpperCase() + lane.status.slice(1)
                    const statusClass = lane.status === 'degraded' || lane.status === 'unavailable'
                      ? 'text-[var(--color-danger)]'
                      : lane.status === 'running'
                        ? 'text-[var(--status-warn)]'
                        : 'text-[var(--color-fg-primary)]'
                    return html`
                      <tr key=${lane.laneId}>
                        <td><strong>${lane.label}</strong>${lane.required ? html` <span class="dim">required</span>` : null}<br /><code class="mono dim">${lane.laneId}</code></td>
                        <td class=${statusClass}><strong>${statusLabel}</strong>${lane.admissionError ? html`<br /><span class="text-3xs">${lane.admissionError}</span>` : null}</td>
                        <td class="mono">${lane.admittedSlots.length === 0 ? '—' : lane.admittedSlots.join(', ')}${lane.cliSlots.length === 0 ? null : html`<br /><span class="text-3xs text-[var(--color-text-tertiary)]">cli: ${lane.cliSlots.join(', ')}</span>`}${lane.droppedSlots.length === 0 ? null : html`<br /><span class="text-3xs text-[var(--color-danger)]">dropped: ${lane.droppedSlots.join(', ')}</span>`}</td>
                        <td class="r mono">${lane.runningCount}</td>
                        <td class="r mono">${lane.retainedRunCount}</td>
                        <td class="r mono">${lane.lastTerminalAt === null ? '관측 기록 없음' : `${lane.lastOutcome ?? 'terminal'} · ${formatDateTimeKo(lane.lastTerminalAt)}`}</td>
                        <td class="r mono">${formatElapsed(lane.p50ElapsedSeconds ?? undefined)}</td>
                        <td class="mono">${lane.selectedSlots.length === 0 ? '—' : lane.selectedSlots.map(slot => `${slot.slotId} ×${slot.count}`).join(', ')}</td>
                      </tr>
                    `
                  })}
                </tbody>
              </table>
            </div>
          `}
      </section>

      <section class="grid gap-2" aria-labelledby="internal-agent-inventory-title">
        <div class="flex items-end gap-2">
          <h3 id="internal-agent-inventory-title" class="text-sm font-semibold text-[var(--color-fg-primary)]">Observed run inventory</h3>
          <span class="text-3xs text-[var(--color-fg-muted)]">0건인 lane도 숨기지 않습니다.</span>
        </div>
        <div class="ai-strip">
          ${inventory.map(item => html`
            <button
              key=${item.id}
              type="button"
              class=${`ai-stat cursor-pointer text-left ${filter === item.id ? 'border-[var(--volt-strong)]' : ''}`}
              aria-pressed=${filter === item.id}
              onClick=${() => setFilter(item.id)}
            >
              <span class="k">${item.label}</span>
              <span class="v mono">${item.count}</span>
              <span class="cl-sub mono">${item.latest == null ? '관측 기록 없음' : `최근 ${formatDateTimeKo(item.latest)}`}</span>
            </button>
          `)}
        </div>
      </section>

      <section class="grid gap-2" aria-labelledby="internal-agent-owner-title">
        <div class="flex items-end gap-2">
          <h3 id="internal-agent-owner-title" class="text-sm font-semibold text-[var(--color-fg-primary)]">Owner × execution kind</h3>
          <span class="text-3xs text-[var(--color-fg-muted)]">Keeper Fleet와 exact identity로 조인합니다.</span>
        </div>
        <div class="ai-tablewrap">
          <table class="ai-table">
            <thead>
              <tr><th>Owner</th>${inventory.map(item => html`<th key=${item.id} class="r">${item.label}</th>`)}<th class="r">Last observed</th></tr>
            </thead>
            <tbody>
              ${owners.map(owner => html`
                <tr key=${owner.name}>
                  <td><a class="text-[var(--color-accent)] hover:underline" href=${keeperHref(owner.name)}>${owner.name}</a> <span class="dim mono">${owner.total}</span></td>
                  ${inventory.map(item => {
                    const count = owner.counts[item.id as Exclude<Filter, 'all'>]
                    return html`<td key=${item.id} class=${`r mono ${count === 0 ? 'dim' : ''}`}>${count}</td>`
                  })}
                  <td class="r dim mono">${owner.latest == null ? '없음' : formatDateTimeKo(owner.latest)}</td>
                </tr>
              `)}
            </tbody>
          </table>
        </div>
      </section>

      <div class="ia-filters" role="group" aria-label="Internal agent filters">
        ${FILTERS.map(item => html`
          <button
            key=${item.id}
            type="button"
            class=${`ia-filter ${filter === item.id ? 'on' : ''}`}
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
        ? html`<div class="ia-empty">No internal agent runs for this filter.</div>`
        : html`<div class="ia-list">
            ${visible.map(row => {
              const open = expanded === row.id
              const startIso = new Date(startedAt(row) * 1000).toISOString()
              return html`
                <article key=${row.id} class=${`ia-card ${open ? 'on' : ''}`}>
                  <button
                    type="button"
                    class="ia-row"
                    aria-expanded=${open}
                    onClick=${() => setExpanded(open ? null : row.id)}
                  >
                    <span class="ia-badge" data-tone=${tone(row)}><i></i>${status(row)}</span>
                    <span class="ia-sub">
                      <b>${laneLabel(row)}</b>
                      <code class="mono" title=${subject(row)}>${subject(row)}</code>
                      ${row.source === 'exact' && row.run.lane === 'librarian_exact'
                        ? html`<code translate="no" class="mono" title=${row.run.runId}>run_id · ${row.run.runId}</code>`
                        : null}
                    </span>
                    <span class="ia-meta mono">
                      <span>${actor(row)}</span>
                      <span><time dateTime=${startIso}>${formatDateTimeKo(startedAt(row))}</time> · ${relativeTime(startIso)}</span>
                      <span>elapsed ${formatElapsed(elapsed(row))}</span>
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
