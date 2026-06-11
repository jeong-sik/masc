import { html } from 'htm/preact'
import { useEffect, useMemo, useState } from 'preact/hooks'
import type { CodeDocumentLine } from './code-document-store'
import { escapeRegExp } from '../../lib/format-string'

export interface FindOptions {
  readonly caseSensitive: boolean
  readonly wholeWord: boolean
}

export interface FindMatch {
  readonly line: number
  readonly text: string
  readonly before: string
  readonly match: string
  readonly after: string
}

export function IdeFindPanel({
  lines,
  filePath,
  onClose,
}: {
  readonly lines: ReadonlyArray<CodeDocumentLine>
  readonly filePath: string
  readonly onClose?: () => void
}) {
  const [query, setQuery] = useState('')
  const [caseSensitive, setCaseSensitive] = useState(false)
  const [wholeWord, setWholeWord] = useState(false)
  const [activeIndex, setActiveIndex] = useState(0)

  const matches = useMemo(
    () => currentFileFindMatches(lines, query, { caseSensitive, wholeWord }),
    [caseSensitive, lines, query, wholeWord],
  )

  useEffect(() => {
    setActiveIndex(0)
  }, [caseSensitive, filePath, query, wholeWord])

  useEffect(() => {
    if (activeIndex < matches.length || matches.length === 0) return
    setActiveIndex(matches.length - 1)
  }, [activeIndex, matches.length])

  const activeOrdinal = matches.length > 0 ? activeIndex + 1 : 0
  const canMove = matches.length > 1
  const move = (delta: number): void => {
    if (matches.length === 0) return
    setActiveIndex(index => (index + delta + matches.length) % matches.length)
  }

  return html`
    <div
      role="search"
      aria-label="Find in current file"
      data-testid="ide-find-panel"
      style=${{
        display: 'grid',
        gridTemplateColumns: 'minmax(0, 1fr)',
        alignItems: 'center',
        gap: 'var(--sp-2)',
        boxSizing: 'border-box',
        width: '100%',
        maxWidth: 'calc(100vw - 20px)',
        padding: 'var(--sp-2) var(--sp-3)',
        borderBottom: '1px solid var(--color-border-divider)',
        background: 'var(--color-bg-surface)',
        color: 'var(--color-fg-muted)',
        font: 'var(--type-body)',
        fontSize: 'var(--fs-11)',
      }}
    >
      <div
        style=${{
          gridColumn: '1 / -1',
          display: 'flex',
          alignItems: 'center',
          flexWrap: 'wrap',
          gap: 'var(--sp-1)',
          minWidth: 0,
        }}
      >
        <input
          type="search"
          aria-label="Find query"
          placeholder="Find in current file"
          value=${query}
          onInput=${(event: Event) => setQuery((event.target as HTMLInputElement).value)}
          style=${{
            flex: '1 1 100px',
            minWidth: 0,
            maxWidth: '280px',
            height: '28px',
            font: 'var(--type-body)',
            fontSize: 'var(--fs-11)',
            color: 'var(--color-fg-primary)',
            background: 'var(--color-bg-elevated)',
            border: '1px solid var(--color-border-default)',
            borderRadius: 'var(--r-1)',
            padding: '0 var(--sp-2)',
            outline: 'none',
          }}
        />
        <${ToggleButton}
          label="Aa"
          pressed=${caseSensitive}
          onClick=${() => setCaseSensitive(value => !value)}
        />
        <${ToggleButton}
          label="Word"
          pressed=${wholeWord}
          onClick=${() => setWholeWord(value => !value)}
        />
        <button
          type="button"
          aria-label="Previous match"
          disabled=${!canMove}
          onClick=${() => move(-1)}
          style=${findButtonStyle(!canMove)}
        >Prev</button>
        <button
          type="button"
          aria-label="Next match"
          disabled=${!canMove}
          onClick=${() => move(1)}
          style=${findButtonStyle(!canMove)}
        >Next</button>
        ${onClose ? html`
          <button
            type="button"
            aria-label="Close find panel"
            onClick=${onClose}
            style=${findButtonStyle(false)}
          >Close</button>
        ` : null}
      </div>
      <div
        role="status"
        data-testid="ide-find-status"
        style=${{
          gridColumn: '1 / -1',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          flexWrap: 'wrap',
          gap: 'var(--sp-2)',
          color: 'var(--color-fg-muted)',
          minWidth: 0,
        }}
      >
        <span>${activeOrdinal} of ${matches.length} matches</span>
        <span
          style=${{
            minWidth: 0,
            overflow: 'hidden',
            textOverflow: 'ellipsis',
            whiteSpace: 'nowrap',
          }}
        >${filePath}</span>
      </div>
      ${query.trim() !== '' && matches.length > 0
        ? html`
            <ol
              role="list"
              aria-label="Find matches"
              data-testid="ide-find-results"
              style=${{
                gridColumn: '1 / -1',
                display: 'grid',
                gap: '2px',
                maxHeight: '112px',
                overflow: 'auto',
                margin: 0,
                padding: 0,
                listStyle: 'none',
              }}
            >
              ${matches.map((item, index) => html`
                <li
                  role="listitem"
                  aria-current=${index === activeIndex ? 'true' : undefined}
                  style=${{
                    display: 'grid',
                    gridTemplateColumns: '48px minmax(0, 1fr)',
                    gap: 'var(--sp-2)',
                    alignItems: 'baseline',
                    padding: '2px var(--sp-2)',
                    color: index === activeIndex ? 'var(--color-fg-primary)' : 'var(--color-fg-secondary)',
                    background: index === activeIndex ? 'var(--color-bg-elevated)' : 'transparent',
                    borderRadius: 'var(--r-1)',
                    fontFamily: 'var(--font-mono)',
                  }}
                >
                  <span style=${{ color: 'var(--color-fg-muted)' }}>${item.line}</span>
                  <code style=${{ minWidth: 0, overflowWrap: 'anywhere', whiteSpace: 'pre-wrap' }}>
                    ${item.before}<mark>${item.match}</mark>${item.after}
                  </code>
                </li>
              `)}
            </ol>
          `
        : null}
    </div>
  `
}

function ToggleButton({
  label,
  pressed,
  onClick,
}: {
  readonly label: string
  readonly pressed: boolean
  readonly onClick: () => void
}) {
  return html`
    <button
      type="button"
      aria-pressed=${pressed ? 'true' : 'false'}
      onClick=${onClick}
      style=${{
        height: '28px',
        padding: '0 var(--sp-2)',
        color: pressed ? 'var(--color-accent-fg)' : 'var(--color-fg-muted)',
        background: pressed ? 'var(--color-bg-elevated)' : 'transparent',
        border: '1px solid var(--color-border-default)',
        borderRadius: 'var(--r-1)',
        font: 'var(--type-eyebrow)',
        cursor: 'pointer',
      }}
    >${label}</button>
  `
}

function findButtonStyle(disabled: boolean): Record<string, string | number> {
  return {
    height: '28px',
    padding: '0 var(--sp-2)',
    color: disabled ? 'var(--color-fg-disabled)' : 'var(--color-fg-muted)',
    background: 'transparent',
    border: '1px solid var(--color-border-default)',
    borderRadius: 'var(--r-1)',
    font: 'var(--type-eyebrow)',
    cursor: disabled ? 'not-allowed' : 'pointer',
  }
}

export function currentFileFindMatches(
  lines: ReadonlyArray<CodeDocumentLine>,
  query: string,
  options: FindOptions,
): ReadonlyArray<FindMatch> {
  const needle = query.trim()
  if (needle === '') return []

  const flags = options.caseSensitive ? '' : 'i'
  const pattern = options.wholeWord
    ? `\\b${escapeRegExp(needle)}\\b`
    : escapeRegExp(needle)
  const regex = new RegExp(pattern, flags)
  const matches: FindMatch[] = []

  for (const line of lines) {
    const match = regex.exec(line.text)
    if (!match) continue
    matches.push({
      line: line.num,
      text: line.text,
      before: line.text.slice(0, match.index),
      match: match[0],
      after: line.text.slice(match.index + match[0].length),
    })
    if (matches.length >= 50) break
  }

  return matches
}
