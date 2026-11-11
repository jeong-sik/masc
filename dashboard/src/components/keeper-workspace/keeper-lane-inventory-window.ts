import { html } from 'htm/preact'
import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'preact/hooks'
import type { RefObject, VNode } from 'preact'
import { parseKeeperEventQueueSourceAddress, type DashboardKeeperWaitingRow } from '../../api'
import { VirtualList } from '../common/virtual-list'

interface Item { key: string; row: DashboardKeeperWaitingRow }
interface Props {
  rows: DashboardKeeperWaitingRow[]
  renderRow: (row: DashboardKeeperWaitingRow, index: number, expanded: boolean, onExpandedChange: (open: boolean) => void) => VNode
}
const label = '대기 나이순 작업 흐름'

function itemsWithKeys(rows: DashboardKeeperWaitingRow[]): Item[] {
  const occurrences = new Map<string, number>()
  return rows.map(row => {
    const address = row.source === 'event_queue_pending' ? parseKeeperEventQueueSourceAddress(row.detail) : null
    // A diagnostic without a durable address keeps its complete observation.
    // Repeated identical rows remain separate; this key grants no action authority.
    const identity = address === null ? JSON.stringify(['observation', row])
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
      // A focused row may leave the window or the server inventory. Return
      // keyboard navigation to the same list after DOM removal; respect any
      // focus deliberately moved elsewhere during the commit.
      queueMicrotask(() => {
        if (doc.activeElement === doc.body || doc.activeElement === null) {
          host.current?.querySelector<HTMLElement>(`[aria-label="${label}"]`)?.focus({ preventScroll: true })
        }
      })
    }
  }, [host])
  // The dynamic virtualizer measures this gap along with expanded content.
  return html`<div ref=${ref} class="pb-1">${children}</div>`
}

/** Remount only this presentation state when the selected Keeper changes.
 *  Its owner leaves mutation/recovery state outside this keyed child. */
export function KeeperLaneInventoryWindow({ rows, renderRow }: Props): VNode {
  const host = useRef<HTMLDivElement>(null)
  const items = useMemo(() => itemsWithKeys(rows), [rows])
  const [expandedKeys, setExpandedKeys] = useState<ReadonlySet<string>>(new Set())
  useEffect(() => {
    const currentKeys = new Set(items.map(item => item.key))
    setExpandedKeys(previous => {
      const next = new Set([...previous].filter(key => currentKeys.has(key)))
      return next.size === previous.size ? previous : next
    })
  }, [items])
  const renderItem = (item: Item, index: number) => html`<${MountedRow} host=${host}>
    ${renderRow(item.row, index, expandedKeys.has(item.key), open => {
      setExpandedKeys(previous => {
        if (previous.has(item.key) === open) return previous
        const next = new Set(previous)
        if (open) next.add(item.key); else next.delete(item.key)
        return next
      })
    })}
  <//>`
  return html`<div ref=${host} data-testid="keeper-lane-graph">
    <${VirtualList} items=${items} estimatedItemHeight=${40}
      getKey=${(item: Item) => item.key} renderItem=${renderItem}
      className="max-h-[30rem] overflow-y-auto pr-1" tabIndex=${0} ariaLabel=${label} />
  </div>`
}
