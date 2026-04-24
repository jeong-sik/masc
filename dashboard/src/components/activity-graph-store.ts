import { createManagedAsyncResource } from '../lib/async-state'
import { fetchActivityGraph } from '../api'
import {
  currentTimeRangeFilter,
  type TimeRangePreset,
} from '../observatory-filter-store'
import type { ActivityGraphResponse } from '../types'

export const DEFAULT_ACTIVITY_RANGE: TimeRangePreset = '1h'
export const graphResource = createManagedAsyncResource<ActivityGraphResponse | null>(null)

export function activityRange(): TimeRangePreset {
  return currentTimeRangeFilter() ?? DEFAULT_ACTIVITY_RANGE
}

export function loadGraphForRange(since: TimeRangePreset) {
  return graphResource.load((signal) => {
    return fetchActivityGraph(since, { signal })
  })
}

export function loadGraph() {
  return loadGraphForRange(activityRange())
}

export { loadGraph as refreshActivityGraph }
