import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect, useMemo, useRef, useState } from 'preact/hooks'
import type { CodeDocumentLine } from './code-document-store'
import { escapeRegExp } from '../../lib/format-string'

export interface FindOptions {
  readonly caseSensitive: boolean
  readonly wholeWord: boolean
}

export interface FindMatch {
  readonly line: number
  /** 0-based offset of the match in the line. */
  readonly column: number
  readonly text: string
  readonly before: string
  readonly match: string
  readonly after: string
}

/**
 * The match the find panel has made current, for the editor to select and
 * scroll to. `seq` changes on every reveal so choosing the same match again
 * (a click on the active row) still moves the editor back to it.
 */
export interface FindReveal {
  readonly filePath: string
  readonly line: number
  readonly column: number
  readonly length: number
  readonly seq: number
}

export const ideFindReveal = signal<FindReveal | null>(null)

let revealSeq = 0

function revealMatch(filePath: string, match: FindMatch): void {
  revealSeq += 1
  ideFindReveal.value = {
    filePath,
    line: match.line,
    column: match.column,
    length: match.match.length,
    seq: revealSeq,
  }
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

  const inputRef = useRef<HTMLInputElement>(null)
  useEffect(() => {
    inputRef.current?.focus()
  }, [])

  // The editor follows the current match; closing the panel leaves the
  // selection where it is.
  const activeMatch = matches[activeIndex] ?? null
  useEffect(() => {
    if (activeMatch !== null) revealMatch(filePath, activeMatch)
  }, [activeMatch, filePath])
  useEffect(() => () => { ideFindReveal.value = null }, [])

  const activeOrdinal = matches.length > 0 ? activeIndex + 1 : 0
  const canMove = matches.length > 1
  const move = (delta: number): void => {
    if (matches.length === 0) return
    setActiveIndex(index => (index + delta + matches.length) % matches.length)
  }
  const choose = (index: number): void => {
    const match = matches[index]
    if (match === undefined) return
    if (index === activeIndex) revealMatch(filePath, match)
    else setActiveIndex(index)
  }
  const handleKeyDown = (event: KeyboardEvent): void => {
    // Committing an IME query uses Enter too; leave that key to the input.
    if (event.isComposing) return
    if (event.key === 'Enter') {
      event.preventDefault()
      move(event.shiftKey ? -1 : 1)
    } else if (event.key === 'Escape' && onClose) {
      event.preventDefault()
      onClose()
    }
  }

  return html`
    <div
      class="ide-find-panel v2-ide-panel"
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
          aria-keyshortcuts="Enter Shift+Enter Escape"
          placeholder="Find in current file"
          ref=${inputRef}
          value=${query}
          onInput=${(event: Event) => setQuery((event.target as HTMLInputElement).value)}
          onKeyDown=${handleKeyDown}
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
          class="v2-ide-action"
          aria-label="Previous match"
          disabled=${!canMove}
          onClick=${() => move(-1)}
          style=${findButtonStyle(!canMove)}
        >Prev</button>
        <button
          type="button"
          class="v2-ide-action"
          aria-label="Next match"
          disabled=${!canMove}
          onClick=${() => move(1)}
          style=${findButtonStyle(!canMove)}
        >Next</button>
        ${onClose ? html`
          <button
            type="button"
            class="v2-ide-action"
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
                  key=${`${item.line}:${item.column}`}
                  class="v2-ide-row"
                  role="listitem"
                  aria-current=${index === activeIndex ? 'true' : undefined}
                  onClick=${() => choose(index)}
                  style=${{
                    cursor: 'pointer',
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
      class="v2-ide-action"
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

  const flags = options.caseSensitive ? 'g' : 'gi'
  const pattern = options.wholeWord
    ? `\\b${escapeRegExp(needle)}\\b`
    : escapeRegExp(needle)
  const regex = new RegExp(pattern, flags)
  const matches: FindMatch[] = []

  // Every occurrence is a stop, so Next walks a line with two hits twice.
  for (const line of lines) {
    for (const match of line.text.matchAll(regex)) {
      matches.push({
        line: line.num,
        column: match.index,
        text: line.text,
        before: line.text.slice(0, match.index),
        match: match[0],
        after: line.text.slice(match.index + match[0].length),
      })
      if (matches.length >= 50) return matches
    }
  }

  return matches
}
