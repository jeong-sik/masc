// Keeper Turn Inspector (RFC-0233 PR-4) — one row per keeper turn from
// GET /api/v1/keepers/:name/turn-records, with the server-computed
// block diff between consecutive turns of the same trace. Answers the
// operator question "which instruction blocks entered, left, or changed
// between turns" without reading source.
//
// v2 refresh: each turn row opens a detail drawer with summary stats,
// token-economics bar, tabbed waterfall, structured transcript, and
// copyable context blocks styled after keeper-v2 turn-inspector.

import { html } from 'htm/preact'
import { useEffect, useMemo, useRef, useState } from 'preact/hooks'
import {
  fetchKeeperTurnRecords,
  fetchKeeperTurnTranscript,
} from '../api/dashboard'
import type {
  MemoryOsEpisodeSummary,
  MemoryOsTurnRecordSnapshot,
  TurnBlock,
  TurnBlockDiff,
  TurnRecordEntry,
  TurnRecordRow,
  TurnRecordsResponse,
  TurnTranscript,
  TurnTranscriptLine,
  TelemetryFreshnessMetadata,
} from '../api/dashboard'
import { formatTimeHms } from '../lib/format-time'
import { formatMsCompact } from '../lib/format-number'
import { LoadingState } from './common/feedback-state'
import { useManagedAsyncResource } from '../lib/use-managed-async-resource'
import { coverageGapDisplay, sourceHealthClass, freshnessText } from './common/source-health'

const EMPTY_TURN_RECORD_ROWS: TurnRecordRow[] = []

// RFC-0233 §7: [turn_ref] is minted once by the Keeper turn writer and carried
// unchanged by TurnRecord, chat, and board origins. The dashboard compares the
// opaque typed-wire value directly; it never parses or reconstructs identity.
export function initialTurnRowForTurnRef(
  rows: TurnRecordRow[],
  turnRef?: string | null,
): TurnRecordRow | null {
  if (!turnRef || rows.length === 0) return null
  return rows.find(row => row.record.turn_ref === turnRef) ?? null
}

function FreshnessLine({ data }: { data: TelemetryFreshnessMetadata }) {
  const gap = coverageGapDisplay(data)
  return html`
    <div class="text-3xs text-[var(--color-fg-disabled)] v2-monitoring-row">
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
    <div class="flex items-center gap-2 text-2xs font-mono v2-monitoring-row">
      <span class="text-[var(--color-fg-default)]">${block.block}</span>
      <span class="text-[var(--color-fg-muted)]">${block.bytes}B</span>
      <span class="text-[var(--color-fg-disabled)]" title=${block.digest}>
        ${block.digest.slice(0, 12)}
      </span>
    </div>
  `
}

function latestBlockByName(rows: TurnRecordRow[], blockName: string): TurnBlock | null {
  for (const row of [...rows].reverse()) {
    const block = row.record.blocks.find(item => item.block === blockName)
    if (block) return block
  }
  return null
}

function latestMemoryOsBlock(rows: TurnRecordRow[]): TurnBlock | null {
  return latestBlockByName(rows, 'memory_os_recall')
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
    <div class="min-w-0 border-t border-[var(--color-border-muted)] py-2 first:border-t-0 v2-monitoring-row">
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
      class="mb-3 border-y border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2 py-3 v2-monitoring-panel"
      data-testid="memory-os-recall-source"
    >
      <div class="flex min-w-0 flex-wrap items-start gap-3 v2-monitoring-toolbar">
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

      <div class="mt-2 divide-y divide-[var(--color-border-muted)] v2-monitoring-row">
        ${episodes.length === 0
          ? html`<div class="py-2 text-2xs text-[var(--color-fg-disabled)] v2-monitoring-row">recent episodes 없음</div>`
          : episodes.map(episode => html`<${MemoryOsEpisodeRow} key=${`${episode.trace_id}-${episode.generation}-${episode.created_at}`} episode=${episode} />`)}
      </div>

      <details class="mt-2 text-3xs text-[var(--color-fg-disabled)] v2-monitoring-detail">
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
    return html`<div class="text-xs text-[var(--color-status-err)] p-3 v2-monitoring-panel" role="alert">${resource.state.value.error}</div>`
  }

  if (!response?.memory_os) {
    return html`
      <div class="p-3 text-xs text-[var(--color-fg-muted)] v2-monitoring-panel">
        Memory OS recall source 없음
      </div>
    `
  }

  return html`
    <div class="p-2 v2-monitoring-surface">
      <${MemoryOsRecallSourcePanel} snapshot=${response.memory_os} rows=${response.entries} />
    </div>
  `
}

function DiffSection({ diff }: { diff: TurnBlockDiff }) {
  const empty =
    diff.added.length === 0 && diff.removed.length === 0 && diff.changed.length === 0
  if (empty) {
    return html`<div class="text-2xs text-[var(--color-fg-disabled)] v2-monitoring-row">이전 턴과 블록 변화 없음</div>`
  }
  return html`
    <div class="space-y-1 v2-monitoring-row">
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

/* ═══════════════════════════════════════════════════════════════════════
   Keeper Turn Inspector v2 detail drawer
   ═══════════════════════════════════════════════════════════════════════ */

type TurnDetail = {
  tokIn: number | null
  tokOut: number | null
  // RFC-0233 §8 — null when the observations needed for the ratio are absent.
  ctxPct: number | null
  contextWindow: number | null
  requestLatencyMs: number | null
  ttfrcMs: number | null
}

function thinkingStateLabel(record: TurnRecordEntry): string {
  if (record.enable_thinking === true) return 'enabled'
  if (record.enable_thinking === false) return 'disabled'
  return 'unknown'
}

function thinkingChipLabel(record: TurnRecordEntry): string {
  if (record.enable_thinking === true) return 'on'
  if (record.enable_thinking === false) return 'off'
  return '—'
}

function formatObservedTokens(value: number | null): string {
  return value != null ? value.toLocaleString() : '측정 없음'
}

function formatContextWindow(value: number | null): string {
  return value != null ? `${value.toLocaleString()} tok` : '미상'
}

function formatObservedDuration(value: number | null): string {
  return value != null ? formatMsCompact(value) : '측정 없음'
}

function buildTurnDetail(record: TurnRecordEntry): TurnDetail {
  const tokIn = record.input_tokens ?? null
  const tokOut = record.output_tokens ?? null
  // RFC-0233 §8 — context fill is a transparent projection of two recorded
  // observations. Missing input usage or context window stays unknown.
  const ctxPct =
    tokIn != null && record.context_window != null && record.context_window > 0
      ? (tokIn / record.context_window) * 100
      : null

  return {
    tokIn,
    tokOut,
    ctxPct,
    contextWindow: record.context_window ?? null,
    requestLatencyMs: record.request_latency_ms ?? null,
    ttfrcMs: record.ttfrc_ms ?? null,
  }
}

function CopyBtn({ text, label = '복사' }: { text: string; label?: string }) {
  const [status, setStatus] = useState<'idle' | 'done' | 'failed'>('idle')
  const onClick = async (e: Event) => {
    e.stopPropagation()
    try {
      if (!navigator.clipboard) throw new Error('clipboard API unavailable')
      await navigator.clipboard.writeText(text)
      setStatus('done')
    } catch {
      setStatus('failed')
    }
    setTimeout(() => setStatus('idle'), 1200)
  }
  return html`
    <button class="kti-copy ${status}" onClick=${onClick}>
      ${status === 'done' ? '\u2713 복사됨' : status === 'failed' ? '복사 실패' : '\u2398 ' + label}
    </button>
  `
}

function TimelineTab({ t }: { t: TurnDetail }) {
  const latencyObserved = t.requestLatencyMs != null
  return html`
    <div class="kti-sec">
      <div class="kti-sec-h">
        <h4>Provider 요청 관측</h4>
        <span class="n">request_latency_ms · ${latencyObserved ? '실측' : '측정 없음'}</span>
      </div>
      <div class="kti-wf">
        <div class="kti-wf-row">
          <div class="kti-wf-lbl">
            <span class="kti-wf-ico kti-k-provider"></span>
            <span class="nm" title="OAS inference_telemetry.request_latency_ms">Provider request wall-clock</span>
          </div>
          <div class="kti-wf-track">
            ${latencyObserved
              ? html`<span class="kti-wf-observed" data-testid="turn-provider-latency-observed">OAS inference telemetry</span>`
              : html`<span class="kti-wf-unmeasured" data-testid="turn-provider-latency-unmeasured">측정 없음</span>`}
          </div>
          <span class="kti-wf-dur" title="request_latency_ms — provider call wall-clock (OAS inference_telemetry)">${formatObservedDuration(t.requestLatencyMs)}</span>
        </div>
      </div>
      <div class="kti-wf-foot">
        <span>source · OAS inference_telemetry</span>
        <span>request wall-clock <b>${formatObservedDuration(t.requestLatencyMs)}</b> · TTFRC <b>${formatObservedDuration(t.ttfrcMs)}</b></span>
      </div>
    </div>
  `
}

// Lazy-loaded transcript state for the open turn (RFC-0233 §7). Distinct from
// `null` (not yet requested) so the renderer can show loading vs absence.
type TranscriptView =
  | { kind: 'loading' }
  | { kind: 'error'; message: string }
  | { kind: 'loaded'; data: TurnTranscript }

// Map the async-resource state to a transcript view. Error wins over a stale
// data value; absence of both reads as still-loading (the lazy fetch fires on
// drawer open).
function toTranscriptView(state: {
  loading: boolean
  error: string | null
  data: TurnTranscript | null
}): TranscriptView {
  if (state.error) return { kind: 'error', message: state.error }
  if (state.data) return { kind: 'loaded', data: state.data }
  return { kind: 'loading' }
}

// One operator request line. Renders the real persisted content; explicit
// absence when the turn carried no joinable user row.
function OperatorLine({ line, seq }: { line: TurnTranscriptLine | null; seq: number }) {
  return html`
    <div class="kti-msg">
      <div class="kti-msg-h">
        <span class="kti-msg-role user">user</span>
        <span class="who">operator</span>
        <span class="seq">#${seq}</span>
      </div>
      ${line
        ? html`<div class="kti-msg-b" data-testid="turn-transcript-user">${line.content}</div>`
        : html`<div class="kti-msg-b kti-msg-absent" data-testid="turn-transcript-user-absent">
            operator 요청이 이 턴에 기록되지 않았습니다 (turn_ref 미연결 또는 보존 윈도 밖)
          </div>`}
    </div>
  `
}

// One keeper response line. A transport-failure row is labelled distinctly and
// never presented as the keeper's own utterance.
function KeeperLine({
  keeperName,
  line,
  seq,
}: {
  keeperName: string
  line: TurnTranscriptLine | null
  seq: number
}) {
  const isFailure = line?.kind === 'transport_failure'
  return html`
    <div class="kti-msg">
      <div class="kti-msg-h">
        <span class="kti-msg-role assistant">assistant</span>
        <span class="who">${keeperName}</span>
        ${isFailure
          ? html`<span class="pill bad" data-testid="turn-transcript-assistant-failure">transport failure</span>`
          : null}
        <span class="seq">#${seq}</span>
      </div>
      ${line
        ? html`<div class="kti-msg-b" data-testid="turn-transcript-assistant">${line.content}</div>`
        : html`<div class="kti-msg-b kti-msg-absent" data-testid="turn-transcript-assistant-absent">
            keeper 응답이 이 턴에 기록되지 않았습니다
          </div>`}
    </div>
  `
}

function MessagesTab({
  keeperName,
  transcript,
}: {
  keeperName: string
  transcript: TranscriptView
}) {
  let seq = 0
  const userLines = transcript.kind === 'loaded' ? transcript.data.user : []
  const assistantLines = transcript.kind === 'loaded' ? transcript.data.assistant : []
  const messageCount = userLines.length + assistantLines.length
  return html`
    <div class="kti-sec">
      <div class="kti-sec-h">
        <h4>턴 전사 관측</h4>
        <span class="n">
          ${transcript.kind === 'loaded'
            ? `${messageCount} 메시지 · ${transcript.data.source}`
            : '전사 미확정'}
        </span>
      </div>
      ${transcript.kind === 'loading'
        ? html`<div class="text-2xs text-[var(--color-fg-muted)] px-1 pb-1" data-testid="turn-transcript-loading">전사 불러오는 중…</div>`
        : null}
      ${transcript.kind === 'error'
        ? html`<div class="text-2xs text-[var(--color-status-warn)] px-1 pb-1" data-testid="turn-transcript-error">전사 불러오기 실패 · ${transcript.message}</div>`
        : null}
      ${transcript.kind === 'loaded'
        ? html`
          <div class="kti-seq-rail">
            ${userLines.length
              ? userLines.map(line => html`<${OperatorLine} line=${line} seq=${++seq} />`)
              : html`<${OperatorLine} line=${null} seq=${++seq} />`}
            ${assistantLines.length
              ? assistantLines.map(line => html`<${KeeperLine} keeperName=${keeperName} line=${line} seq=${++seq} />`)
              : html`<${KeeperLine} keeperName=${keeperName} line=${null} seq=${++seq} />`}
          </div>
        `
        : null}
    </div>
  `
}

function MetaTab({ record, t, source }: { record: TurnRecordEntry; t: TurnDetail; source: string }) {
  return html`
    <div class="kti-sec">
      <div class="kti-sec-h"><h4>샘플링 파라미터</h4></div>
      <div class="kti-params">
        <span class="kti-param">temperature<b>${record.temperature ?? '—'}</b></span>
        <span class="kti-param">top_p<b>${record.top_p ?? '—'}</b></span>
        <span class="kti-param">max_tokens<b>${record.max_tokens?.toLocaleString() ?? '—'}</b></span>
        <span class="kti-param">thinking_budget<b>${record.thinking_budget ?? '—'}</b></span>
        <span class="kti-param">enable_thinking<b>${thinkingChipLabel(record)}</b></span>
      </div>
      <div class="kti-sec-h" style=${{ marginTop: '16px' }}><h4>실행 메타데이터</h4></div>
      <div class="kti-kv">
        <span class="k">model</span><span class="v">${record.model ?? 'n/a'}</span>
        <span class="k">runtime</span><span class="v">${record.runtime_profile}</span>
        <span class="k">input tokens</span><span class="v">${formatObservedTokens(t.tokIn)}</span>
        <span class="k">output tokens</span><span class="v">${formatObservedTokens(t.tokOut)}</span>
        <span class="k">ctx window${record.context_window != null ? '' : ' · 미상'}</span><span class="v">${t.ctxPct != null ? `${t.ctxPct.toFixed(1)}% / ${formatContextWindow(t.contextWindow)}` : `비율 측정 없음 / ${formatContextWindow(t.contextWindow)}`}</span>
        <span class="k">keeper turn</span><span class="v">T${record.absolute_turn}</span>
        <span class="k">thinking</span><span class="v">${thinkingStateLabel(record)}</span>
        <span class="k">provider request wall-clock</span><span class="v">${formatObservedDuration(t.requestLatencyMs)}</span>
        <span class="k">time to first response chunk</span><span class="v">${formatObservedDuration(t.ttfrcMs)}</span>
        <span class="k">finish_reason</span><span class="v">${record.finish_reason ?? 'n/a'}</span>
        <span class="k">source</span><span class="v">${source}</span>
      </div>
    </div>
  `
}

const TABS: [string, string][] = [
  ['timeline', '타임라인'],
  ['messages', '메시지'],
  ['meta', '메타'],
]

function TurnDetailDrawer({
  keeperName,
  row,
  source,
  onClose,
}: {
  keeperName: string
  row: TurnRecordRow
  source: string
  onClose: () => void
}) {
  const [tab, setTab] = useState('timeline')
  const t = buildTurnDetail(row.record)
  const tokenSplit =
    t.tokIn != null && t.tokOut != null && t.tokIn + t.tokOut > 0
      ? {
          inputPct: (t.tokIn / (t.tokIn + t.tokOut)) * 100,
          outputPct: (t.tokOut / (t.tokIn + t.tokOut)) * 100,
        }
      : null

  // RFC-0233 §7: use the exact opaque join key recorded by the server. Loaded
  // per-open so the (potentially large) transcript never bloats the list.
  const turnRef = row.record.turn_ref
  const transcriptResource = useManagedAsyncResource<TurnTranscript | null>(null)
  useEffect(() => {
    void transcriptResource.load((signal) =>
      fetchKeeperTurnTranscript(keeperName, turnRef, { signal }),
    )
    return () => {
      transcriptResource.cancel()
    }
  }, [keeperName, turnRef, transcriptResource])

  const transcript = toTranscriptView(transcriptResource.state.value)

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.stopPropagation()
        onClose()
      }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [onClose])

  return html`
    <div
      class="kti-overlay"
      role="dialog"
      aria-modal="true"
      aria-label="턴 상세"
      onClick=${onClose}
      data-testid="turn-detail-drawer"
    >
      <div class="kti-drawer" onClick=${(e: Event) => e.stopPropagation()}>
        <div class="kti-head">
          <h3>턴 상세</h3>
          <span class="tid mono">${row.record.turn_ref}</span>
          <div class="kti-head-actions">
            <${CopyBtn} text=${row.record.turn_ref} label="turn_ref" />
            <button class="kti-close" onClick=${onClose} title="닫기 (Esc)">\u2715</button>
          </div>
        </div>

        <div class="kti-sub">
          <span class="kti-chip">
            <span class="sub-k">keeper</span>${keeperName}
          </span>
          <span class="kti-chip">
            <span class="sub-k">keeper turn</span>T${row.record.absolute_turn}
          </span>
          <span class="kti-chip${row.record.finish_reason ? ' ok' : ''}">
            <span class="sub-k">finish</span>${row.record.finish_reason ?? 'n/a'}
          </span>
          <span class="kti-chip">
            <span class="sub-k">runtime</span>${row.record.runtime_profile}
          </span>
        </div>

        <div class="kti-summary" data-testid="turn-summary-stats">
          <div class="kti-stat">
            <div class="k">Provider</div>
            <div class="v">${formatObservedDuration(t.requestLatencyMs)}</div>
          </div>
          <div class="kti-stat">
            <div class="k">입력</div>
            <div class="v">${formatObservedTokens(t.tokIn)}</div>
          </div>
          <div class="kti-stat">
            <div class="k">출력</div>
            <div class="v volt">${formatObservedTokens(t.tokOut)}</div>
          </div>
        </div>

        <div class="kti-tok" data-testid="turn-token-bar">
          <div class="kti-tok-top">
            <span class="lbl">토큰 관측</span>
            <span class="ctxpct">${t.ctxPct != null ? `컨텍스트 ${t.ctxPct.toFixed(1)}% / ${formatContextWindow(t.contextWindow)}` : `컨텍스트 비율 측정 없음 / ${formatContextWindow(t.contextWindow)}`}</span>
          </div>
          <div class="kti-tok-bar">
            ${tokenSplit
              ? html`
                <span class="seg-in" style=${{ width: `${tokenSplit.inputPct}%` }} />
                <span class="seg-out" style=${{ width: `${tokenSplit.outputPct}%` }} />
              `
              : html`
                <span class="kti-tok-unmeasured" data-testid="turn-token-split-unmeasured">
                  ${t.tokIn === 0 && t.tokOut === 0 ? '관측 합계 0' : '토큰 분할 측정 없음'}
                </span>
              `}
          </div>
          <div class="kti-tok-legend">
            <span class="in"><i></i>입력 <b>${formatObservedTokens(t.tokIn)}</b></span>
            <span class="out"><i></i>출력 <b>${formatObservedTokens(t.tokOut)}</b></span>
          </div>
        </div>

        <div class="kti-tabs" role="tablist" aria-label="턴 상세 탭">
          ${TABS.map(([id, lbl]) => html`
            <button
              key=${id}
              role="tab"
              aria-selected=${tab === id}
              class="kti-tab ${tab === id ? 'on' : ''}"
              onClick=${() => setTab(id)}
              data-testid="turn-tab-${id}"
            >
              ${lbl}
            </button>
          `)}
        </div>

        <div class="kti-body">
          ${tab === 'timeline' && html`<${TimelineTab} t=${t} />`}
          ${tab === 'messages' && html`<${MessagesTab} keeperName=${keeperName} transcript=${transcript} />`}
          ${tab === 'meta' && html`<${MetaTab} record=${row.record} t=${t} source=${source} />`}
        </div>
      </div>
    </div>
  `
}

function TurnRow({
  row,
  onOpen,
}: {
  row: TurnRecordRow
  onOpen: (row: TurnRecordRow) => void
}) {
  const record = row.record
  const tokens =
    record.input_tokens != null || record.output_tokens != null
      ? `${record.input_tokens ?? '?'}→${record.output_tokens ?? '?'} tok`
      : null
  const sampling = [
    record.temperature != null ? `t=${record.temperature}` : null,
    record.top_p != null ? `p=${record.top_p}` : null,
    record.max_tokens != null ? `tok=${record.max_tokens}` : null,
  ].filter(Boolean)

  return html`
    <details class="rounded-[var(--r-1)] hover:bg-[var(--color-bg-surface)] transition-colors v2-monitoring-row">
      <summary
        class="kti-turn-summary list-none cursor-pointer flex items-center gap-2 py-1.5 px-2 flex-wrap"
        onClick=${(e: Event) => {
          // Only open the drawer on direct summary clicks, not on the expand chevron area.
          if (e.target === e.currentTarget || (e.target as HTMLElement).closest('.kti-turn-summary') === e.currentTarget) {
            onOpen(row)
          }
        }}
      >
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
          블록 ${record.blocks.length}
        </span>
        ${row.diff_vs_prev
          && (row.diff_vs_prev.added.length > 0
            || row.diff_vs_prev.removed.length > 0
            || row.diff_vs_prev.changed.length > 0)
          ? html`<span class="text-3xs font-mono text-[var(--color-status-warn)]">
              +${row.diff_vs_prev.added.length} −${row.diff_vs_prev.removed.length} Δ${row.diff_vs_prev.changed.length}
            </span>`
          : null}
        <span class="open-hint">턴 상세</span>
      </summary>
      <div class="px-3 pb-2 space-y-2 v2-monitoring-panel">
        <div>
          <div class="text-3xs uppercase tracking-wider text-[var(--color-fg-disabled)] mb-1">
            컨텍스트 블록 (조립 순서)
          </div>
          ${record.blocks.length === 0
            ? html`<div class="text-2xs text-[var(--color-fg-disabled)] v2-monitoring-row">기록된 블록 없음</div>`
            : record.blocks.map(block => html`<${BlockRow} block=${block} />`)}
        </div>
        <div>
          <div class="text-3xs uppercase tracking-wider text-[var(--color-fg-disabled)] mb-1">
            이전 턴 대비
          </div>
          ${row.diff_vs_prev
            ? html`<${DiffSection} diff=${row.diff_vs_prev} />`
            : html`<div class="text-2xs text-[var(--color-fg-disabled)] v2-monitoring-row">같은 trace의 이전 턴 없음</div>`}
        </div>
      </div>
    </details>
  `
}

export function KeeperTurnInspector({
  keeperName,
  initialTurnRef,
}: {
  keeperName: string
  // RFC-0233 §7: exact turn join key from the originating chat row / board post.
  initialTurnRef?: string | null
}) {
  const resource = useManagedAsyncResource<TurnRecordsResponse | null>(null)
  const [selectedRow, setSelectedRow] = useState<TurnRecordRow | null>(null)
  const [initialMatchState, setInitialMatchState] = useState<'idle' | 'matched' | 'missed'>('idle')
  const appliedInitialTurnKey = useRef<string | null>(null)

  useEffect(() => {
    void resource.load(signal => fetchKeeperTurnRecords(keeperName, 50, { signal }))
    return () => {
      resource.cancel()
    }
  }, [keeperName, resource])

  const response = resource.state.value.data
  const rows = response?.entries ?? EMPTY_TURN_RECORD_ROWS
  // Server returns oldest-first; show newest first.
  const sorted = useMemo(() => [...rows].reverse(), [rows])
  const initialMatchedRow = useMemo(
    () => initialTurnRowForTurnRef(rows, initialTurnRef),
    [rows, initialTurnRef],
  )
  const initialTurnKey = initialTurnRef ?? null

  useEffect(() => {
    appliedInitialTurnKey.current = null
    setInitialMatchState('idle')
    setSelectedRow(null)
  }, [keeperName, initialTurnKey])

  useEffect(() => {
    if (
      !initialTurnKey
      || rows.length === 0
      || appliedInitialTurnKey.current === initialTurnKey
    ) {
      return
    }

    setSelectedRow(initialMatchedRow)
    setInitialMatchState(initialMatchedRow ? 'matched' : 'missed')
    appliedInitialTurnKey.current = initialTurnKey
  }, [initialTurnKey, initialMatchedRow, rows.length])

  if (resource.state.value.loading) {
    return html`<${LoadingState}>턴 레코드 불러오는 중...<//>`
  }

  if (resource.state.value.error) {
    return html`<div class="text-xs text-[var(--color-status-err)] p-4 v2-monitoring-panel" role="alert">${resource.state.value.error}</div>`
  }

  const memoryOsPanel = response?.memory_os
    ? html`<${MemoryOsRecallSourcePanel} snapshot=${response.memory_os} rows=${rows} />`
    : null

  if (rows.length === 0) {
    return html`
      <div class="p-4 space-y-1 v2-monitoring-panel">
        ${memoryOsPanel}
        <div class="text-xs text-[var(--color-fg-muted)]">턴 레코드 없음 (서버 재시작 이후 keeper 턴까지 기록됩니다)</div>
        <${FreshnessLine} data=${response ?? { source: 'turn_record' }} />
      </div>
    `
  }

  return html`
    <div class="p-2 space-y-1 v2-monitoring-surface">
      <div class="flex items-center justify-between px-1 v2-monitoring-toolbar">
        <${FreshnessLine} data=${response} />
        ${response && response.skipped_rows > 0
          ? html`<span class="text-3xs text-[var(--color-status-warn)]">
              malformed ${response.skipped_rows}행 제외됨
            </span>`
          : null}
      </div>
      ${memoryOsPanel}
      ${initialMatchState === 'missed'
        ? html`
          <div
            class="rounded-[var(--r-1)] border border-[var(--color-status-warn)]/40 bg-[var(--color-bg-surface)] px-2 py-1.5 text-2xs text-[var(--color-fg-muted)] v2-monitoring-row"
            data-testid="turn-linked-empty"
          >
            연결된 turn record를 찾지 못했습니다. 리스트에서 직접 선택하세요.
          </div>
        `
        : null}
      ${sorted.map(row => html`<${TurnRow}
        key=${`${row.record.trace_id}-${row.record.absolute_turn}-${row.record.ts}`}
        row=${row}
        onOpen=${setSelectedRow}
      />`)}
      ${selectedRow
        ? html`<${TurnDetailDrawer}
            keeperName=${keeperName}
            row=${selectedRow}
            source=${response?.source ?? 'turn_record'}
            onClose=${() => setSelectedRow(null)}
          />`
        : null}
    </div>
  `
}
