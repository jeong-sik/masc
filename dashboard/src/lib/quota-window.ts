/**
 * Shared SSOT quota window utilization predicates (mirrors server
 * `window_is_spent` in `lib/runtime/runtime_provider_usage_window.ml`).
 *
 * Used by Pulse (`pulse-quota.ts`), Runtime (`runtime/types.ts`, `quotas-tab.ts`).
 */

export type QuotaUtilizationLike =
  | { readonly unit: 'fraction'; readonly value: number }
  | { readonly unit: 'percent'; readonly value: number }
  | { readonly unit: 'usd'; readonly value: number; readonly limit: number | null }
  | { readonly unit: 'credit_balance'; readonly remaining: number }
  | { readonly unit: 'credit_unlimited' }
  | { readonly unit: 'credit_retracted' }

/**
 * Whether a window's utilization reached its hard limit (`window_is_spent`).
 * Returns `null` for a USD window without a limit (never spent) or retracted credit.
 */
export function isUtilizationSpent(u: QuotaUtilizationLike): boolean | null {
  switch (u.unit) {
    case 'fraction': return u.value >= 1
    case 'percent': return u.value >= 100
    case 'usd': return u.limit === null ? null : u.value >= u.limit
    case 'credit_balance': return u.remaining <= 0
    case 'credit_unlimited': return false
    case 'credit_retracted': return null
  }
}

/**
 * Whether a quota window reading is still refusing calls at `nowSec`.
 * A spent reading whose `resets_at` timestamp has already passed has reset.
 */
export function isWindowCurrentlySpent(
  window: { readonly utilization: QuotaUtilizationLike; readonly resets_at: number | null },
  nowSec: number = Date.now() / 1000,
): boolean {
  if (isUtilizationSpent(window.utilization) !== true) return false
  return window.resets_at === null || window.resets_at > nowSec
}
