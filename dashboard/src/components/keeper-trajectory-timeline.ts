// Keeper trajectory state — SSE-driven fetch of /api/v1/keepers/:name/trajectory.
// UI was retired; only loadTrajectory is still called from sse-store.ts.

import { signal } from '@preact/signals'
import { fetchKeeperTrajectory } from '../api/dashboard'
import type { TrajectoryResponse } from '../api/dashboard'

const TRAJECTORY_DEFAULT_LIMIT = 50

type TrajectoryState = {
  data: TrajectoryResponse | null
  loading: boolean
  error: string | null
}

const trajectoryStates = signal<Record<string, TrajectoryState>>({})

function getState(name: string): TrajectoryState {
  return trajectoryStates.value[name] ?? { data: null, loading: false, error: null }
}

function setState(name: string, patch: Partial<TrajectoryState>): void {
  const prev = getState(name)
  trajectoryStates.value = { ...trajectoryStates.value, [name]: { ...prev, ...patch } }
}

export async function loadTrajectory(keeperName: string): Promise<void> {
  setState(keeperName, { loading: true, error: null })
  try {
    const data = await fetchKeeperTrajectory(keeperName, TRAJECTORY_DEFAULT_LIMIT)
    setState(keeperName, { data, loading: false })
  } catch (err) {
    setState(keeperName, {
      data: null,
      loading: false,
      error: err instanceof Error ? err.message : 'fetch failed',
    })
  }
}
