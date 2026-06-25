import { currentDashboardActor, runOperatorAction } from '../api'
import { invalidateDashboardCache, refreshDashboard, refreshExecution } from '../store'
import { showToast } from './common/toast'
import { keeperRuntimeBlockerHint } from '../lib/keeper-runtime-display'
import type { Keeper } from '../types'

export async function runSocialSweep(): Promise<void> {
  try {
    await runOperatorAction({
      actor: currentDashboardActor(),
      action_type: 'social_sweep',
      target_type: 'root',
      payload: {},
    })
    invalidateDashboardCache()
    await refreshDashboard({ force: true })
    showToast('소셜 스위프 완료', 'success')
  } catch (err) {
    const message = err instanceof Error ? err.message : '소셜 스위프 실행 실패'
    showToast(message, 'error')
  }
}

export async function refreshAfterRuntimeAction(): Promise<void> {
  // Keeper runtime actions (boot/shutdown/resume/wakeup/pause from the rail,
  // alert strip, detail page and lifecycle buttons) reconcile against the
  // execution slice — the keeper roster — not the full dashboard bootstrap.
  // The previous `refreshDashboard({ force: true })` re-hydrated shell,
  // planning, namespace, goals and goal_loop and flipped dashboardLoading,
  // re-rendering every panel ("the whole screen refreshes when I resume a
  // keeper"). `force: true` keeps the immediate refetch boot/shutdown need
  // (those have no optimistic patch); the scope now matches the SSE
  // keeper_phase_changed route (sse-store.ts).
  void refreshExecution({ force: true }).catch(err => {
    const message = err instanceof Error ? err.message : '대시보드 새로고침 실패'
    showToast(message, 'warning')
  })
}

export function keeperNeedsDiagnosticAttention(keeper: Keeper): boolean {
  if (typeof keeper.needs_attention === 'boolean') return keeper.needs_attention
  const runtimeBlocker = keeperRuntimeBlockerHint(keeper)
  const blocker = keeper.last_blocker?.trim()
  const hbTs = keeper.last_heartbeat ? Date.parse(keeper.last_heartbeat) : null
  const hbAgeMs = hbTs != null && !Number.isNaN(hbTs) ? Date.now() - hbTs : null
  const hbStale = hbAgeMs != null && hbAgeMs > 300_000
  return keeper.paused
    || keeper.social_model_recognized === false
    || Boolean(runtimeBlocker)
    || Boolean(blocker)
    || hbStale
}
