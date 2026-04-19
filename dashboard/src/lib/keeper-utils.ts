// Keeper lookup utilities — canonical keeper resolution by name or agent_name.

import { keepers } from '../store'
import type { Keeper } from '../types'

/** Find a keeper by name or agent_name. Returns null when not found or name is empty. */
export function findKeeper(name?: string | null): Keeper | null {
  if (!name) return null
  return keepers.value.find(k => k.name === name || k.agent_name === name) ?? null
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
