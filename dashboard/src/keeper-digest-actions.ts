import { fetchKeeperCatchupDigest } from './api/keeper'
import {
  keeperCatchupDigests,
  keeperDigestError,
  keeperDigestLoading,
} from './keeper-digest-signals'

interface InflightDigestRefresh {
  requestId: number
  sinceUnix: number
  promise: Promise<void>
}

// Per-keeper+baseline inflight dedup. The digest is anchored to the captured
// sinceUnix cursor, so a later refresh for the same keeper with a newer cursor
// must not reuse or be overwritten by an older in-flight response.
const inflight = new Map<string, InflightDigestRefresh>()
let nextRequestId = 0

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
  if (existing && existing.sinceUnix === sinceUnix) return existing.promise

  const requestId = ++nextRequestId
  setRecord(keeperDigestLoading, name, true)
  setRecord(keeperDigestError, name, null)
  const run = (async () => {
    try {
      const digest = await fetchKeeperCatchupDigest(name, sinceUnix)
      if (inflight.get(name)?.requestId === requestId) {
        setRecord(keeperCatchupDigests, name, digest)
      }
    } catch (err) {
      const message = err instanceof Error ? err.message : `${name} digest 로드 실패`
      if (inflight.get(name)?.requestId === requestId) {
        setRecord(keeperDigestError, name, message)
      }
    } finally {
      if (inflight.get(name)?.requestId === requestId) {
        setRecord(keeperDigestLoading, name, false)
        inflight.delete(name)
      }
    }
  })()
  inflight.set(name, { requestId, sinceUnix, promise: run })
  return run
}

export function _resetKeeperDigestForTests(): void {
  inflight.clear()
  nextRequestId = 0
  keeperCatchupDigests.value = {}
  keeperDigestLoading.value = {}
  keeperDigestError.value = {}
}
