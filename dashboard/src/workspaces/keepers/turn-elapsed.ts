import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { formatElapsedCompact } from './chat-blocks'

/** How long a running turn has run. While [live] it counts each second;
 *  otherwise it stops at the moment the turn was last observed. */
export function KeeperTurnElapsed({ startedAt, observedAt, live }: {
  readonly startedAt: number
  readonly observedAt: number
  readonly live: boolean
}) {
  const [now, setNow] = useState(Date.now)
  useEffect(() => {
    if (!live) return
    setNow(Date.now())
    const interval = window.setInterval(() => setNow(Date.now()), 1000)
    return () => window.clearInterval(interval)
  }, [live])
  const elapsedAt = live ? Math.max(now, observedAt) : observedAt
  const seconds = (elapsedAt - startedAt) / 1000
  return html`<span class="kp-turn-elapsed" role="timer" aria-label="턴 경과 시간">${formatElapsedCompact(seconds)}</span>`
}
