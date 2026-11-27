import { html } from 'htm/preact'
import { nowMs1sSignal, useNowMs1sTicker } from '../../lib/now-signal'
import { formatElapsedCompact } from './chat-blocks'

/** How long a running turn has run. While [live] it counts each second;
 *  otherwise it stops at the moment the turn was last observed. */
export function KeeperTurnElapsed({ startedAt, observedAt, live }: {
  readonly startedAt: number
  readonly observedAt: number
  readonly live: boolean
}) {
  useNowMs1sTicker(live)
  const now = live ? Math.max(nowMs1sSignal.value, Date.now()) : observedAt
  const elapsedAt = live ? Math.max(now, observedAt) : observedAt
  const seconds = (elapsedAt - startedAt) / 1000
  return html`<span class="kp-turn-elapsed" role="timer" aria-label="턴 경과 시간">${formatElapsedCompact(seconds)}</span>`
}
