/** General tone classification — maps status/health values to 'ok' | 'warn' | 'bad'. */
export function toneClass(tone?: string | null): string {
  if (
    tone === 'bad'
    || tone === 'error'
    || tone === 'failed'
    || tone === 'fatal'
    || tone === 'offline'
    || tone === 'stopped'
    || tone === 'critical'
    || tone === 'risk'
  ) {
    return 'bad'
  }
  if (
    tone === 'warn'
    || tone === 'warning'
    || tone === 'pending'
    || tone === 'degraded'
    || tone === 'interrupted'
    || tone === 'watch'
    || tone === 'paused'
    || tone === 'blocked'
    || tone === 'unbooted'
  ) {
    return 'warn'
  }
  return 'ok'
}
