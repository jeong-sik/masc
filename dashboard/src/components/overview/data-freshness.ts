// Data freshness indicator for overview page.
// Shows when data was last updated, warns when stale (>5 min).

import { html } from 'htm/preact'
import { signal, computed } from '@preact/signals'
import { lastEvent, eventCount, connected } from '../../sse'
import { lastDashboardRefreshAt, refreshDashboard } from '../../store'
import { missionSnapshot } from '../../mission-store'
import { refreshRoomTruth } from '../../room-truth-store'

const STALE_THRESHOLD_SEC = 5 * 60 // 5 minutes

// Periodic tick (30s) forces re-render so relative time labels stay current
// between SSE events. Module-level singleton; cost is negligible.
const tick = signal(0)
setInterval(() => { tick.value++ }, 30_000)

/** Latest data timestamp in ms (from SSE event, API refresh, or mission snapshot). */
const latestDataTs = computed((): number | null => {
  // Depend on tick so the computed re-evaluates periodically
  void tick.value

  const candidates: number[] = []

  // SSE last event timestamp
  const evt = lastEvent.value
  if (evt && typeof evt.ts_unix === 'number') {
    candidates.push(evt.ts_unix * 1000)
  }

  // Dashboard API refresh timestamp (ISO string)
  const dashRefresh = lastDashboardRefreshAt.value
  if (dashRefresh) {
    const ts = Date.parse(dashRefresh)
    if (!Number.isNaN(ts)) candidates.push(ts)
  }

  // Mission snapshot generated_at (ISO string)
  const snap = missionSnapshot.value
  if (snap?.generated_at) {
    const ts = Date.parse(snap.generated_at)
    if (!Number.isNaN(ts)) candidates.push(ts)
  }

  if (candidates.length === 0) return null
  return Math.max(...candidates)
})

function formatRelativeTime(tsMs: number): string {
  const deltaSec = Math.max(0, Math.round((Date.now() - tsMs) / 1000))
  if (deltaSec < 10) return '방금'
  if (deltaSec < 60) return `${deltaSec}초 전`
  const deltaMin = Math.round(deltaSec / 60)
  if (deltaMin < 60) return `${deltaMin}분 전`
  const deltaHr = Math.round(deltaSec / 3600)
  return `${deltaHr}시간 전`
}

const refreshing = signal(false)

async function handleManualRefresh(): Promise<void> {
  if (refreshing.value) return
  refreshing.value = true
  try {
    await Promise.all([
      refreshRoomTruth({ force: true }),
      refreshDashboard({ force: true }),
    ])
  } catch (err) {
    console.warn('[DataFreshness] manual refresh failed', err instanceof Error ? err.message : err)
  } finally {
    refreshing.value = false
  }
}

export function DataFreshnessBar() {
  // Subscribe to reactive signals that drive this component
  void tick.value
  void eventCount.value

  const ts = latestDataTs.value
  const isConnected = connected.value
  const isRefreshing = refreshing.value

  // No data received and not connected
  if (ts === null && !isConnected) {
    return html`
      <div class="flex items-center justify-between gap-3 rounded-lg border border-[rgba(230,167,0,0.2)] bg-[rgba(230,167,0,0.05)] px-3 py-2 text-[12px]">
        <div class="flex items-center gap-2 text-[var(--warn)]">
          <span class="text-[14px]">\u25C9</span>
          <span class="font-medium">데이터 미수신</span>
        </div>
      </div>
    `
  }

  const deltaSec = ts !== null ? Math.max(0, Math.round((Date.now() - ts) / 1000)) : 0
  const isStale = ts !== null && deltaSec > STALE_THRESHOLD_SEC
  const label = ts !== null ? formatRelativeTime(ts) : '대기 중'

  const borderColor = isStale ? 'rgba(230,167,0,0.22)' : 'rgba(255,255,255,0.06)'
  const bgColor = isStale ? 'rgba(230,167,0,0.05)' : 'rgba(255,255,255,0.03)'
  const textClass = isStale ? 'text-[var(--warn)]' : 'text-[var(--text-muted)]'

  return html`
    <div
      class="flex items-center justify-between gap-3 rounded-lg px-3 py-1.5 text-[12px]"
      style="border:1px solid ${borderColor};background:${bgColor}"
    >
      <div class="flex items-center gap-2 ${textClass}">
        ${isStale
          ? html`<span class="text-[14px]">\u26A0</span>`
          : html`<span class="w-1.5 h-1.5 rounded-full bg-[var(--ok)] shrink-0"></span>`
        }
        <span class="font-medium">마지막 갱신: ${label}</span>
        ${isStale ? html`<span class="text-[11px] opacity-75">(5분 이상 경과)</span>` : null}
      </div>
      <button
        type="button"
        class="flex items-center gap-1.5 rounded-md px-2 py-1 text-[11px] font-medium text-[var(--text-muted)] cursor-pointer transition-colors duration-150 hover:text-[var(--text-strong)] disabled:opacity-40 disabled:cursor-default"
        style="border:1px solid rgba(255,255,255,0.08);background:rgba(255,255,255,0.04)"
        onClick=${() => void handleManualRefresh()}
        disabled=${isRefreshing}
        title="수동 새로고침"
      >
        <span class="${isRefreshing ? 'animate-spin' : ''}" style="display:inline-block">\u21BB</span>
        <span>${isRefreshing ? '갱신 중' : '새로고침'}</span>
      </button>
    </div>
  `
}
