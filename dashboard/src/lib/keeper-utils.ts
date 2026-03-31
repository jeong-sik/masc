// Keeper lookup utilities — canonical keeper resolution by name or agent_name.

import { keepers } from '../store'
import type { Keeper } from '../types'

/** Find a keeper by name or agent_name. Returns null when not found or name is empty. */
export function findKeeper(name?: string | null): Keeper | null {
  if (!name) return null
  return keepers.value.find(k => k.name === name || k.agent_name === name) ?? null
}
