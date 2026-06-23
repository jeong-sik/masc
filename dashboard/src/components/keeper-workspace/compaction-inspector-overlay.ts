// MASC v2 — Compaction snapshot overlay (from context rail).
//
// Ported from rails.jsx CompactionInspector. Uses the client-side
// compactionSnapshots store; only token counts are guaranteed from live data.
// Message/trace counts and kept/summarized/dropped details are not yet streamed
// by the backend, so those sections render an explicit data-gap note.

import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import type { VNode } from 'preact'
import type { Keeper } from '../../types'
import { keeperCompactionSnapshots, type CompactionSnapshot } from './compaction-snapshots'

function fmtTok(n: number): string {
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
    '전체 프롬프트 텍스트는 아직 백엔드에서 스트리밍되지 않습니다.',
  ]
  return lines.join('\n')
}

function DataGapNote({ children }: { children: string }): VNode {
  return html`<div class="mem-empty" data-stub="compaction-detail">${children}</div>`
}

export function CompactionInspectorOverlay({
  keeper,
  onClose,
}: {
  keeper: Keeper
  onClose: () => void
}): VNode {
  const events = keeperCompactionSnapshots(keeper.name)
  const [idx, setIdx] = useState(0)
  const [side, setSide] = useState<'before' | 'after'>('after')

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

  const ev = events[idx]!
  const reduction = Math.round((1 - ev.after.tok / Math.max(1, ev.before.tok)) * 100)

  return html`
    <div class="turn-overlay" onClick=${onClose}>
      <div class="turn-drawer" onClick=${(e: MouseEvent) => e.stopPropagation()}>
        <div class="turn-hd">
          <h3>컴팩션 스냅샷</h3>
          <span class="tid">${keeper.name}</span>
          <button type="button" class="turn-close" onClick=${onClose} title="닫기 (Esc)">${'✕'}</button>
        </div>

        ${events.length === 0
          ? html`
            <div class="turn-body">
              <div class="cmp-empty">
                아직 이 keeper에서 실행된 컴팩션이 없습니다.<br />
                컨텍스트가 임계치를 넘으면 자동으로 기록되며, ‘지금 컴팩트’를 눌러 수동 결과를 남길 수 있습니다.
              </div>
            </div>
          `
          : html`
            <div class="turn-tabs">
              ${events.map((e, i) => html`
                <button
                  key=${e.id}
                  type="button"
                  class=${`turn-tab ${idx === i ? 'on' : ''}`}
                  onClick=${() => setIdx(i)}
                >
                  ${e.at} <span class="mono" style=${{ opacity: 0.6 }}>${e.id}</span>
                </button>
              `)}
            </div>
            <div class="turn-body">
              <div class="cmp-trigger"><span class="sub-k">트리거</span>${ev.trigger}</div>
              <div class="cmp-trigger"><span class="sub-k">수행 런타임</span><span class="mono">${ev.runtime}</span></div>

              <div class="turn-sec">
                <h4>Before → After</h4>
                <div class="cmp-headline">
                  <span class="mono">${fmtTok(ev.before.tok)}</span>
                  <span class="cmp-arrow">${'→'}</span>
                  <span class="mono" style=${{ color: 'var(--status-ok)' }}>${fmtTok(ev.after.tok)}</span>
                  <span class="cmp-reduce">${'−'}${reduction}%</span>
                </div>
                <${CmpStat} label="토큰" a=${ev.before.tok} b=${ev.after.tok} unit="k" max=${Math.max(ev.before.tok, 1)} />
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
                  ? html`<${DataGapNote}>백엔드에서 아직 상세 분류(kept / summarized / dropped)를 병렬하지 않습니다.</${DataGapNote}>`
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
          `}
      </div>
    </div>
  `
}
