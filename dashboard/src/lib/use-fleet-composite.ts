import { useCallback, useEffect, useRef } from 'preact/hooks'
import {
  acquireFleetComposite,
  fleetCompositeData,
  fleetCompositeError,
  fleetCompositeLoading,
  fleetCompositeObservation,
  type FleetCompositeLease,
} from '../fleet-composite-resource'

export function useFleetComposite(enabled = true) {
  const lease = useRef<FleetCompositeLease | null>(null)
  useEffect(() => {
    if (!enabled) return
    const held = acquireFleetComposite()
    lease.current = held
    return () => {
      if (lease.current === held) lease.current = null
      held.release()
    }
  }, [enabled])
  const refresh = useCallback((keeperName?: string) => lease.current
    ? lease.current.refresh(keeperName)
    : Promise.reject(new DOMException('Fleet composite consumer retired', 'AbortError')), [])
  return {
    observation: enabled ? fleetCompositeObservation.value : null,
    data: enabled ? fleetCompositeData.value : null,
    loading: enabled && fleetCompositeLoading.value,
    error: enabled ? fleetCompositeError.value : null,
    refresh,
  }
}
