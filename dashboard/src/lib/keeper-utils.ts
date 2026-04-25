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

/**
 * Client-side mirror of Keeper_unified_turn.is_verifier_role_keeper (OCaml).
 * Returns true when mention_targets include one of the verifier role tokens
 * ("verifier" / "검증자"). Used by dashboard surfaces that need to distinguish
 * verification-authority keepers without reloading the persona profile.
 */
const VERIFIER_ROLE_MENTION_TOKENS: readonly string[] = ['verifier', '검증자']

export function isVerifierRoleKeeper(
  mentionTargets: readonly string[] | null | undefined,
): boolean {
  if (!mentionTargets || mentionTargets.length === 0) return false
  return VERIFIER_ROLE_MENTION_TOKENS.some(token => mentionTargets.includes(token))
}
