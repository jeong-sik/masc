// Keeper waiting rows in one windowed scroll list (#26606).
//
// A lane inventory has no client-side cap, so a Keeper that cannot consume can
// hold thousands of rows. Only the rows near the viewport are mounted; every
// server row stays reachable by scrolling.
//
// A row unmounts when it scrolls away, so what the operator did to it cannot
// live in its DOM. Which rows are open is kept here by row identity, and
// keyboard focus returns to the list when the focused row leaves.

import { html } from 'htm/preact'
import { useLayoutEffect, useMemo, useRef, useState } from 'preact/hooks'
import type { RefObject, VNode } from 'preact'
import { parseKeeperEventQueueSourceAddress, type DashboardKeeperWaitingRow } from '../../api'
import { VirtualList } from '../common/virtual-list'

const LIST_LABEL = '대기 나이순 작업 흐름'

interface Item {
  key: string
  row: DashboardKeeperWaitingRow
}

interface Props {
  rows: readonly DashboardKeeperWaitingRow[]
  renderRow: (
    row: DashboardKeeperWaitingRow,
    index: number,
    expanded: boolean,
    onExpandedChange: (open: boolean) => void,
  ) => VNode
}

/** An event-queue row is identified by the exact-entry address the server
 *  gives it. Any other row has no server identity, so its whole content stands
 *  in for one. Rows with equal identities stay separate by their order. The
 *  key only tracks presentation state; it grants no action authority. */
function itemsWithKeys(rows: readonly DashboardKeeperWaitingRow[]): Item[] {
  const occurrences = new Map<string, number>()
  return rows.map(row => {
    const address = row.source === 'event_queue_pending'
      ? parseKeeperEventQueueSourceAddress(row.detail)
      : null
    const identity = address === null
      ? JSON.stringify(['observation', row])
      : JSON.stringify(['event', row.keeper_name, address.sourceRef, address.sourceIncarnation])
    const ordinal = occurrences.get(identity) ?? 0
    occurrences.set(identity, ordinal + 1)
    return { key: JSON.stringify([identity, ordinal]), row }
  })
}

function MountedRow({ host, children }: { host: RefObject<HTMLDivElement>; children: VNode }) {
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
  // The list measures this wrapper, so the gap between rows is part of it.
  return html`<div ref=${ref} class="pb-1">${children}</div>`
}

/** Scroll position and open rows belong to one mounted instance. A caller
 *  that switches Keepers keys this component by Keeper so both start fresh. */
export function KeeperLaneInventoryWindow({ rows, renderRow }: Props): VNode {
  const host = useRef<HTMLDivElement>(null)
  const items = useMemo(() => itemsWithKeys(rows), [rows])
  const [expandedKeys, setExpandedKeys] = useState<ReadonlySet<string>>(() => new Set())
  const setExpanded = (key: string, open: boolean) => {
    setExpandedKeys(previous => {
      if (previous.has(key) === open) return previous
      const next = new Set(previous)
      if (open) next.add(key)
      else next.delete(key)
      return next
    })
  }
  const renderItem = (item: Item, index: number) => html`
    <${MountedRow} host=${host}>
      ${renderRow(item.row, index, expandedKeys.has(item.key), open => setExpanded(item.key, open))}
    <//>
  `
  return html`
    <div ref=${host} data-testid="keeper-lane-graph">
      <${VirtualList}
        items=${items}
        getKey=${(item: Item) => item.key}
        renderItem=${renderItem}
        className="max-h-[30rem] overflow-y-auto pr-1"
        tabIndex=${-1}
        ariaLabel=${LIST_LABEL}
      />
    </div>
  `
}
