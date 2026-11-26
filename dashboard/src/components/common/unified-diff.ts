import { html } from 'htm/preact'

export type UnifiedDiffLineKind = 'add' | 'del' | 'hunk' | 'ctx'

export function classifyUnifiedDiffLine(line: string): UnifiedDiffLineKind {
  if (line.startsWith('+') && !line.startsWith('+++')) return 'add'
  if (line.startsWith('-') && !line.startsWith('---')) return 'del'
  if (line.startsWith('@@')) return 'hunk'
  return 'ctx'
}

export function UnifiedDiffView(props: {
  readonly diffText: string
  readonly maxLines?: number
  readonly testId?: string
  readonly padding?: string
  readonly emptyLabel?: string
  readonly inline?: boolean
}) {
  if (!props.diffText) {
    return props.inline
      ? html`<span class="kp-diff-line">${props.emptyLabel ?? '(변경 사항 없음)'}</span>`
      : html`<pre class="mono" data-testid=${props.testId}>${props.emptyLabel ?? '(변경 사항 없음)'}</pre>`
  }
  const allLines = props.diffText.split('\n')
  const truncated = props.maxLines !== undefined && allLines.length > props.maxLines
  const lines = truncated ? allLines.slice(0, props.maxLines) : allLines

  if (props.inline) {
    return html`${lines.map((line, i) =>
      html`<span key=${i} class="kp-diff-line" data-kind=${classifyUnifiedDiffLine(line)}>${line}</span>`,
    )}`
  }

  return html`
    <pre
      class="mono"
      data-testid=${props.testId}
      style=${{
        margin: 0,
        padding: props.padding ?? 'var(--sp-3)',
        background: 'var(--bg-0)',
        border: '1px solid var(--line-1)',
        borderRadius: 'var(--radius-sm)',
        fontSize: 'var(--fs-11)',
        overflowX: 'auto',
        lineHeight: 1.45,
      }}
    >
      ${lines.map((line, idx) => {
        const kind = classifyUnifiedDiffLine(line)
        const style = kind === 'add'
          ? { display: 'block', background: 'var(--ok-soft)', color: 'var(--ok-fg)' }
          : kind === 'del'
            ? { display: 'block', background: 'var(--err-soft)', color: 'var(--err-fg)' }
            : kind === 'hunk'
              ? { display: 'block', color: 'var(--info-fg)' }
              : { display: 'block', color: 'var(--fg-2)' }
        return html`<span key=${idx} style=${style}>${line}</span>`
      })}
      ${truncated && html`
        <span style=${{ display: 'block', color: 'var(--fg-3)', marginTop: 'var(--sp-1)' }}>
          … (${allLines.length - (props.maxLines ?? 0)}줄 생략 · [⤢] 전체 보기 클릭)
        </span>
      `}
    </pre>
  `
}
