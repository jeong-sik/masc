// keeper-v2 design content-block molecules — CodeBlock / ShellBlock / MdTable
// from prototypes/keeper-v2/molecules.jsx, fed by the live chat block payloads
// (ChatCodeBlock / ChatShellBlock / ChatTableBlock in src/types/core.ts).

import { html } from 'htm/preact'
import type { VNode } from 'preact'
import type { ChatCodeBlock, ChatShellBlock, ChatShellLine, ChatTableBlock, ChatTableCellValue } from '../../types'
import { sanitizeHtml } from '../../lib/dompurify'

/** Design CodeBlock — caption bar + mono pre. The block html arrives
 *  pre-highlighted from the server; sanitize before injecting. */
export function MoleculeCodeBlock({ cap, html: htmlContent }: Pick<ChatCodeBlock, 'cap' | 'html'>): VNode {
  return html`
    <div class="code-block">
      ${cap ? html`<div class="code-cap mono">${cap}</div>` : null}
      <pre class="mono"><code dangerouslySetInnerHTML=${{ __html: sanitizeHtml(htmlContent) }} /></pre>
    </div>
  `
}

// Live shell lines carry t: 'cmd' | 'out' | 'err'; the design additionally has
// 'ok'/'dim' tones. 'out' maps to the untoned default line — it is neutral
// output, not a success marker.
function shellLineKind(t: ChatShellLine['t']): string {
  if (t === 'cmd') return 'cmd'
  if (t === 'err') return 'err'
  return ''
}

/** Design ShellBlock — terminal chrome + lines + exit code. */
export function MoleculeShellBlock({ title = 'keeper@worktree', lines, exit, dur }: ChatShellBlock): VNode {
  return html`
    <div class="shell-block">
      <div class="shell-bar">
        <span class="dot r"></span><span class="dot y"></span><span class="dot g"></span>
        ${title ? html`<span class="shell-title mono">${title}</span>` : null}
      </div>
      <pre class="mono">
        ${lines.map((ln, i) => {
          const kind = shellLineKind(ln.t)
          return html`
            <div key=${i} class="sh-ln ${kind}">
              ${ln.t === 'cmd' ? html`<span class="sh-prompt">$ </span>` : null}
              <span dangerouslySetInnerHTML=${{ __html: sanitizeHtml(ln.v) }} />
            </div>
          `
        })}
      </pre>
      ${typeof exit === 'number'
        ? html`<div class="shell-exit ${exit === 0 ? 'ok' : 'fail'}">exit ${exit}${dur ? ` · ${dur}` : ''}</div>`
        : null}
    </div>
  `
}

/** Design MdTable — head cells may carry { v, num }, body cells { v, num, muted }. */
export function MoleculeTable({ head, rows }: Pick<ChatTableBlock, 'head' | 'rows'>): VNode {
  const cell = (c: ChatTableCellValue) => (typeof c === 'object' ? c : { v: c })
  return html`
    <table class="md-table">
      <thead>
        <tr>
          ${head.map((h, i) => {
            const c = cell(h)
            return html`<th key=${i} class=${c.num ? 'num' : ''} dangerouslySetInnerHTML=${{ __html: sanitizeHtml(String(c.v)) }} />`
          })}
        </tr>
      </thead>
      <tbody>
        ${rows.map((row, ri) => html`
          <tr key=${ri}>
            ${row.map((c0, ci) => {
              const c = cell(c0)
              return html`<td
                key=${ci}
                class="${c.num ? 'num' : ''} ${c.muted ? 'muted' : ''}"
                dangerouslySetInnerHTML=${{ __html: sanitizeHtml(String(c.v)) }}
              />`
            })}
          </tr>
        `)}
      </tbody>
    </table>
  `
}
