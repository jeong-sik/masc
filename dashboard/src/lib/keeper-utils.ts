// Keeper lookup utilities — canonical keeper resolution by name or agent_name.

import { keepers } from '../store'
import type { Keeper } from '../types'
import {
  canonicalKeeperNameFromAgentName,
  keeperIdentityKeys,
} from '../components/common/keeper-identity'

/** Find a keeper by name or agent_name. Returns null when not found or name is empty. */
export function findKeeper(name?: string | null): Keeper | null {
  if (!name) return null
  const needle = name.trim().toLowerCase()
  if (!needle) return null
  const alias = canonicalKeeperNameFromAgentName(name)?.toLowerCase() ?? null
  return keepers.value.find(k => {
    const keys = keeperIdentityKeys(k.keeper_id, k.name, k.agent_name)
    return keys.includes(needle) || (alias !== null && keys.includes(alias))
  }) ?? null
}
