// keeper-v2 design trace molecule — ported from prototypes/keeper-v2/molecules.jsx
// (Trace / TraceStepM) onto the live ChatTraceStep stream (src/types/core.ts).
// Same data ChatTraceBlock in chat/primitives.ts renders; this file carries the
// design's own class vocabulary (.trace / .tstep / .tnode / …) so the vendored
// keeper-v2 skin (src/styles/keeper-v2/v2.css) activates without aliases.

import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
import type { VNode } from 'preact'
import type { ChatTraceStep } from '../../types'
import { sanitizeHtml } from '../../lib/dompurify'
import { Dot } from '../v2/primitives-v2'

// JSON key/string tinting for the tool fold — .jk/.js are the vendored
// classes. Replacements run on the raw JSON before sanitizeHtml, matching
// highlightJson in chat/primitives.ts.
function highlightJson(raw: string): string {
  let parsed: unknown = null
  try {
    parsed = JSON.parse(raw)
  } catch {
    parsed = null
  }
  const text = parsed === null ? raw : JSON.stringify(parsed, null, 2)
  return sanitizeHtml(
    text
      .replace(/("[^"]+"):/g, '<span class="jk">$1</span>:')
      .replace(/: ("[^"]*")/g, ': <span class="js">$1</span>'),
  )
}

// Sum of tool step durations ("0.4s" strings) for the header meta — mirrors
// traceDur in chat/primitives.ts.
export function traceMoleculeDur(trace: ChatTraceStep[]): string | null {
  let sum = 0
  let has = false
  trace.forEach((st) => {
    if (st.kind !== 'tool') return
    const m = st.dur?.match(/([\d.]+)s/)
    if (m?.[1]) {
      sum += parseFloat(m[1])
      has = true
    }
  })
  return has ? `${Math.round(sum * 10) / 10}s` : null
}

function toolDotState(status: 'pending' | 'ok' | 'err' | undefined): 'ok' | 'bad' | 'busy' {
  if (status === 'err') return 'bad'
  if (status === 'pending') return 'busy'
  return 'ok'
}

function TraceStepMolecule({ step }: { step: ChatTraceStep }): VNode {
  const [open, setOpen] = useState(false)

  if (step.kind === 'think') {
    // RFC-0358 §2: server admitted the step without its reasoning — the row
    // marks the fact only, same wording as the chat transcript.
    const text = step.contentWithheld ? '내부 판단 단계 (내용 비공개)' : step.text
    return html`
      <div class="tstep think">
        <span class="tnode"></span>
        <div class="tstep-main">
          <div class="tstep-row">
            <span class="tstep-kind">Thinking</span>
            <span class="tstep-text">${text}</span>
          </div>
        </div>
      </div>
    `
  }

  if (step.kind === 'progress') {
    // No design counterpart; render with the think styling so the live
    // progress events stay visible instead of being dropped.
    return html`
      <div class="tstep think">
        <span class="tnode"></span>
        <div class="tstep-main">
          <div class="tstep-row">
            <span class="tstep-kind">Progress</span>
            <span class="tstep-text">${step.text}</span>
          </div>
        </div>
      </div>
    `
  }

  if (step.kind === 'reason') {
    const exp = !!step.detail
    return html`
      <div class="tstep reason ${open ? 'exp' : ''}">
        <span class="tnode"></span>
        <div class="tstep-main">
          <div class="tstep-row ${exp ? 'click' : ''}" onClick=${() => { if (exp) setOpen((o) => !o) }}>
            <span class="tstep-kind">Reasoning</span>
            <span class="tstep-text" dangerouslySetInnerHTML=${{ __html: sanitizeHtml(step.text) }} />
            ${exp ? html`<span class="chev sm">▶</span>` : null}
          </div>
          ${exp && open
            ? html`<div class="reason-detail" dangerouslySetInnerHTML=${{ __html: sanitizeHtml(step.detail ?? '') }} />`
            : null}
        </div>
      </div>
    `
  }

  const hasBody = step.args !== undefined || step.result !== undefined
  return html`
    <div class="tstep tool ${open ? 'exp' : ''}">
      <span class="tnode"></span>
      <div class="tstep-main">
        <div class="tstep-row ${hasBody ? 'click' : ''}" onClick=${() => { if (hasBody) setOpen((o) => !o) }}>
          <span class="tstep-kind">Tool</span>
          <span class="tname mono">${step.name}</span>
          <${Dot} state=${toolDotState(step.status)} />
          ${step.dur ? html`<span class="tdur mono">${step.dur}</span>` : null}
          ${hasBody ? html`<span class="chev sm">▶</span>` : null}
        </div>
        ${open && hasBody
          ? html`
              <div class="tool-body2">
                ${step.args !== undefined
                  ? html`<div class="tk">args</div><pre dangerouslySetInnerHTML=${{ __html: highlightJson(step.args) }} />`
                  : null}
                ${step.result !== undefined
                  ? html`<div class="tk">result</div><pre dangerouslySetInnerHTML=${{ __html: sanitizeHtml(step.result) }} />`
                  : null}
              </div>
            `
          : null}
      </div>
    </div>
  `
}

/** Design Trace fold — label/glyph header + railed steps. Consumes the live
 *  ChatTraceBlock payload; `omitted` mirrors the transcript's abridged marker. */
export function MoleculeTrace({
  trace,
  omitted = 0,
  label = '작업 과정',
  glyph = '◆',
  defaultOpen = true,
}: {
  trace: ChatTraceStep[]
  omitted?: number
  label?: string
  glyph?: string
  defaultOpen?: boolean
}): VNode {
  const [open, setOpen] = useState(defaultOpen)
  const toolN = trace.filter((s) => s.kind === 'tool').length
  const dur = traceMoleculeDur(trace)
  const meta: string[] = []
  if (toolN > 0) meta.push(`도구 ${toolN}`)
  if (dur) meta.push(dur)

  return html`
    <div class="trace ${open ? 'open' : ''}">
      <div class="trace-hd" onClick=${() => setOpen((o) => !o)}>
        <span class="chev">▸</span>
        <span class="glyph">${glyph}</span>
        <span class="tlabel">${label}</span>
        <span class="tcount">${trace.length}단계</span>
        ${meta.length > 0 ? html`<span class="tmeta">${meta.map((m) => html`<span class="mono">${m}</span>`)}</span>` : null}
      </div>
      <div class="trace-steps">
        <div class="trace-rail"></div>
        ${omitted > 0
          ? html`<div class="tstep-text">이 턴의 앞 ${omitted}단계는 대화 화면에 싣지 않았습니다 — 전체는 Turn Inspector의 raw trace에서 확인합니다.</div>`
          : null}
        ${trace.map((s, i) => html`<${TraceStepMolecule} key=${i} step=${s} />`)}
      </div>
    </div>
  `
}
