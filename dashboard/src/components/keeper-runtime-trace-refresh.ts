import { signal } from '@preact/signals'

/*
 * Bumped whenever a keeper's runtime assignment is written (the config PATCH in
 * keeper-config-panel). Hooks that read the keeper runtime-trace evidence — the
 * right-rail "지정됨 X · 재시작 시 적용" drift badge — include this nonce in their
 * effect deps so they re-fetch immediately after a save instead of waiting up to
 * DEFAULT_PANEL_REFRESH_MS (30s) for the next visible-auto-refresh tick.
 *
 * refreshKeeperRuntimeStatus (store) only refreshes the LIVE runtime slice,
 * which by design does not change on save (the assignment is adopted at the next
 * turn-up); the drift badge is backed by the separate runtime-trace source,
 * which nothing on the save path was invalidating.
 */
export const keeperRuntimeTraceRefreshNonce = signal(0)

export function bumpKeeperRuntimeTraceRefresh(): void {
  keeperRuntimeTraceRefreshNonce.value += 1
}
