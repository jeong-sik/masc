// keeper-v2 design broadcast molecule — Broadcast from
// prototypes/keeper-v2/molecules.jsx, fed by the live ChatBroadcastBlock
// (src/types/core.ts: scope/via/note/recipients with per-keeper ack state).
//
// Gaps vs the design (no live signal today — render only when a host passes
// the prop explicitly):
//   - `audience` (발화/기록 칩): ChatBroadcastBlock carries no audience field.
//   - recipient sigils: the design looks up window.KEEPERS for a Sigil; the
//     dashboard has no per-id sigil lookup on this surface, so recipients
//     render id-only — as the design does when the keeper is not found.

import { html } from 'htm/preact'
import type { VNode } from 'preact'
import type { ChatBroadcastBlock } from '../../types'

const BCAST_ACK: Record<string, string> = { acked: '확인함', read: '읽음', delivered: '전달됨' }

const BCAST_AUDIENCE: Record<string, [string, string]> = {
  speech: ['발화', '다른 keeper 대화창에도 뜸'],
  record: ['기록', '대화창에는 뜨지 않음 — 기록으로만 남음'],
}

export function MoleculeBroadcast({
  scope,
  via,
  note,
  recipients,
  tag = 'Broadcast',
  audience,
}: ChatBroadcastBlock & {
  tag?: string
  audience?: 'speech' | 'record'
}): VNode {
  const ackN = recipients.filter((r) => r.ack === 'acked').length
  const aud = audience ? BCAST_AUDIENCE[audience] : undefined
  return html`
    <div class="bcast">
      <div class="bcast-hd">
        <span class="bcast-tag">${tag}</span>
        ${aud ? html`<span class="bcast-aud ${audience}" title=${aud[1]}>${aud[0]}</span>` : null}
        ${scope ? html`<span class="bcast-scope mono">${scope}</span>` : null}
        ${via ? html`<span class="bcast-via mono">${via}</span>` : null}
        ${recipients.length > 0 ? html`<span class="bcast-count mono">${ackN}/${recipients.length} 확인</span>` : null}
      </div>
      ${note ? html`<div class="bcast-note">${note}</div>` : null}
      ${aud ? html`<div class="bcast-aud-note">${aud[1]}</div>` : null}
      ${recipients.length > 0
        ? html`
            <div class="bcast-rcpts">
              ${recipients.map((r, i) => html`
                <div key=${i} class="bcast-rcpt ${r.ack}">
                  <span class="bcast-rcpt-id">${r.id}</span>
                  <span class="bcast-ack">${BCAST_ACK[r.ack] || r.ack}${r.at ? ` · ${r.at}` : ''}</span>
                </div>
              `)}
            </div>
          `
        : null}
    </div>
  `
}
