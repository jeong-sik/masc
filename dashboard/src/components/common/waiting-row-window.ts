// What a windowed list of Keeper waiting rows needs besides VirtualList: a
// key per row and a row wrapper that keeps keyboard focus in the list. The
// lane strip's KeeperLaneInventoryWindow (#26606) and the age axis WaitAges
// (#51359) both draw a waiting inventory through it.

import { html } from 'htm/preact'
import { useLayoutEffect, useRef } from 'preact/hooks'
import type { RefObject, VNode } from 'preact'
import type { DashboardKeeperWaitingRow } from '../../api'

export interface KeyedWaitingRow {
  key: string
  row: DashboardKeeperWaitingRow
}

/** A row is the same row while its kind and its place in the list hold, as it
 *  was when every row had a DOM node of its own. The inventory names no row
 *  across a refresh: the queue gives a pending event a new exact-entry address
 *  each time it defers or reprioritizes that event, and an observation row
 *  changes its content while it stays the same wait.
 *  `rows` is the order the list draws, so the place is the drawn place. */
export function keyedWaitingRows(
  rows: readonly DashboardKeeperWaitingRow[],
): { items: KeyedWaitingRow[]; keys: ReadonlySet<string> } {
  const items = rows.map((row, index) => ({ key: `${row.source}:${row.waiting_on}:${index}`, row }))
  return { items, keys: new Set(items.map(item => item.key)) }
}

/** The wrapper of one drawn row. VirtualList unmounts a row that scrolls
 *  away, which would leave keyboard focus on the page body. */
export function WindowedWaitingRow({ host, listLabel, className, children }: {
  /** An element around the list, to find the list in. */
  host: RefObject<HTMLElement>
  /** The list's `aria-label`. */
  listLabel: string
  className: string
  children: VNode
}) {
  const ref = useRef<HTMLDivElement>(null)
  useLayoutEffect(() => {
    const element = ref.current
    return () => {
      if (element === null) return
      const doc = element.ownerDocument
      if (!element.contains(doc.activeElement)) return
      // The focused row is leaving the window or the server inventory. Once it
      // is out of the DOM, hand focus to the list so the keyboard keeps
      // scrolling it; focus moved elsewhere during the commit is left alone.
      queueMicrotask(() => {
        if (doc.activeElement === doc.body || doc.activeElement === null) {
          host.current
            ?.querySelector<HTMLElement>(`[aria-label="${listLabel}"]`)
            ?.focus({ preventScroll: true })
        }
      })
    }
  }, [host, listLabel])
  return html`<div ref=${ref} class=${className}>${children}</div>`
}
