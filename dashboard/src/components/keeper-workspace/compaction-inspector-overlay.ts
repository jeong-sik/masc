// MASC v2 — Compaction snapshot overlay (from context rail).
//
// Ported from rails.jsx CompactionInspector. Hydrates durable snapshots from
// the backend and keeps optimistic SSE/manual entries from the local store.
// Message/trace counts and kept/summarized/dropped details are not exposed, so
// those sections render an explicit data-gap note.

import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import type { VNode } from 'preact'
import type { Keeper } from '../../types'
import {
  fetchKeeperCompactionSnapshots,
  fetchKeeperTurnRecords,
  type TurnRecordRow,
} from '../../api/dashboard'
import {
  hydrateCompactionSnapshots,
  keeperCompactionSnapshots,
  type CompactionSnapshot,
} from './compaction-snapshots'

type CompactionReadError = {
  readonly scope: string
  readonly error: string
}

type CompactionSnapshotLoadState = {
  readonly loading: boolean
  readonly error: string | null
  readonly payloadCount: number | null
  readonly decodedCount: number | null
  readonly payloadSource: string | null
  readonly payloadProducer: string | null
  readonly payloadLimit: number | null
  readonly readErrorCount: number
  readonly readErrors: readonly CompactionReadError[]
  readonly scanTruncated: boolean
}

type PromptContextLoadState = {
  readonly loading: boolean
  readonly error: string | null
  readonly rows: readonly TurnRecordRow[]
  readonly count: number | null
  readonly health: string | null
  readonly source: string | null
  readonly producer: string | null
}

function isFiniteNumber(n: number | null | undefined): n is number {
  return typeof n === 'number' && Number.isFinite(n)
}

function fmtTok(n: number | null | undefined): string {
  if (!isFiniteNumber(n)) return '계측 없음'
  return n >= 1000 ? `${(n / 1000).toFixed(1)}k` : String(n)
}

function fmtBytes(n: number): string {
  if (n >= 1024 * 1024) return `${(n / (1024 * 1024)).toFixed(1)}MB`
  if (n >= 1024) return `${(n / 1024).toFixed(1)}KB`
  return `${n}B`
}

function shortDigest(digest: string): string {
  return digest.length > 12 ? digest.slice(0, 12) : digest
}

function CmpStat({
  label,
  a,
  b,
  unit,
  max,
}: {
  label: string
  a: number
  b: number
  unit?: 'k'
  max: number
}) {
  const fmt = (v: number) => (unit === 'k' ? (v / 1000).toFixed(1) + 'k' : String(v))
  return html`
    <div class="cmp-stat">
      <span class="cmp-stat-k">${label}</span>
      <div class="cmp-bars">
        <div class="cmp-line">
          <span class="t">before</span>
          <span class="v">${fmt(a)}</span>
        </div>
        <div class="cmp-bar before"><span style=${{ width: `${Math.min(100, (a / max) * 100)}%` }}></span></div>
        <div class="cmp-line">
          <span class="t">after</span>
          <span class="v ok">${fmt(b)}</span>
        </div>
        <div class="cmp-bar after"><span style=${{ width: `${Math.min(100, (b / max) * 100)}%` }}></span></div>
      </div>
    </div>
  `
}

function DataGapNote({ children }: { children: string }): VNode {
  return html`<div class="mem-empty" data-stub="compaction-detail">${children}</div>`
}

function CompactionScanDiagnostics({
  loadState,
}: {
  loadState: CompactionSnapshotLoadState
}): VNode | null {
  const shownErrors = loadState.readErrors.slice(0, 3)
  const hiddenErrorCount = Math.max(0, loadState.readErrorCount - shownErrors.length)
  if (loadState.readErrorCount <= 0 && !loadState.scanTruncated) return null
  return html`
    <div class="mem-read-error" role="status" data-testid="compaction-scan-diagnostics">
      <strong>스캔 진단</strong>
      ${loadState.readErrorCount > 0 ? html`<span>manifest row ${loadState.readErrorCount}개를 읽지 못했습니다.</span>` : null}
      ${loadState.scanTruncated ? html`<span>manifest scan budget에 도달했습니다.</span>` : null}
      ${shownErrors.length > 0
        ? html`
          <ul>
            ${shownErrors.map((err) => html`
              <li><code>${err.scope}</code>: ${err.error}</li>
            `)}
          </ul>
        `
        : null}
      ${hiddenErrorCount > 0 ? html`<span class="mono">+${hiddenErrorCount} more</span>` : null}
    </div>
  `
}

function CompactionCoverageStatus({
  loadState,
}: {
  loadState: CompactionSnapshotLoadState
}): VNode | null {
  if (loadState.loading || loadState.error) return null
  const payloadCount = loadState.payloadCount ?? 0
  const decodedCount = loadState.decodedCount ?? 0
  const source = loadState.payloadSource ?? 'unknown_source'
  const producer = loadState.payloadProducer ?? 'unknown_producer'
  const limit = loadState.payloadLimit ?? 0
  return html`
    <div class=${`cmp-coverage${loadState.scanTruncated ? ' warn' : ''}`} data-testid="compaction-coverage-status">
      <div class="cmp-coverage-main">
        <strong>durable hydrate</strong>
        <span>표시 ${decodedCount}/${payloadCount}</span>
        <span class="mono">source=${source}</span>
      </div>
      <div class="cmp-coverage-meta">
        <span class="mono">producer=${producer}</span>
        <span class="mono">limit=${limit}</span>
      </div>
      ${loadState.scanTruncated
        ? html`<div class="cmp-coverage-note">manifest scan이 모두 끝나기 전에 중단되어 더 오래된 snapshot은 누락될 수 있습니다.</div>`
        : null}
    </div>
  `
}

function CompactionEmptyState({
  keeperName,
  loadState,
}: {
  keeperName: string
  loadState: CompactionSnapshotLoadState
}): VNode {
  const payloadCount = loadState.payloadCount ?? 0
  const decodedCount = loadState.decodedCount ?? 0
  const source = loadState.payloadSource ?? 'unknown_source'
  const producer = loadState.payloadProducer ?? 'unknown_producer'
  const schemaDrift = payloadCount > 0 && decodedCount === 0
  return html`
    <div class="cmp-empty">
      <strong>${schemaDrift ? '표시 가능한 compaction snapshot이 없습니다.' : '아직 이 keeper에서 durable compaction snapshot이 없습니다.'}</strong><br />
      ${schemaDrift
        ? html`API는 ${keeperName} snapshot ${payloadCount}건을 보고했지만 대시보드 디코더가 표시 가능한 행 ${decodedCount}건만 수락했습니다.`
        : html`컨텍스트가 임계치를 넘거나 ‘지금 컴팩트’를 실행하면 새 결과가 기록됩니다.`}
      <br />
      <span class="mono">source=${source} · producer=${producer} · api_count=${payloadCount} · decoded=${decodedCount}</span>
    </div>
  `
}

function selectPromptContextRow(
  rows: readonly TurnRecordRow[],
  ev: CompactionSnapshot,
): { row: TurnRecordRow | null; linked: boolean } {
  const linked = rows.find((row) => {
    if (!ev.traceId || row.record.trace_id !== ev.traceId) return false
    return ev.keeperTurnId == null || row.record.absolute_turn === ev.keeperTurnId
  })
  if (linked) return { row: linked, linked: true }
  return { row: rows.length > 0 ? rows[rows.length - 1]! : null, linked: false }
}

function PromptContextEvidence({
  ev,
  loadState,
}: {
  ev: CompactionSnapshot
  loadState: PromptContextLoadState
}): VNode {
  if (loadState.loading) {
    return html`<div class="mem-empty mem-disclosure">최근 turn-records prompt blocks 불러오는 중...</div>`
  }
  if (loadState.error) {
    return html`<div class="mem-read-error" role="alert">turn-records 조회 실패 — ${loadState.error}</div>`
  }
  const { row, linked } = selectPromptContextRow(loadState.rows, ev)
  if (!row) {
    return html`<div class="mem-empty">최근 turn-records가 없어 주입 컨텍스트를 검산할 수 없습니다.</div>`
  }
  const blocks = row.record.blocks
  const totalBytes = blocks.reduce((sum, block) => sum + block.bytes, 0)
  const inputTok = row.record.input_tokens
  const ctxWin = row.record.context_window
  const pct = inputTok != null && ctxWin != null && ctxWin > 0
    ? Math.round((inputTok / ctxWin) * 100)
    : null
  const diff = row.diff_vs_prev
  return html`
    <div class="mem-compo" data-testid="compaction-prompt-context">
      <div class="mem-compo-head">
        <span class="mono mem-compo-tot">${fmtBytes(totalBytes)}</span>
        <span class="mem-compo-sub">
          ${inputTok != null
            ? html`${fmtTok(inputTok)} tok${ctxWin != null ? html` / ${fmtTok(ctxWin)} window` : null}${pct != null ? html` · ${pct}%` : null}`
            : html`${blocks.length} blocks`}
        </span>
      </div>
      <div class="mem-trust-sub mono">
        ${linked ? 'snapshot-linked turn-record' : 'latest turn-record'}
        · ${row.record.trace_id}#${row.record.absolute_turn}
        · ${loadState.source ?? 'turn_record'}${loadState.health ? ` · ${loadState.health}` : ''}
      </div>
      <div class="mem-trust-sub mono">${loadState.producer ?? 'keeper_turn_record_writer'}</div>
      ${!linked
        ? html`<div class="mem-empty mem-disclosure">선택한 snapshot trace가 최근 ${loadState.count ?? blocks.length}개 turn-records 안에 없어 최신 턴의 prompt block 증거를 표시합니다.</div>`
        : null}
      <div class="mem-legend">
        ${blocks.map((block) => html`
          <div key=${`${block.block}-${block.digest}`} class="mem-leg">
            <span class="mem-leg-sw" style=${{ background: 'var(--volt-dim)' }}></span>
            <span class="mem-leg-lbl">${block.block}</span>
            <span class="mem-leg-v mono">${fmtBytes(block.bytes)} · ${shortDigest(block.digest)}</span>
          </div>
        `)}
      </div>
      ${diff
        ? html`
          <div class="mem-prompt-foot">
            이전 턴 대비 added ${diff.added.length} · removed ${diff.removed.length} · changed ${diff.changed.length}
          </div>
        `
        : null}
      <div class="mem-prompt-foot">
        raw prompt text는 이 화면/API에서 노출하지 않습니다. 이 표는 실제 주입된 prompt block의 이름, 크기, digest 증거입니다.
      </div>
    </div>
  `
}

export function CompactionInspectorOverlay({
  keeper,
  onClose,
}: {
  keeper: Keeper
  onClose: () => void
}): VNode {
  const globalEvents = keeperCompactionSnapshots(keeper.name)
  const [hydratedState, setHydratedState] = useState<{ keeperName: string; events: CompactionSnapshot[] }>({
    keeperName: keeper.name,
    events: [],
  })
  const hydratedEvents = hydratedState.keeperName === keeper.name ? hydratedState.events : []
  const events = globalEvents.length > 0 ? globalEvents : hydratedEvents
  const [idx, setIdx] = useState(0)
  const [loadState, setLoadState] = useState<CompactionSnapshotLoadState>({
    loading: true,
    error: null,
    payloadCount: null,
    decodedCount: null,
    payloadSource: null,
    payloadProducer: null,
    payloadLimit: null,
    readErrorCount: 0,
    readErrors: [],
    scanTruncated: false,
  })
  const [promptContextState, setPromptContextState] = useState<PromptContextLoadState>({
    loading: true,
    error: null,
    rows: [],
    count: null,
    health: null,
    source: null,
    producer: null,
  })

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

  useEffect(() => {
    const controller = new AbortController()
    let active = true
    setLoadState({
      loading: true,
      error: null,
      payloadCount: null,
      decodedCount: null,
      payloadSource: null,
      payloadProducer: null,
      payloadLimit: null,
      readErrorCount: 0,
      readErrors: [],
      scanTruncated: false,
    })
    setHydratedState({ keeperName: keeper.name, events: [] })
    void fetchKeeperCompactionSnapshots(keeper.name, undefined, { signal: controller.signal })
      .then((payload) => {
        if (!active) return
        const next = hydrateCompactionSnapshots(keeper.name, payload.items)
        setHydratedState({ keeperName: keeper.name, events: next })
        setLoadState({
          loading: false,
          error: null,
          payloadCount: payload.count,
          decodedCount: payload.items.length,
          payloadSource: payload.source,
          payloadProducer: payload.producer,
          payloadLimit: payload.limit,
          readErrorCount: payload.read_error_count,
          readErrors: payload.read_errors,
          scanTruncated: payload.scan_truncated,
        })
      })
      .catch((err: unknown) => {
        if (!active) return
        if (err instanceof DOMException && err.name === 'AbortError') return
        setLoadState({
          loading: false,
          error: err instanceof Error ? err.message : String(err),
          payloadCount: null,
          decodedCount: null,
          payloadSource: null,
          payloadProducer: null,
          payloadLimit: null,
          readErrorCount: 0,
          readErrors: [],
          scanTruncated: false,
        })
      })
    return () => {
      active = false
      controller.abort()
    }
  }, [keeper.name])

  useEffect(() => {
    const controller = new AbortController()
    let active = true
    setPromptContextState({
      loading: true,
      error: null,
      rows: [],
      count: null,
      health: null,
      source: null,
      producer: null,
    })
    void fetchKeeperTurnRecords(keeper.name, 12, { signal: controller.signal })
      .then((payload) => {
        if (!active) return
        setPromptContextState({
          loading: false,
          error: null,
          rows: payload.entries,
          count: payload.count,
          health: payload.health ?? null,
          source: payload.source ?? null,
          producer: payload.producer ?? null,
        })
      })
      .catch((err: unknown) => {
        if (!active) return
        if (err instanceof DOMException && err.name === 'AbortError') return
        setPromptContextState({
          loading: false,
          error: err instanceof Error ? err.message : String(err),
          rows: [],
          count: null,
          health: null,
          source: null,
          producer: null,
        })
      })
    return () => {
      active = false
      controller.abort()
    }
  }, [keeper.name])

  if (events.length === 0) {
    return html`
      <div class="turn-overlay" onClick=${onClose}>
        <div class="turn-drawer" onClick=${(e: MouseEvent) => e.stopPropagation()}>
          <div class="turn-hd">
            <h3>컴팩션 스냅샷</h3>
            <span class="tid">${keeper.name}</span>
            <button type="button" class="turn-close" onClick=${onClose} title="닫기 (Esc)">${'✕'}</button>
          </div>
          <div class="turn-body">
            ${loadState.loading
              ? html`<div class="cmp-empty">컴팩션 스냅샷 불러오는 중…</div>`
              : loadState.error
                ? html`<div class="mem-read-error" role="alert">${'⚠'} 컴팩션 스냅샷 불러오기 실패 — ${loadState.error}</div>`
                : html`
                  <${CompactionCoverageStatus} loadState=${loadState} />
                  <${CompactionScanDiagnostics} loadState=${loadState} />
                  <${CompactionEmptyState} keeperName=${keeper.name} loadState=${loadState} />
                `}
          </div>
        </div>
      </div>
    `
  }

  const safeIdx = Math.max(0, Math.min(idx, events.length - 1))
  const ev = events[safeIdx]!
  const hasTokenPair = isFiniteNumber(ev.before.tok) && isFiniteNumber(ev.after.tok)
  const reduction = hasTokenPair && ev.before.tok > 0
    ? Math.round((1 - ev.after.tok / ev.before.tok) * 100)
    : null

  return html`
    <div class="turn-overlay" onClick=${onClose}>
      <div class="turn-drawer" onClick=${(e: MouseEvent) => e.stopPropagation()}>
        <div class="turn-hd">
          <h3>컴팩션 스냅샷</h3>
          <span class="tid">${keeper.name}</span>
          <button type="button" class="turn-close" onClick=${onClose} title="닫기 (Esc)">${'✕'}</button>
        </div>

        <div class="turn-tabs">
          ${events.map((e, i) => html`
            <button
              key=${e.id}
              type="button"
              class=${`turn-tab ${safeIdx === i ? 'on' : ''}`}
              onClick=${() => setIdx(i)}
            >
              ${e.at} <span class="mono" style=${{ opacity: 0.6 }}>${e.id}</span>
            </button>
          `)}
        </div>
        <div class="turn-body">
          ${loadState.loading
            ? html`<div class="mem-empty mem-disclosure">durable snapshot 새로고침 중…</div>`
            : loadState.error
              ? html`<div class="mem-read-error" role="alert">${'⚠'} durable snapshot 새로고침 실패 — ${loadState.error}</div>`
              : html`
                <${CompactionCoverageStatus} loadState=${loadState} />
                <${CompactionScanDiagnostics} loadState=${loadState} />
              `}
          <div class="cmp-trigger"><span class="sub-k">트리거</span>${ev.trigger}</div>
          <div class="cmp-trigger"><span class="sub-k">수행 런타임</span><span class="mono">${ev.runtime}</span></div>
          <div class="cmp-trigger"><span class="sub-k">소스</span><span class="mono">${ev.detailSource ?? ev.source}${ev.status ? ` · ${ev.status}` : ''}</span></div>
          ${ev.traceId
            ? html`<div class="cmp-trigger"><span class="sub-k">trace</span><span class="mono">${ev.traceId}${ev.keeperTurnId != null ? `#${ev.keeperTurnId}` : ''}</span></div>`
            : null}

          <div class="turn-sec">
            <h4>Before → After</h4>
            <div class="cmp-headline">
              <span class="mono">${fmtTok(ev.before.tok)}</span>
              <span class="cmp-arrow">${'→'}</span>
              <span class="mono" style=${{ color: 'var(--status-ok)' }}>${fmtTok(ev.after.tok)}</span>
              ${reduction != null ? html`<span class="cmp-reduce">${'−'}${reduction}%</span>` : null}
            </div>
            ${hasTokenPair
              ? html`<${CmpStat} label="토큰" a=${ev.before.tok} b=${ev.after.tok} unit="k" max=${Math.max(ev.before.tok, 1)} />`
              : html`<${DataGapNote}>이 snapshot은 compaction event는 확인하지만 before/after token count는 기록하지 않았습니다.</${DataGapNote}>`}
            ${ev.before.msgs != null && ev.after.msgs != null
              ? html`<${CmpStat} label="메시지" a=${ev.before.msgs} b=${ev.after.msgs} max=${Math.max(ev.before.msgs, 1)} />`
              : null}
            ${ev.before.traces != null && ev.after.traces != null
              ? html`<${CmpStat} label="trace" a=${ev.before.traces} b=${ev.after.traces} max=${Math.max(ev.before.traces, 1)} />`
              : null}
          </div>

          <div class="turn-sec">
            <h4>유지 · 요약 · 폐기</h4>
            ${ev.kept.length === 0 && ev.summarized.length === 0 && ev.dropped.length === 0
              ? html`<${DataGapNote}>현재 백엔드 projection은 kept / summarized / dropped 목록을 노출하지 않습니다. 이 snapshot은 "컴팩션 이벤트 발생"과 가능한 token 계측만 증명합니다.</${DataGapNote}>`
              : html`
                <div class="cmp-diff">
                  <div class="cmp-col kept">
                    <div class="cmp-col-h">${'◈'} 유지</div>
                    ${ev.kept.length
                      ? ev.kept.map((x, i) => html`<div key=${i} class="cmp-li">${x}</div>`)
                      : html`<div class="cmp-li">—</div>`}
                  </div>
                  <div class="cmp-col summ">
                    <div class="cmp-col-h">${'◉'} 요약</div>
                    ${ev.summarized.length
                      ? ev.summarized.map((x, i) => html`<div key=${i} class="cmp-li">${x}</div>`)
                      : html`<div class="cmp-li">—</div>`}
                  </div>
                  <div class="cmp-col drop">
                    <div class="cmp-col-h">${'◌'} 폐기</div>
                    ${ev.dropped.length
                      ? ev.dropped.map((x, i) => html`<div key=${i} class="cmp-li">${x}</div>`)
                      : html`<div class="cmp-li">—</div>`}
                  </div>
                </div>
              `}
          </div>

          <div class="turn-sec">
            <h4>최근 턴 주입 컨텍스트</h4>
            <${PromptContextEvidence} ev=${ev} loadState=${promptContextState} />
          </div>
        </div>
      </div>
    </div>
  `
}
