// MASC Dashboard — retained redacted execution records and the next prompt.
//
// The server has carried these four views since RFC-0366 and the raw-trace
// reader landed, but nothing rendered them: the routes, the decoders and their
// tests were all green with zero consumers, so the only way to read a turn was
// curl. This is the consumer.
//
// Read-only except the operator note, which is the one place an operator can
// put a sentence in front of the next turn.

import { html } from 'htm/preact'
import { useCallback, useEffect, useState } from 'preact/hooks'
import {
  fetchKeeperLastPrompt,
  fetchKeeperOperatorNote,
  fetchKeeperRawTrace,
  fetchKeeperRawTraces,
  putKeeperOperatorNote,
  type OperatorNote,
  type PromptCapture,
  type RawTracePage,
  type RawTraceTurn,
} from '../api/dashboard-keeper-prompt'
import { Btn } from './btn'
import { relativeTime } from '../lib/format-time'
import { JsonViewerCard } from './common/json-viewer'

type Tab = 'raw' | 'prompt' | 'note'
type RawView = 'text' | 'tree'

const TABS: Array<{ id: Tab; label: string; hint: string }> = [
  { id: 'raw', label: 'Retained trace records', hint: 'REDACTED TRACE · 보존된 실행 레코드' },
  { id: 'prompt', label: 'Typed next prompt', hint: 'TYPED · 다음 턴에 조립될 시스템 컨텍스트' },
  { id: 'note', label: 'Operator input', hint: 'OPERATOR INPUT · 다음 턴 한 번에만 실리는 문장' },
]

// The store rejects a note over this rather than truncating it. Showing the
// budget while typing is the difference between a rejection an operator
// expected and one that looks like a bug.
const MAX_NOTE_BYTES = 4 * 1024

const RECORDS_PER_PAGE = 20

function formatBytes(value: number): string {
  if (value < 1024) return `${value} B`
  if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KB`
  return `${(value / (1024 * 1024)).toFixed(1)} MB`
}

// A turn past the listing budget has no count yet. Saying so — and naming the
// size that caused it — is more use to an operator hunting a runaway turn than
// a number would be, because the size is the thing that flagged it. Opening
// the turn reads the file in full and shows the real total.
function censusLabel(census: RawTraceTurn['census']): string {
  return census.state === 'whole_file'
    ? `${census.records}건`
    : `${formatBytes(census.budgetBytes)} 초과 · 열어서 집계`
}

// These records carry unix seconds; relativeTime reads ISO strings.
function ago(unixSeconds: number): string {
  return relativeTime(new Date(unixSeconds * 1000).toISOString())
}

function utf8Bytes(text: string): number {
  return new TextEncoder().encode(text).length
}

function Muted({ children }: { children: unknown }) {
  return html`<p class="text-xs text-[var(--color-fg-muted)]">${children}</p>`
}

function Danger({ children }: { children: unknown }) {
  return html`<p class="text-xs text-[var(--color-danger)]">${children}</p>`
}

// A scroll container of its own so a 200 KB turn does not make the page scroll
// sideways.
function Pre({ text }: { text: string }) {
  return html`
    <pre
      class="max-h-[28rem] overflow-auto rounded border border-[var(--color-border-subtle)] bg-[var(--color-bg-subtle)] p-2 text-3xs leading-relaxed"
    >${text}</pre>
  `
}

/** Redacted semantic execution records retained for one keeper turn. */
function RawTurns({ keeper }: { keeper: string }) {
  const [turns, setTurns] = useState<readonly RawTraceTurn[] | null>(null)
  const [selected, setSelected] = useState<string | null>(null)
  const [page, setPage] = useState<RawTracePage | null>(null)
  const [offset, setOffset] = useState(0)
  const [view, setView] = useState<RawView>('text')
  const [copyState, setCopyState] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    const controller = new AbortController()
    setTurns(null)
    setSelected(null)
    setPage(null)
    setError(null)
    fetchKeeperRawTraces(keeper, 50, { signal: controller.signal })
      .then(setTurns)
      .catch((reason: unknown) => {
        if (controller.signal.aborted) return
        setError(reason instanceof Error ? reason.message : String(reason))
      })
    return () => controller.abort()
  }, [keeper])

  useEffect(() => {
    if (selected === null) return
    const controller = new AbortController()
    setPage(null)
    setCopyState(null)
    fetchKeeperRawTrace(keeper, selected, {
      signal: controller.signal,
      offset,
      limit: RECORDS_PER_PAGE,
    })
      .then(setPage)
      .catch((reason: unknown) => {
        if (controller.signal.aborted) return
        setError(reason instanceof Error ? reason.message : String(reason))
      })
    return () => controller.abort()
  }, [keeper, selected, offset])

  if (error !== null) return html`<${Danger}>원문을 읽지 못했습니다: ${error}<//>`
  if (turns === null) return html`<${Muted}>턴 목록 읽는 중…<//>`
  if (turns.length === 0) {
    return html`<${Muted}>이 keeper 는 아직 저장된 턴 원문이 없습니다.<//>`
  }

  const copyPage = async () => {
    if (page === null) return
    try {
      await navigator.clipboard.writeText(page.records.map(record => record.raw).join('\n'))
      setCopyState(`${page.records.length}개 literal JSONL 행 복사됨`)
    } catch (cause) {
      setCopyState(`복사 실패: ${cause instanceof Error ? cause.message : String(cause)}`)
    }
  }

  return html`
    <div class="grid gap-2">
      <div class="max-h-40 overflow-auto rounded border border-[var(--color-border-subtle)]">
        ${turns.map(turn => html`
          <button
            key=${turn.file}
            type="button"
            class="flex w-full items-center gap-2 border-b border-[var(--color-border-subtle)] px-2 py-1 text-left text-3xs last:border-b-0 ${
              selected === turn.file ? 'bg-[var(--color-bg-selected)]' : ''
            }"
            onClick=${() => { setSelected(turn.file); setOffset(0) }}
          >
            <span class="font-mono">${turn.file}</span>
            ${turn.traceId == null
              ? html`<span class="text-[var(--color-fg-disabled)]">trace 없음</span>`
              : html`<span class="min-w-0 truncate font-mono text-[var(--color-fg-muted)]" title=${turn.traceId}>${turn.traceId}</span>`}
            <span class="ml-auto tabular-nums text-[var(--color-fg-muted)]">
              ${censusLabel(turn.census)} · ${formatBytes(turn.bytes)} · ${ago(turn.modifiedAt)}
            </span>
          </button>
        `)}
      </div>

      ${selected === null
        ? html`<${Muted}>턴을 고르면 원문이 열립니다.<//>`
        : page === null
          ? html`<${Muted}>${selected} 읽는 중…<//>`
          : html`
            <div class="flex items-center gap-2 text-3xs text-[var(--color-fg-muted)]">
              <span class="font-mono">${page.file}</span>
              <span class="tabular-nums">
                ${page.offset + 1}–${page.offset + page.records.length} / ${page.totalRecords}
              </span>
              <${Btn}
                class="ml-auto"
                disabled=${page.offset === 0}
                onClick=${() => setOffset(Math.max(0, page.offset - RECORDS_PER_PAGE))}
              >이전<//>
              <${Btn}
                disabled=${page.offset + page.records.length >= page.totalRecords}
                onClick=${() => setOffset(page.offset + RECORDS_PER_PAGE)}
              >다음<//>
            </div>
            <div class="flex flex-wrap items-center gap-1" role="group" aria-label="Trace 표시 방식">
              <button
                type="button"
                class=${`rounded border px-2 py-1 text-3xs ${view === 'text' ? 'border-[var(--status-warn)] text-[var(--status-warn)]' : 'border-[var(--color-border-default)] text-[var(--color-fg-muted)]'}`}
                aria-pressed=${view === 'text'}
                onClick=${() => setView('text')}
              >Literal JSONL</button>
              <button
                type="button"
                class=${`rounded border px-2 py-1 text-3xs ${view === 'tree' ? 'border-[var(--color-accent)] text-[var(--color-accent)]' : 'border-[var(--color-border-default)] text-[var(--color-fg-muted)]'}`}
                aria-pressed=${view === 'tree'}
                onClick=${() => setView('tree')}
              >JSON tree</button>
              <${Btn} class="ml-auto" onClick=${() => void copyPage()}>현재 페이지 복사<//>
              ${copyState === null ? null : html`<span role="status" class="text-3xs text-[var(--color-fg-muted)]">${copyState}</span>`}
            </div>
            <p class="text-3xs text-[var(--color-fg-muted)]">
              ${view === 'text'
                ? 'REDACTED TRACE · retained JSONL의 literal 행을 변환 없이 표시합니다.'
                : 'PARSED TREE · 같은 행을 JSON으로 해석한 탐색용 보기입니다.'}
            </p>
            ${page.records.map((record, index) => html`
              <div key=${page.offset + index} class="grid gap-1" data-testid="raw-trace-record">
                <div class="flex items-center gap-2 text-3xs">
                  <span class="w-fit rounded border border-[var(--status-warn)] px-1.5 py-0.5 font-semibold text-[var(--status-warn)]">REDACTED TRACE</span>
                  <span class="font-mono text-[var(--color-fg-muted)]">line ${page.offset + index + 1}</span>
                </div>
                ${view === 'text'
                  ? html`<${Pre} text=${record.raw} />`
                  : record.ok
                    ? html`<${JsonViewerCard} data=${record.record} title=${`Provider record ${page.offset + index + 1}`} />`
                    : html`<${Pre} text=${record.raw} />`}
                ${record.ok
                  ? null
                  // A torn line keeps its position rather than being skipped:
                  // a damaged trace must not read as a shorter one.
                  : html`<${Danger}>레코드 ${page.offset + index + 1} 를 읽지 못했습니다: ${record.error}<//>`}
              </div>
            `)}
          `}
    </div>
  `
}

/** The keeper's most recently captured turn prompt, block by block, read from
    `GET /api/v1/keepers/{name}/last-prompt`. Also mounted by the memory inspector's
    recall chain so both surfaces show the same capture. */
export function KeeperPromptCapture({ keeper }: { keeper: string }) {
  const [capture, setCapture] = useState<PromptCapture | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [open, setOpen] = useState<string | null>(null)

  useEffect(() => {
    const controller = new AbortController()
    setCapture(null)
    setError(null)
    fetchKeeperLastPrompt(keeper, { signal: controller.signal })
      .then(setCapture)
      .catch((reason: unknown) => {
        if (controller.signal.aborted) return
        setError(reason instanceof Error ? reason.message : String(reason))
      })
    return () => controller.abort()
  }, [keeper])

  if (error !== null) return html`<${Danger}>프롬프트를 읽지 못했습니다: ${error}<//>`
  if (capture === null) return html`<${Muted}>프롬프트 읽는 중…<//>`
  if (capture.blocks.length === 0) {
    return html`<${Muted}>캡처된 프롬프트 없음<//>`
  }

  const total = capture.blocks.reduce((sum, block) => sum + block.bytes, 0)

  return html`
    <div class="grid gap-2">
      <div class="text-3xs text-[var(--color-fg-muted)]">
        turn ${capture.absoluteTurn} · trace
        <span class="font-mono">${capture.traceId}</span> ·
        ${ago(capture.capturedAt)} · 합계 ${formatBytes(total)}
      </div>
      ${capture.blocks.map(block => html`
        <div key=${block.id} class="rounded border border-[var(--color-border-subtle)]">
          <button
            type="button"
            class="flex w-full items-center gap-2 px-2 py-1 text-left text-3xs"
            onClick=${() => setOpen(open === block.id ? null : block.id)}
          >
            <span class="font-mono">${block.id}</span>
            <span class="ml-auto tabular-nums text-[var(--color-fg-muted)]">
              ${formatBytes(block.bytes)}
            </span>
            <span aria-hidden="true">${open === block.id ? '▾' : '▸'}</span>
          </button>
          ${open === block.id ? html`<div class="p-2 pt-0"><${Pre} text=${block.text} /></div>` : null}
        </div>
      `)}
      ${capture.assembled === null
        ? null
        : html`
          <details>
            <summary class="cursor-pointer text-3xs text-[var(--color-fg-muted)]">
              조립된 전문 (${formatBytes(utf8Bytes(capture.assembled))})
            </summary>
            <div class="pt-1"><${Pre} text=${capture.assembled} /></div>
          </details>
        `}
    </div>
  `
}

/** One sentence for one turn. The only write on this panel. */
function NoteEditor({ keeper }: { keeper: string }) {
  const [note, setNote] = useState<OperatorNote | null>(null)
  const [absent, setAbsent] = useState(false)
  const [draft, setDraft] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)

  const load = useCallback((signal?: AbortSignal) => {
    setError(null)
    fetchKeeperOperatorNote(keeper, { signal })
      .then(value => { setNote(value); setAbsent(false) })
      .catch((reason: unknown) => {
        if (signal?.aborted) return
        // No note yet is the ordinary state for most keepers, not a failure.
        const message = reason instanceof Error ? reason.message : String(reason)
        if (/no_note|not found/i.test(message)) { setNote(null); setAbsent(true); return }
        setError(message)
      })
  }, [keeper])

  useEffect(() => {
    const controller = new AbortController()
    setNote(null)
    setAbsent(false)
    setDraft('')
    load(controller.signal)
    return () => controller.abort()
  }, [keeper, load])

  const bytes = utf8Bytes(draft)
  const overBudget = bytes > MAX_NOTE_BYTES

  const submit = useCallback(async () => {
    setSaving(true)
    setError(null)
    try {
      const saved = await putKeeperOperatorNote(keeper, draft)
      setNote(saved)
      setAbsent(false)
      setDraft('')
    } catch (reason: unknown) {
      // The server rejects an oversized note rather than truncating it, and
      // its refusal carries the byte counts. Showing it verbatim beats a
      // generic failure for the one case an operator needs to act on.
      setError(reason instanceof Error ? reason.message : String(reason))
    } finally {
      setSaving(false)
    }
  }, [keeper, draft])

  return html`
    <div class="grid gap-2">
      ${error !== null ? html`<${Danger}>${error}<//>` : null}

      ${absent
        ? html`<${Muted}>대기 중인 노트가 없습니다.<//>`
        : note === null
          ? html`<${Muted}>노트 읽는 중…<//>`
          : html`
            <div class="rounded border border-[var(--color-border-subtle)] p-2">
              <div class="flex items-center gap-2 text-3xs text-[var(--color-fg-muted)]">
                <span>${note.pending ? '다음 턴에 실림' : `turn ${note.consumedTurn} 에서 소비됨`}</span>
                <span class="ml-auto">${note.createdBy} · ${ago(note.createdAt)}</span>
              </div>
              <${Pre} text=${note.text} />
            </div>
          `}

      <label class="grid gap-1">
        <span class="text-3xs uppercase tracking-wide text-[var(--color-fg-muted)]">
          새 노트 — 다음 턴 한 번에만 실립니다
        </span>
        <textarea
          class="min-h-24 rounded border border-[var(--color-border-subtle)] bg-[var(--color-bg-subtle)] p-2 text-xs"
          value=${draft}
          onInput=${(event: Event) => setDraft((event.target as HTMLTextAreaElement).value)}
          placeholder="예: PR #27407 의 취소 기록부터 확인하고 시작해라."
        ></textarea>
      </label>

      <div class="flex items-center gap-2 text-3xs">
        <span class="tabular-nums ${overBudget ? 'text-[var(--color-danger)]' : 'text-[var(--color-fg-muted)]'}">
          ${bytes} / ${MAX_NOTE_BYTES} B
        </span>
        ${overBudget
          ? html`<span class="text-[var(--color-danger)]">한도를 넘으면 잘리지 않고 거부됩니다.</span>`
          : null}
        <${Btn}
          class="ml-auto"
          disabled=${saving || draft.trim().length === 0 || overBudget}
          onClick=${() => void submit()}
        >${saving ? '저장 중…' : '다음 턴에 싣기'}<//>
      </div>
    </div>
  `
}

export function KeeperTurnInspectorPanel({ keepers }: { keepers: readonly string[] }) {
  const [keeper, setKeeper] = useState<string | null>(keepers[0] ?? null)
  const [tab, setTab] = useState<Tab>('raw')

  // The roster arrives after the first render, so adopt the first keeper once
  // it does and drop a selection that is no longer in the roster.
  useEffect(() => {
    if (keeper !== null && keepers.includes(keeper)) return
    setKeeper(keepers[0] ?? null)
  }, [keepers, keeper])

  if (keeper === null) {
    return html`
      <section class="grid gap-2" data-testid="keeper-turn-inspector">
        <${Muted}>관측된 keeper 없음<//>
      </section>
    `
  }

  const active = TABS.find(item => item.id === tab) ?? TABS[0]!

  return html`
    <section class="grid gap-2" data-testid="keeper-turn-inspector">
      <div class="flex flex-wrap items-center gap-2">
        <h3 class="text-xs font-semibold text-[var(--color-fg-primary)]">Turn inspector</h3>
        <label class="flex items-center gap-1 text-3xs text-[var(--color-fg-muted)]">
          keeper
          <select
            class="rounded border border-[var(--color-border-subtle)] bg-[var(--color-bg-subtle)] px-1 py-0.5 text-3xs"
            value=${keeper}
            onChange=${(event: Event) => setKeeper((event.target as HTMLSelectElement).value)}
          >
            ${keepers.map(name => html`<option key=${name} value=${name}>${name}</option>`)}
          </select>
        </label>
      </div>

      <div class="flex flex-wrap gap-1" role="tablist" aria-label="Turn inspector views">
        ${TABS.map(item => html`
          <button
            key=${item.id}
            type="button"
            role="tab"
            aria-selected=${tab === item.id}
            class=${`rounded px-2 py-1 text-xs border ${
              tab === item.id
                ? 'border-[var(--color-accent)] text-[var(--color-fg-primary)]'
                : 'border-[var(--color-border-default)] text-[var(--color-fg-muted)]'
            }`}
            onClick=${() => setTab(item.id)}
          >${item.label}</button>
        `)}
      </div>
      <${Muted}>${active.hint}<//>

      ${tab === 'raw' ? html`<${RawTurns} keeper=${keeper} />` : null}
      ${tab === 'prompt' ? html`<${KeeperPromptCapture} keeper=${keeper} />` : null}
      ${tab === 'note' ? html`<${NoteEditor} keeper=${keeper} />` : null}
    </section>
  `
}
