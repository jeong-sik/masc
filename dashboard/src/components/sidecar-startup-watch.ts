// SidecarStartupWatch — surfaces "Start was clicked but the sidecar
// hasn't come online" without forcing the operator to open the log
// viewer manually.
//
// Backend POST /api/v1/sidecar/start always returns 202 (it just
// shells out to setsid+nohup). Whether the bridge actually came up is
// detected only by polling status. Without this banner the operator
// sees their click "succeed" via toast, then the rail stays bad, then
// they have to remember to open Logs and parse a stack trace.
//
// We mark a startAt timestamp from inside startSidecar (called by
// rail/onboarding/strip), then any render that includes
// StartupCheckBanner can decide whether to surface the warning based
// on (now - startAt) and the live `sidecarUp` flag.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useLayoutEffect, useState } from 'preact/hooks'
import { openSidecarLogs } from './sidecar-log-viewer'

/** How often the live counter in the banner re-renders. 1000ms matches
    the unit the banner displays ("N초 경과"), so the counter ticks
    precisely when the displayed seconds change.

    Reference — Grafana live counter + Stripe Dashboard "processing for
    N seconds" chrome: watching the number tick is how the operator
    knows the system hasn't silently stalled on them. Cheap: setInterval
    inside a component that only mounts during the 55s warning window. */
const LIVE_TICK_MS = 1000

const lastStartAt = signal<Record<string, number>>({})

/** Lower bound: don't flash the banner immediately on click. The pulse
    + 2s SSE refresh covers normal startup. Wait long enough that "ok"
    has had a chance to come back. */
const GRACE_MS = 5000
/** Upper bound: stop showing the banner after 60s — at that point the
    operator either fixed it or moved on. */
const MAX_MS = 60_000

export function markStartAttempt(connectorId: string) {
  lastStartAt.value = { ...lastStartAt.value, [connectorId]: Date.now() }
}

export function clearStartAttempt(connectorId: string) {
  if (!(connectorId in lastStartAt.value)) return
  const next = { ...lastStartAt.value }
  delete next[connectorId]
  lastStartAt.value = next
}

export function getStartAttempt(connectorId: string): number | null {
  return lastStartAt.value[connectorId] ?? null
}

export function resetStartupWatchState() {
  lastStartAt.value = {}
}

/** Pure decision: should we render the banner right now?
    Exposed so unit tests can pin the timing logic without DOM. */
export function shouldShowStartupWarning(
  startAt: number | null,
  sidecarUp: boolean,
  now: number = Date.now(),
): boolean {
  if (sidecarUp) return false
  if (startAt === null) return false
  const elapsed = now - startAt
  return elapsed >= GRACE_MS && elapsed <= MAX_MS
}

export function StartupCheckBanner({ connectorId, sidecarUp }: {
  connectorId: string
  sidecarUp: boolean
}) {
  const startAt = lastStartAt.value[connectorId] ?? null
  const visible = shouldShowStartupWarning(startAt, sidecarUp)

  // Local tick — causes the counter line to re-render once a second
  // while the banner is visible, independent of the parent's poll
  // cadence. Layout-effect variant so the interval is already armed by
  // the time a test dispatches a clock advance (keeps happy-dom tests
  // deterministic without rAF juggling).
  const [, setTick] = useState(0)
  useLayoutEffect(() => {
    if (!visible) return
    const id = setInterval(() => setTick(t => t + 1), LIVE_TICK_MS)
    return () => clearInterval(id)
  }, [visible])

  if (!visible) return null

  const elapsedSec = startAt !== null ? Math.floor((Date.now() - startAt) / 1000) : 0

  return html`
    <div
      class="mt-2 flex items-center gap-2 rounded-[var(--r-1)] border border-[var(--warn-20)] bg-[var(--warn-10)] px-3 py-2 text-2xs text-[var(--color-status-warn)]"
      data-startup-warning=${connectorId}
    >
      <span class="text-base leading-none" aria-hidden="true">⚠</span>
      <div class="min-w-0 flex-1">
        <div class="font-semibold" data-startup-warning-elapsed=${String(elapsedSec)}>기동 응답 없음 (${elapsedSec}s 경과)</div>
        <div class="text-3xs opacity-90">
          Start 요청은 보냈지만 sidecar가 online으로 올라오지 않았습니다.
          토큰 검증 실패 / 의존성 누락이 가장 흔한 원인 — 로그를 확인하세요.
        </div>
      </div>
      <button
        type="button"
        class="shrink-0 cursor-pointer rounded-[var(--r-1)] border border-[var(--warn-20)] bg-[var(--warn-10)] px-2 py-1 text-3xs uppercase tracking-4 text-[var(--color-status-warn)] hover:bg-[var(--warn-10)]"
        onClick=${() => {
          openSidecarLogs(connectorId)
          // Don't clear startAt yet — operator might toggle logs back closed
          // and the warning should still nag until MAX_MS or until the bridge
          // actually comes up.
        }}
      >📋 로그 열기</button>
      <button
        type="button"
        class="shrink-0 cursor-pointer rounded-[var(--r-1)] border border-[var(--warn-20)] px-1.5 py-0.5 text-base leading-none text-[var(--color-status-warn)]/70 hover:text-[var(--color-status-warn)]"
        aria-label="dismiss startup warning"
        onClick=${() => clearStartAttempt(connectorId)}
      >×</button>
    </div>
  `
}
