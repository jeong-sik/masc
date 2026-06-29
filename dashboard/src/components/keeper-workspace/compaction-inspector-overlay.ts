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
import { fetchKeeperCompactionSnapshots } from '../../api/dashboard'
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

function isFiniteNumber(n: number | null | undefined): n is number {
  return typeof n === 'number' && Number.isFinite(n)
}

function fmtTok(n: number | null | undefined): string {
  if (!isFiniteNumber(n)) return '미수신'
  return n >= 1000 ? `${(n / 1000).toFixed(1)}k` : String(n)
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

function cmpFullCtx(ev: CompactionSnapshot, side: 'before' | 'after'): string {
  const tok = side === 'before' ? ev.before.tok : ev.after.tok
  const otherTok = side === 'before' ? ev.after.tok : ev.before.tok
  const label = side === 'before' ? '압축 전' : '압축 후'
  const lines = [
    `## ${label} 컨텍스트`,
    '',
    `- 총 토큰: ${fmtTok(tok)}`,
    `- 메시지 수: ${ev.before.msgs != null && ev.after.msgs != null ? String(side === 'before' ? ev.before.msgs : ev.after.msgs) : '미수신'}`,
    `- trace 수: ${ev.before.traces != null && ev.after.traces != null ? String(side === 'before' ? ev.before.traces : ev.after.traces) : '미수신'}`,
    `- 반대쪽: ${fmtTok(otherTok)}`,
    '',
    '전체 프롬프트 텍스트는 이 API에서 노출하지 않습니다.',
  ]
  return lines.join('\n')
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
  const [side, setSide] = useState<'before' | 'after'>('after')
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
              : html`<${DataGapNote}>이 snapshot에는 before/after token count가 없습니다.</${DataGapNote}>`}
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
              ? html`<${DataGapNote}>백엔드 API는 상세 분류(kept / summarized / dropped)와 raw prompt text를 노출하지 않습니다.</${DataGapNote}>`
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
            <h4>전체 컨텍스트 (실제 프롬프트)</h4>
            <div class="cmp-side-toggle">
              <button type="button" class=${`cmp-side ${side === 'before' ? 'on' : ''}`} onClick=${() => setSide('before')}>
                압축 전 · ${fmtTok(ev.before.tok)}
              </button>
              <button type="button" class=${`cmp-side ${side === 'after' ? 'on' : ''}`} onClick=${() => setSide('after')}>
                압축 후 · ${fmtTok(ev.after.tok)}
              </button>
            </div>
            <pre class="turn-pre cmp-ctx-pre">${cmpFullCtx(ev, side)}</pre>
          </div>
        </div>
      </div>
    </div>
  `
}
