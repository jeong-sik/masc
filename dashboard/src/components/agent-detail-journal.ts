// Agent detail journal stream — real-time activity stream filtered by agent

import { html } from 'htm/preact'
import { Card } from './common/card'
import { EmptyState } from './common/empty-state'
import { TimeAgo } from './common/time-ago'
import { agentJournalEntries, journalKindIcon } from './agent-detail-state'
import { trimText } from '../lib/truncate'
import type { JournalEntry } from '../types'

export function AgentJournalStream({ agentName }: { agentName: string }) {
  const entries = agentJournalEntries(agentName)

  return html`
    <${Card} title="실시간 활동 스트림">
      ${entries.length === 0
        ? html`<${EmptyState} message="아직 활동 기록이 없습니다" compact />`
        : html`
            <div role="log" aria-label="에이전트 활동 로그" class="flex flex-col gap-0.5 max-h-70 overflow-y-auto">
              ${entries.map((entry: JournalEntry, idx: number) => html`
                <div class="agent-journal-entry flex items-baseline gap-1.5 py-1 px-2 text-sm transition-[background] duration-[var(--t-fast)] rounded-[var(--r-1)] hover:bg-[var(--white-4)]" key=${idx}>
                  <span class="agent-journal-kind">${journalKindIcon(entry)}</span>
                  <span class="agent-journal-type">${entry.eventType}</span>
                  <span class="agent-journal-text">${trimText(entry.text, 120) ?? ''}</span>
                  ${entry.timestamp ? html`<${TimeAgo} timestamp=${entry.timestamp} />` : null}
                </div>
              `)}
            </div>
          `}
    <//>
  `
}
