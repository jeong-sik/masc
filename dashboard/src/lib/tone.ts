// Unified tone classification utilities.
// Consolidates toneClass, chainStatusTone, sessionStatusTone, expiryTone
// from helpers.ts, mission-utils.ts, agents.ts, room-truth-strip.ts, etc.

/** General tone classification — maps status/health values to 'ok' | 'warn' | 'bad'. */
export function toneClass(tone?: string | null): string {
  if (
    tone === 'bad'
    || tone === 'offline'
    || tone === 'critical'
    || tone === 'risk'
  ) {
    return 'bad'
  }
  if (
    tone === 'warn'
    || tone === 'pending'
    || tone === 'degraded'
    || tone === 'interrupted'
    || tone === 'watch'
    || tone === 'paused'
    || tone === 'blocked'
  ) {
    return 'warn'
  }
  return 'ok'
}

/** Chain status tone — classifies chain runtime status strings via substring matching. */
export function chainStatusTone(status?: string | null): string {
  if (!status) return 'warn'
  const lowered = status.toLowerCase()
  if (
    lowered.includes('failed')
    || lowered.includes('error')
    || lowered.includes('disconnected')
    || lowered.includes('stopped')
  ) {
    return 'bad'
  }
  if (
    lowered.includes('running')
    || lowered.includes('active')
    || lowered.includes('degraded')
    || lowered.includes('pending')
  ) {
    return 'warn'
  }
  return 'ok'
}

/** Session status tone — classifies session status with normalized matching. */
export function sessionStatusTone(status?: string | null): string {
  const normalized = (status ?? '').trim().toLowerCase()
  if (
    normalized.includes('failed')
    || normalized.includes('error')
    || normalized.includes('stopped')
    || normalized === 'paused'
  ) {
    return 'bad'
  }
  if (
    normalized.includes('active')
    || normalized.includes('running')
    || normalized.includes('healthy')
    || normalized.includes('ok')
  ) {
    return 'ok'
  }
  return 'warn'
}

/** Expiry tone — 'bad' if expired, 'ok' if still valid, 'warn' if unknown. */
export function expiryTone(iso?: string | null): string {
  if (!iso) return 'warn'
  const ts = Date.parse(iso)
  if (Number.isNaN(ts)) return 'warn'
  return ts <= Date.now() ? 'bad' : 'ok'
}

/** Governance tone — maps governance decision values to 'positive' | 'negative' | 'neutral'. */
export function governanceToneClass(raw: string | null | undefined): string {
  const value = (raw || '').toLowerCase()
  if (value.includes('block') || value.includes('deny') || value.includes('closed')) return 'negative'
  if (
    value.includes('support')
    || value.includes('approve')
    || value.includes('ready')
    || value.includes('executed')
    || value.includes('done')
  ) {
    return 'positive'
  }
  return 'neutral'
}
