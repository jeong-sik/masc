// Terminal — AX molecule for agent console output.
//
// Kimi design system sec02 reference: 2.1.3 terminal with ANSI color.
// Fallback div renderer (no xterm.js) for zero-dependency bundles.

import { html } from 'htm/preact'

export interface TerminalLine {
  text: string
}

interface TerminalProps {
  lines: TerminalLine[]
  prompt?: string
  testId?: string
}

interface Segment {
  text: string
  color?: string
  bold?: boolean
}

function ansiColor(code: number, bold: boolean): string | undefined {
  switch (code) {
    case 30:
      return bold ? 'var(--color-fg-secondary)' : 'var(--color-fg-muted)'
    case 31:
      return 'var(--error-10)'
    case 32:
      return 'var(--ok-10)'
    case 33:
      return 'var(--warn-10)'
    case 34:
      return 'var(--color-accent)'
    case 35:
      return 'var(--color-accent)'
    case 36:
      return 'var(--ok-10)'
    case 37:
      return 'var(--color-fg-primary)'
    case 39:
      return undefined
    default:
      return undefined
  }
}

function parseAnsi(input: string): Segment[] {
  const segments: Segment[] = []
  let current = ''
  let color: string | undefined
  let bold = false
  let i = 0

  while (i < input.length) {
    if (input[i] === '\x1b' && input[i + 1] === '[') {
      if (current) {
        segments.push({ text: current, color, bold })
        current = ''
      }
      const end = input.indexOf('m', i + 2)
      if (end === -1) {
        current += input[i]
        i += 1
        continue
      }
      const codes = input
        .slice(i + 2, end)
        .split(';')
        .map(Number)
      for (const c of codes) {
        if (c === 0) {
          color = undefined
          bold = false
        } else if (c === 1) {
          bold = true
        } else if (c >= 30 && c <= 39) {
          color = ansiColor(c, bold)
        }
      }
      i = end + 1
    } else {
      current += input[i]
      i += 1
    }
  }

  if (current) {
    segments.push({ text: current, color, bold })
  }

  return segments
}

function renderLine(line: TerminalLine): ReturnType<typeof html> {
  const segments = parseAnsi(line.text)
  return html`
    <div class="min-h-[1.25em] text-xs font-mono leading-relaxed text-[var(--color-fg-primary)]">
      ${segments.map(
        (s, idx) => html`
          <span
            key=${idx}
            style=${{
              color: s.color,
              fontWeight: s.bold ? '600' : undefined,
            }}
            >${s.text}</span
          >
        `,
      )}
    </div>
  `
}

export function Terminal({ lines, prompt = 'agent:$ ', testId }: TerminalProps) {
  return html`
    <div
      class="h-64 overflow-auto rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-2 font-mono"
      data-terminal
      data-testid=${testId}
      role="log"
      aria-live="polite"
      aria-atomic="false"
      aria-label="에이전트 터미널"
    >
      ${lines.length === 0
        ? html`<div class="text-3xs text-[var(--color-fg-muted)]">출력 없음</div>`
        : html`<div class="space-y-0.5">${lines.map((l, i) => html`<div key=${i}>${renderLine(l)}</div>`)}</div>`}
      ${prompt
        ? html`
            <div class="mt-1 flex items-center gap-1 text-xs font-mono text-[var(--color-fg-secondary)]">
              <span class="text-[var(--color-accent)]">${prompt}</span>
              <span class="inline-block h-3.5 w-0.5 animate-pulse bg-[var(--color-fg-primary)]"></span>
            </div>
          `
        : null}
    </div>
  `
}
