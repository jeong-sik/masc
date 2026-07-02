import { fetchKeeperCatchupDigest } from './api/keeper'
import {
  keeperCatchupDigests,
  keeperDigestError,
  keeperDigestLoading,
} from './keeper-digest-signals'

// Per-keeper inflight dedup: concurrent refreshes for the same keeper share a
// single fetch (mirrors the operator digest stack's *RefreshInflight guard in
// operator-actions.ts). Keyed by keeper name so different keepers still fetch
// in parallel.
const inflight = new Map<string, Promise<void>>()

function setRecord<T>(
  target: typeof keeperCatchupDigests | typeof keeperDigestLoading | typeof keeperDigestError,
  key: string,
  value: T,
): void {
  target.value = { ...target.value, [key]: value } as typeof target.value
}

// Fetch the since-last-seen digest for one keeper and publish it to the signal.
// `sinceUnix` is the operator's last-seen cursor captured at panel mount. Errors
// are surfaced on keeperDigestError (never thrown) so a digest failure cannot
// break panel mount; the transcript still renders.
export async function refreshKeeperCatchupDigest(
  keeperName: string,
  sinceUnix: number,
): Promise<void> {
  const name = keeperName.trim()
  if (!name || !Number.isFinite(sinceUnix)) return
  const existing = inflight.get(name)
  if (existing) return existing

  setRecord(keeperDigestLoading, name, true)
  setRecord(keeperDigestError, name, null)
  const run = (async () => {
    try {
      const digest = await fetchKeeperCatchupDigest(name, sinceUnix)
      setRecord(keeperCatchupDigests, name, digest)
    } catch (err) {
      const message = err instanceof Error ? err.message : `${name} digest 로드 실패`
      setRecord(keeperDigestError, name, message)
    } finally {
      setRecord(keeperDigestLoading, name, false)
      inflight.delete(name)
    }
  })()
  inflight.set(name, run)
  return run
}

export function _resetKeeperDigestForTests(): void {
  inflight.clear()
  keeperCatchupDigests.value = {}
  keeperDigestLoading.value = {}
  keeperDigestError.value = {}
}
