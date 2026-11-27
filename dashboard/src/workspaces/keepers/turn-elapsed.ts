import { html } from 'htm/preact'
import { nowMs1sSignal, useNowMs1sTicker } from '../../lib/now-signal'
import { formatElapsedCompact } from './chat-blocks'

const TURN_ELAPSED_HINT = '턴 경과 시간'
const OPEN_WORK_SINCE_HINT = '이 상태로 지난 시간'

/** The clock in milliseconds, read again each second while `live`. */
export function useNowMs(live: boolean): number {
  useNowMs1sTicker(live)
  return live ? Math.max(nowMs1sSignal.value, Date.now()) : Date.now()
}

/** How long a running turn has run. While [live] it counts each second;
 *  otherwise it stops at the moment the turn was last observed. */
export function KeeperTurnElapsed({ startedAt, observedAt, live }: {
  readonly startedAt: number
  readonly observedAt: number
  readonly live: boolean
}) {
  const now = useNowMs(live)
  const elapsedAt = live ? Math.max(now, observedAt) : observedAt
  const seconds = (elapsedAt - startedAt) / 1000
  return html`<span class="kp-turn-elapsed" role="timer" aria-label=${TURN_ELAPSED_HINT} title=${TURN_ELAPSED_HINT}>${formatElapsedCompact(seconds)}</span>`
}

/** How long the state the progress line names has lasted. Drawn for a turn
 *  confirmed alive: a last observation says what was open, not for how long
 *  it still is. */
export function OpenWorkSince({ sinceUnix }: { readonly sinceUnix: number }) {
  const seconds = Math.max(0, useNowMs(true) / 1000 - sinceUnix)
  return html`<span class="kp-turn-elapsed" role="timer" aria-label=${OPEN_WORK_SINCE_HINT} title=${OPEN_WORK_SINCE_HINT}>${formatElapsedCompact(seconds)}</span>`
}
