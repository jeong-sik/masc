// RFC-0050 PR-1 — extracted from cost-dashboard.ts.
// Pure formatting helpers. No render dependencies.

export function formatTokens(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(2)}M`
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}k`
  return `${n}`
}

export function severityClass(sev: string): string {
  if (sev === 'error') return 'text-[var(--color-danger-fg)]'
  if (sev === 'warn') return 'text-[var(--color-warning-fg)]'
  return 'text-text-muted'
}
