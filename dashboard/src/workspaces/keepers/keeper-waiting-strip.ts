/**
 * The Keeper's waiting inventory under the chat transcript.
 *
 * Rows of one kind (same `source` and `waiting_on`) collapse into one group
 * line with a count, so 123 tool-result receipts read as one line instead of
 * 123 cards. The server's step names (`next_action`) stay in a tooltip: they
 * name the server step that consumes the row, not something the operator does.
 */

import { html } from 'htm/preact'
import { formatElapsedCompact, formatWaitingSourceLabel } from './chat-blocks'
import type { KeeperWaitingInventoryData, KeeperWaitingRow } from './types'

/** Member lines shown when a group is opened. The rest is counted. */
const GROUP_MEMBER_LIMIT = 50

export interface KeeperWaitingGroup {
  readonly key: string
  readonly source: string
  readonly waitingOn: string
  /** The rows' shared sentence, or null when the rows say different things. */
  readonly sharedWhat: string | null
  readonly rows: readonly KeeperWaitingRow[]
  /** Earliest `since` among the rows, in unix seconds. */
  readonly earliestSince: number | null
  readonly nextActions: readonly string[]
}

/** Groups rows by kind, keeping the server's row order for the first member. */
export function groupWaitingRows(rows: readonly KeeperWaitingRow[]): readonly KeeperWaitingGroup[] {
  const order: string[] = []
  const byKey = new Map<string, KeeperWaitingRow[]>()
  for (const row of rows) {
    const key = `${row.source}\u0000${row.waiting_on}`
    const members = byKey.get(key)
    if (members) {
      members.push(row)
    } else {
      byKey.set(key, [row])
      order.push(key)
    }
  }
  return order.map((key) => {
    const members = byKey.get(key)!
    const first = members[0]!
    const sinceValues = members.flatMap((row) => (row.since === null ? [] : [row.since]))
    return {
      key,
      source: first.source,
      waitingOn: first.waiting_on,
      sharedWhat: members.every((row) => row.what === first.what) && first.what !== '' ? first.what : null,
      rows: members,
      earliestSince: sinceValues.length > 0 ? Math.min(...sinceValues) : null,
      nextActions: [...new Set(members.map((row) => row.next_action).filter((action) => action !== ''))],
    }
  })
}

/** The operator sentence for a group. Rows that say different things show the
 *  first one's sentence and how many more there are; the server's kind name
 *  is the last resort, when no row carries a sentence. */
function groupLabel(group: KeeperWaitingGroup): string {
  if (group.sharedWhat !== null) return group.sharedWhat
  const firstWhat = group.rows.find((row) => row.what !== '')?.what
  return firstWhat ? `${firstWhat} 외 ${group.rows.length - 1}건` : group.waitingOn
}

function ageLabel(since: number | null, nowUnix: number): string | null {
  if (since === null) return null
  return `${formatElapsedCompact(Math.max(0, nowUnix - since))} 전부터`
}

export function KeeperWaitingStrip(props: {
  readonly inventory: KeeperWaitingInventoryData
  readonly nowUnix: number
}) {
  const { inventory, nowUnix } = props
  const groups = groupWaitingRows(inventory.rows)
  const total = Math.max(inventory.total_row_count, inventory.rows.length)
  const unlisted = Math.max(0, total - inventory.rows.length)
  const preview = groups
    .slice(0, 3)
    .map((group) => (group.sharedWhat !== null ? `${group.sharedWhat} ${group.rows.length}건` : groupLabel(group)))
    .join(' · ')
  return html`
    <details class="kp-waiting-strip" data-testid="chat-waiting-strip">
      <summary class="kp-activity-group-summary">
        <span class="kp-pill" data-tone="warn">대기 ${total}건</span>
        ${inventory.oldest_age_seconds !== null && html`
          <span class="kp-pill" title="실제로 기다리는 항목 중 가장 오래된 것의 나이예요. 시각이 안 된 예약은 세지 않아요.">
            가장 오래 ${formatElapsedCompact(inventory.oldest_age_seconds)}
          </span>
        `}
        <span class="kp-block-preview">${preview}${groups.length > 3 ? ` 외 ${groups.length - 3}종` : ''}</span>
      </summary>
      <div class="kp-waiting-groups" data-testid="chat-waiting-groups">
        ${groups.map((group) => {
          const age = ageLabel(group.earliestSince, nowUnix)
          const shown = group.rows.slice(0, GROUP_MEMBER_LIMIT)
          const single = group.rows.length === 1 ? group.rows[0]! : null
          return html`
            <div
              key=${group.key}
              class="kp-waiting-group"
              data-waiting-source=${group.source}
              title=${group.nextActions.length > 0 ? `서버 다음 단계: ${group.nextActions.join(', ')}` : undefined}
            >
              <div class="kp-waiting-group-head">
                <span class="kp-pill" data-tone="brass">${formatWaitingSourceLabel(group.source)}</span>
                ${(group.sharedWhat !== null || group.rows.length === 1) && html`<span class="kp-waiting-what">${groupLabel(group)}</span>`}
                <span class="kp-waiting-count">${group.rows.length}건</span>
                ${age && html`<span class="kp-waiting-age">${age}</span>`}
              </div>
              ${single && single.detail_lines.map((line, index) => html`
                <div class="kp-block-status" key=${`detail:${index}`}>${line}</div>
              `)}
              ${group.sharedWhat === null && group.rows.length > 1 && html`
                <ul class="kp-waiting-members">
                  ${shown.map((row, index) => html`<li key=${`${index}:${row.what}`}>${row.what || row.waiting_on}</li>`)}
                  ${group.rows.length > shown.length && html`<li>+ ${group.rows.length - shown.length}건 더</li>`}
                </ul>
              `}
            </div>
          `
        })}
        ${unlisted > 0 && html`<div class="kp-block-status">+ 목록에 실리지 않은 ${unlisted}건</div>`}
      </div>
    </details>
  `
}
