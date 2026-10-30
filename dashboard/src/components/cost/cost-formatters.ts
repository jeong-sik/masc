// RFC-0050 PR-1 — extracted from cost-dashboard.ts.
// Pure formatting helpers. No render dependencies.

/**
 * Cost-domain token count formatter. Distinct from `formatTokens` in
 * `lib/format-number.ts`:
 *   - 2-decimal M precision (cost dashboards want finer M-scale resolution)
 *   - lowercase `k` suffix (matches cost-dashboard column convention)
 *   - assumes caller passes a finite number (cost rows never feed null)
 *
 * Do NOT alias this to `formatTokens` — the two formatters intentionally
 * diverge. Same name with different output was the SSOT violation that
 * the 2026-05-27 dashboard SSOT audit closed by renaming this cost-domain
 * variant.
 */
export function formatCostTokens(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(2)}M`
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}k`
  return `${n}`
}

export function severityClass(sev: string): string {
  if (sev === 'error') return 'text-[var(--color-danger-fg)]'
  if (sev === 'warn') return 'text-[var(--color-warning-fg)]'
  return 'text-text-muted'
}
