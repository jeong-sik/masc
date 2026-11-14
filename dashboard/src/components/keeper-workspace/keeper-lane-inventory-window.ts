// Keeper waiting rows in one windowed scroll list (#26606).
//
// A lane inventory has no client-side cap, so a Keeper that cannot consume can
// hold thousands of rows. Only the rows near the viewport are mounted; every
// server row stays reachable by scrolling.
//
// A row unmounts when it scrolls away, so what the operator did to it cannot
// live in its DOM. Which rows are open is kept here, and keyboard focus
// returns to the list when the focused row leaves.

import { html } from 'htm/preact'
import { useLayoutEffect, useMemo, useRef, useState } from 'preact/hooks'
import type { RefObject, VNode } from 'preact'
import type { DashboardKeeperWaitingRow } from '../../api'
import { VirtualList } from '../common/virtual-list'

const LIST_LABEL = '대기 나이순 작업 흐름'

/** Height the list assumes for a row it has not measured yet. A collapsed row
 *  with its gap is 40.25px under the app's full style set; this is the next
 *  whole pixel above it.
 *  The list replaces the estimate once a row mounts. An estimate above the
 *  real height shrinks the list under a jump to its end, which leaves the jump
 *  at the end; one below it grows the list and leaves the jump short of it. */
const COLLAPSED_ROW_PITCH_PX = 41

interface Item {
  key: string
  row: DashboardKeeperWaitingRow
}

interface Props {
  rows: readonly DashboardKeeperWaitingRow[]
  renderRow: (
    row: DashboardKeeperWaitingRow,
    expanded: boolean,
    onExpandedChange: (open: boolean) => void,
  ) => VNode
}

/** A row is the same row while its kind and its place in the list hold, as it
 *  was when every row had a DOM node of its own. The inventory names no row
 *  across a refresh: the queue gives a pending event a new exact-entry address
 *  each time it defers or reprioritizes that event, and an observation row
 *  changes its content while it stays the same wait. */
function listed(rows: readonly DashboardKeeperWaitingRow[]): { items: Item[]; keys: ReadonlySet<string> } {
  const items = rows.map((row, index) => ({ key: `${row.source}:${row.waiting_on}:${index}`, row }))
  return { items, keys: new Set(items.map(item => item.key)) }
}

function MountedRow({ host, first, children }: {
  host: RefObject<HTMLDivElement>
  /** The first row of the list has no row above it and so no gap above. */
  first: boolean
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
            ?.querySelector<HTMLElement>(`[aria-label="${LIST_LABEL}"]`)
            ?.focus({ preventScroll: true })
        }
      })
    }
  }, [host])
  // The list measures this wrapper, so the gap between two rows is part of it.
  // A short list clips each row to its wrapper, and the keyboard focus ring is
  // drawn just outside the row, so the room around a row belongs here: the
  // row gap above it and the list's right padding beside it. Below the row its
  // own grid gap leaves the same room. The first row starts at the list's top
  // edge, where the list has always cut the top of its ring.
  return html`<div ref=${ref} class=${first ? 'pr-1' : 'pr-1 pt-1'}>${children}</div>`
}

/** Scroll position and open rows belong to one mounted instance. A caller
 *  that switches Keepers keys this component by Keeper so both start fresh. */
export function KeeperLaneInventoryWindow({ rows, renderRow }: Props): VNode {
  const host = useRef<HTMLDivElement>(null)
  const { items, keys } = useMemo(() => listed(rows), [rows])
  const [openKeys, setOpenKeys] = useState<ReadonlySet<string>>(() => new Set())
  // A row that left the list is forgotten here, in the render that sees it
  // gone: the next row to take that place starts closed.
  const stillListed = [...openKeys].filter(key => keys.has(key))
  const open = stillListed.length === openKeys.size ? openKeys : new Set(stillListed)
  if (open !== openKeys) setOpenKeys(open)
  const setExpanded = (key: string, expanded: boolean) => {
    setOpenKeys(previous => {
      if (previous.has(key) === expanded) return previous
      const next = new Set(previous)
      if (expanded) next.add(key)
      else next.delete(key)
      return next
    })
  }
  const renderItem = (item: Item, index: number) => html`
    <${MountedRow} host=${host} first=${index === 0}>
      ${renderRow(item.row, open.has(item.key), expanded => setExpanded(item.key, expanded))}
    <//>
  `
  // min-w-0: a row wider than the list stays the list's problem, as it did
  // when the scroll list itself was the grid item, and does not widen the page.
  return html`
    <div ref=${host} class="min-w-0" data-testid="keeper-lane-graph">
      <${VirtualList}
        items=${items}
        getKey=${(item: Item) => item.key}
        renderItem=${renderItem}
        estimatedItemHeight=${COLLAPSED_ROW_PITCH_PX}
        className="max-h-[30rem] overflow-y-auto"
        scrollBox="self"
        tabIndex=${-1}
        ariaLabel=${LIST_LABEL}
      />
    </div>
  `
}
