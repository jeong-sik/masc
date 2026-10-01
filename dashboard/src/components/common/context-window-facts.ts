import { html } from 'htm/preact'
import type { TurnRecordEntry } from '../../api/dashboard-turn-records'
import { turnContextWindow } from '../../lib/turn-context-window'

export function ContextWindowFacts({ record }: { record: TurnRecordEntry }) {
  const { configured, reported } = turnContextWindow(record)
  return html`<span data-testid="context-window-facts">
    설정 ${configured?.toLocaleString() ?? '미상'} ·
    클라이언트 보고 ${reported?.toLocaleString() ?? '미측정'}
    ${reported !== null && configured !== null && reported !== configured
      ? html` · 설정과 다름` : null}
  </span>`
}
