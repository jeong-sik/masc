// Table of contents for a Wiki page body. The entries are the heading
// elements the Markdown renderer drew, read back from the DOM, and a click
// scrolls to the heading at the same index in a new read of the body. The list
// and the scroll targets come from one function over the drawn nodes: a raw
// `<h2>` in a page, which the document renderer lets through, is listed, and a
// `#` line in a fenced code block, drawn as text, is not.

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { useLayoutEffect, useRef, useState } from 'preact/hooks'
import './wiki-toc.css'

export type HeadingLevel = 1 | 2 | 3 | 4 | 5 | 6

const LEVEL_BY_TAG: ReadonlyMap<string, HeadingLevel> = new Map([
  ['H1', 1], ['H2', 2], ['H3', 3], ['H4', 4], ['H5', 5], ['H6', 6],
])

const HEADING_SELECTOR = [...LEVEL_BY_TAG.keys()].map((tag) => tag.toLowerCase()).join(', ')

/** A page with fewer headings than this has no table of contents. */
const TOC_MIN_HEADINGS = 2

export type TocEntry = {
  readonly level: HeadingLevel
  /** Steps below the highest heading level on the page; the entry is indented by it. */
  readonly depth: number
  readonly text: string
  readonly target: HTMLElement
}

/** What the list shows of an entry. The heading node is looked up again on click. */
type TocItem = Omit<TocEntry, 'target'>

/** The headings drawn under `body`, in document order. A heading with no text is left out. */
export function readTocEntries(body: ParentNode): readonly TocEntry[] {
  const found: Array<Omit<TocEntry, 'depth'>> = []
  for (const heading of body.querySelectorAll<HTMLElement>(HEADING_SELECTOR)) {
    const level = LEVEL_BY_TAG.get(heading.tagName)
    const text = heading.textContent?.replace(/\s+/g, ' ').trim() ?? ''
    if (level === undefined || text === '') continue
    found.push({ level, text, target: heading })
  }
  const top = Math.min(...found.map((entry) => entry.level))
  return found.map((entry) => ({ ...entry, depth: entry.level - top }))
}

/** Opens each closed `<details>` around the heading, so it has a box, then scrolls to it. */
function showHeading(target: HTMLElement): void {
  const closed = 'details:not([open])'
  for (
    let fold = target.closest<HTMLDetailsElement>(closed);
    fold;
    fold = fold.parentElement?.closest<HTMLDetailsElement>(closed) ?? null
  ) {
    fold.open = true
  }
  target.scrollIntoView({ block: 'start' })
}

/**
 * The page body with a table of contents of its headings. `source` is the
 * Markdown the children draw; the headings are read again when it changes.
 */
export function WikiBodyWithToc({ source, children }: {
  readonly source: string
  readonly children: ComponentChildren
}) {
  const bodyRef = useRef<HTMLDivElement>(null)
  const [items, setItems] = useState<readonly TocItem[]>([])
  // The headings exist only once the children are in the DOM, and the
  // renderer draws other ones only when `source` changes. Read in a layout
  // effect: its re-render runs before the browser paints, so a new page is
  // never shown with the entries of the one before.
  useLayoutEffect(() => {
    const entries = bodyRef.current ? readTocEntries(bodyRef.current) : []
    setItems(entries.map(({ level, depth, text }) => ({ level, depth, text })))
  }, [source])

  // A node read earlier can be replaced by an equal one while `source` stays
  // (hydrated embeds), so the heading is looked up when it is asked for.
  const showEntry = (index: number) => {
    const target = bodyRef.current ? readTocEntries(bodyRef.current)[index]?.target : undefined
    if (target) showHeading(target)
  }

  const shown = items.length >= TOC_MIN_HEADINGS
  return html`
    <div class="kn-wiki-body">
      <div class="kn-wiki-body-grid" data-toc=${shown ? 'shown' : 'none'}>
        ${shown && html`
          <nav class="kn-wiki-toc" aria-label="목차">
            <h3 class="kn-section-title">목차</h3>
            <ul class="kn-wiki-toc-list">
              ${items.map((item, index) => html`
                <li key=${index} style=${{ '--kn-toc-depth': item.depth }}>
                  <button type="button" class="kn-wiki-toc-entry" onClick=${() => showEntry(index)}>
                    ${item.text}
                  </button>
                </li>
              `)}
            </ul>
          </nav>
        `}
        <div ref=${bodyRef} class="kn-wiki-body-main">${children}</div>
      </div>
    </div>
  `
}
