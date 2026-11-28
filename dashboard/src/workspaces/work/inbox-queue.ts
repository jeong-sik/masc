// The order of the Inbox queue and what a row says of its wait.
//
// The queue listed its four kinds one after another, each in the order its
// read returned it, and no row said how long it had waited: an item that had
// waited an hour sat under one that had just arrived, and a tool approval
// about to time out looked like any other row.
//
// A tool approval and a Keeper Ask say when they were asked. A Gate row says
// how long it had waited when the server answered. A Goal awaiting
// confirmation says neither, so it has no wait to show and keeps its place
// after the rows that do.

import { html } from 'htm/preact'
import { formatDuration } from '../../lib/format-time'
import { nowSecondsSignal, useNowSecondsTicker } from '../../lib/now-signal'
import { toolApprovalTimeout, type GatePendingItem, type InboxEntry } from './types'

const MS_PER_SECOND = 1000

/** When a row that says a Unix time in seconds began to wait. */
export function waitingSinceAskedAt(askedAt: number | null): number | null {
  return askedAt === null ? null : askedAt * MS_PER_SECOND
}

/** When a Gate row began to wait. The row's own `requestedAt` says it; `waitingSec`
 *  is derived from that when the server builds the payload and goes stale when the
 *  payload is cached, so the derived pair (`waitingSec` back from `readAtMs`, when
 *  the answer that carried it arrived) is only a fallback. */
export function waitingSinceGateRead(
  item: Pick<GatePendingItem, 'requestedAt' | 'waitingSec'>,
  readAtMs: number | null,
): number | null {
  if (item.requestedAt !== null) return item.requestedAt * MS_PER_SECOND
  return item.waitingSec === null || readAtMs === null ? null : readAtMs - item.waitingSec * MS_PER_SECOND
}

/** Longest wait first. An entry with no time comes after those, in the place it had. */
export function orderByWait(entries: readonly InboxEntry[]): InboxEntry[] {
  const timed: { readonly entry: InboxEntry; readonly since: number }[] = []
  const untimed: InboxEntry[] = []
  for (const entry of entries) {
    if (entry.waitingSinceMs === null) untimed.push(entry)
    else timed.push({ entry, since: entry.waitingSinceMs })
  }
  // Array.prototype.sort is stable: two entries asked at the same moment keep their order.
  timed.sort((a, b) => a.since - b.since)
  return [...timed.map((each) => each.entry), ...untimed]
}

/** What a row says of its wait at `nowMs`, or null for an entry with no time.
 *  A tool approval says first when its held call gives up, the one wait here
 *  that ends by itself. */
export function queueWaitText(entry: InboxEntry, nowMs: number): string | null {
  if (entry.waitingSinceMs === null) return null
  const waited = `${formatDuration(Math.max(0, (nowMs - entry.waitingSinceMs) / MS_PER_SECOND))}째 대기`
  if (entry.kind !== 'tool_approval') return waited
  const timeout = toolApprovalTimeout(entry.item, nowMs)
  switch (timeout.kind) {
    case 'unknown':
      return waited
    case 'pending':
      return `${formatDuration(timeout.remainingSec)} 뒤 시간 초과 · ${waited}`
    case 'expired':
      return `대기 한도 지남 · ${waited}`
  }
}

/** A queue row's wait, kept current by the shared 5 s clock. Only this
 *  element is drawn again on a tick, not the queue. */
export function QueueWait({ entry }: { readonly entry: InboxEntry }) {
  useNowSecondsTicker()
  const text = queueWaitText(entry, nowSecondsSignal.value * MS_PER_SECOND)
  if (text === null) return null
  return html`<span class="wk-row-wait tnum" data-testid="inbox-row-wait" title=${text}>${text}</span>`
}
