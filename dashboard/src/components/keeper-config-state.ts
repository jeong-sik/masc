import { signal } from '@preact/signals'
import { fetchKeeperConfig } from '../api/dashboard'
import type { KeeperConfig } from '../types'
import { createAsyncResource, loaded } from '../lib/async-state'

export type KeeperConfigLoadStatus = 'idle' | 'loading' | 'loaded' | 'error' | 'other'

const configResource = createAsyncResource<KeeperConfig>()
export const configState = configResource.state
export const configKeeperName = signal<string>('')

type ResetHandler = () => void
type UpdateHandler = (name: string, updated: KeeperConfig) => void

const resetHandlers = new Set<ResetHandler>()
const updateHandlers = new Set<UpdateHandler>()

export function registerKeeperConfigResetHandler(handler: ResetHandler): () => void {
  resetHandlers.add(handler)
  return () => {
    resetHandlers.delete(handler)
  }
}

export function registerKeeperConfigUpdateHandler(handler: UpdateHandler): () => void {
  updateHandlers.add(handler)
  return () => {
    updateHandlers.delete(handler)
  }
}

export function keeperConfigSubscriptionCountsForTests(): { reset: number; update: number } {
  return {
    reset: resetHandlers.size,
    update: updateHandlers.size,
  }
}

export async function loadKeeperConfig(
  name: string,
  options?: { force?: boolean },
): Promise<void> {
  const force = options?.force === true
  if (!force && configKeeperName.value === name && configState.value.status === 'loaded') return
  if (configKeeperName.value !== name) {
    configResource.reset()
    for (const handler of resetHandlers) {
      handler()
    }
  } else if (force) {
    configResource.reset()
  }
  configKeeperName.value = name
  await configResource.load(() => fetchKeeperConfig(name))
}

export function resetKeeperConfig(): void {
  configResource.reset()
  configKeeperName.value = ''
  for (const handler of resetHandlers) {
    handler()
  }
}

export function applyKeeperConfigUpdate(name: string, updated: KeeperConfig): void {
  configKeeperName.value = name
  configState.value = loaded(updated)
  for (const handler of updateHandlers) {
    handler(name, updated)
  }
}

export function peekLoadedKeeperConfig(name: string): KeeperConfig | null {
  const state = configState.value
  if (configKeeperName.value !== name || state.status !== 'loaded') return null
  return state.data
}

export function peekKeeperConfigLoadStatus(
  name: string,
): KeeperConfigLoadStatus {
  const state = configState.value
  if (configKeeperName.value !== name) return 'other'
  return state.status
}
