import { refreshKeeperRuntimeStatus } from '../store'
import { showToast } from './common/toast'
import { keeperRuntimeBlockerHint } from '../lib/keeper-runtime-display'
import type { Keeper } from '../types'
import { keeperHeartbeatStaleMs } from '../config/constants'

export async function refreshAfterRuntimeAction(): Promise<void> {
  // Keeper runtime actions (boot/shutdown/resume/wakeup/pause from the rail,
  // alert strip, detail page and lifecycle buttons) reconcile against the
  // execution slice and the light shell runtime-health slice — not the full
  // dashboard bootstrap.
  // The previous `refreshDashboard({ force: true })` re-hydrated shell,
  // planning, namespace and goals and flipped dashboardLoading,
  // re-rendering every panel ("the whole screen refreshes when I resume a
  // keeper"). The shared refresh stays on the store scheduler so rapid
  // post-action clicks coalesce while shell runtime-health updates before the
  // execution projection is read.
  void refreshKeeperRuntimeStatus().catch(err => {
    const message = err instanceof Error ? err.message : '대시보드 새로고침 실패'
    showToast(message, 'warning')
  })
}

export function keeperNeedsDiagnosticAttention(keeper: Keeper): boolean {
  if (typeof keeper.needs_attention === 'boolean') return keeper.needs_attention
  const runtimeBlocker = keeperRuntimeBlockerHint(keeper)
  const hbTs = keeper.last_heartbeat ? Date.parse(keeper.last_heartbeat) : null
  const hbAgeMs = hbTs != null && !Number.isNaN(hbTs) ? Date.now() - hbTs : null
  const hbStale = hbAgeMs != null
    && hbAgeMs > keeperHeartbeatStaleMs(keeper.heartbeat_stale_after_s)
  return keeper.paused
    || Boolean(runtimeBlocker)
    || hbStale
}
