import type { DashboardRuntimeModelMetricsResponse } from '../api/dashboard-runtime'
import type { ModelMetricsQuery, ModelMetricsReadError } from '../api/model-metrics-stream'
import type { QueryStreamReader, QueryStreamSubscription } from './query-observation-stream'

/** Existing rendering fixtures supply a controlled reading instead of a socket.
 * Late replies deliberately reach the hook after cancellation, exercising its
 * own authority/query fence. Native stream ownership is tested separately. */
export function modelMetricsSubscriptionFixture(
  read: (window: number, bucket: number, options: { signal: AbortSignal }) => Promise<DashboardRuntimeModelMetricsResponse>,
) {
  return (query: ModelMetricsQuery, reader: QueryStreamReader<DashboardRuntimeModelMetricsResponse, ModelMetricsReadError>): QueryStreamSubscription => {
    let active = true
    let controller: AbortController | null = null
    const load = () => {
      if (!active) return
      controller?.abort()
      const owned = new AbortController()
      controller = owned
      reader.onReset('initial')
      void Promise.resolve().then(() => read(query.windowMinutes, query.bucketMinutes, { signal: owned.signal }))
        .then(reader.onFrame, cause => reader.onError(cause instanceof Error ? cause as ModelMetricsReadError : new Error(String(cause)) as ModelMetricsReadError))
    }
    queueMicrotask(load)
    return Object.assign(() => { active = false; controller?.abort() }, { refresh: load })
  }
}
