// Activity tab — Recent messages and events

import { html } from 'htm/preact'
import { TimeAgo } from './common/time-ago'
import { messages } from '../store'
import type { Message } from '../types'

function MessageRow({ msg }: { msg: Message }) {
  return html`
    <div class="message-row">
      <span class="message-author">${msg.from ?? 'system'}</span>
      <span class="message-content">${msg.content}</span>
      <${TimeAgo} timestamp=${msg.timestamp} />
    </div>
  `
}

export function Activity() {
  const msgList = messages.value

  return html`
    <div class="section">
      <h2>Recent Activity</h2>
      <div class="message-list">
        ${msgList.length === 0
          ? html`<div class="empty-state">No recent activity</div>`
          : msgList.slice(0, 50).map((m, i) =>
              html`<${MessageRow} key=${i} msg=${m} />`
            )}
      </div>
    </div>
  `
}
