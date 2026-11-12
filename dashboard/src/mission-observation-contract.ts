import { isRecord } from './lib/type-guards'
import { isObserverInstance } from './lib/observer-protocol'

export interface MissionPublication {
  readonly observer_instance_id: string
  readonly mission_publication_generation: number
  readonly mission_publication_sequence: number
  readonly mission_observation_state: 'initializing' | 'ready' | 'error'
}

/** Metadata belongs to the captured server owner, never the client clock. */
export function missionPublication(value: unknown): MissionPublication | null {
  if (!isRecord(value) || typeof value.observer_instance_id !== 'string'
    || !isObserverInstance(value.observer_instance_id)) return null
  const generation = value.mission_publication_generation
  const sequence = value.mission_publication_sequence
  const state = value.mission_observation_state
  if (typeof generation !== 'number' || !Number.isSafeInteger(generation) || generation < 0
    || typeof sequence !== 'number' || !Number.isSafeInteger(sequence) || sequence < 0
    || (state !== 'initializing' && state !== 'ready' && state !== 'error')) return null
  return { observer_instance_id: value.observer_instance_id,
    mission_publication_generation: generation, mission_publication_sequence: sequence,
    mission_observation_state: state }
}
