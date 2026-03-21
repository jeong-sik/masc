// Agent detail journal stream — real-time activity stream filtered by agent

import { html } from 'htm/preact'
import { Card } from './common/card'
import { TimeAgo } from './common/time-ago'
import { agentJournalEntries, compactCopy, journalKindIcon } from './agent-detail-state'
import type { JournalEntry } from '../types'

export function AgentJournalStream({ agentName }: { agentName: string }) {
  const entries = agentJournalEntries(agentName)

  return html`
    <${Card} title="실시간 활동 스트림">
      ${entries.length === 0
        ? html`<div class="empty-state">관련 이벤트 없음</div>`
        : html`
            <div class="agent-journal-stream">
              ${entries.map((entry: JournalEntry, idx: number) => html`
                <div class="agent-journal-entry" key=${idx}>
                  <span class="agent-journal-kind">${journalKindIcon(entry)}</span>
                  <span class="agent-journal-type">${entry.eventType}</span>
                  <span class="agent-journal-text">${compactCopy(entry.text, 120) ?? ''}</span>
                  ${entry.timestamp ? html`<${TimeAgo} timestamp=${entry.timestamp} />` : null}
                </div>
              `)}
            </div>
          `}
    <//>
  `
}
