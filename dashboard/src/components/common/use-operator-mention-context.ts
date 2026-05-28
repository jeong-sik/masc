// Shared @mention + target-selector computation for operator messaging surfaces.
//
// Both ComposerV2 (board) and QuickIntervene (ops) consume operatorSnapshot,
// filter via isKeeperOperatorTargetable, and derive the same mention state
// (active candidate, listbox open/dismissed, effective target). The 15-line
// derived block plus two useState hooks plus the reset effect were duplicated
// between the two surfaces; this hook collapses them into one SSOT.

import { useEffect, useState, type Dispatch, type StateUpdater } from 'preact/hooks'
import { operatorSnapshot } from '../../operator-store'
import { isKeeperOperatorTargetable } from '../../lib/keeper-predicates'
import {
  keeperNameFromTarget,
  mentionCandidates,
  mentionQueryFromMessage,
  onlineKeeperNameForMention,
  trailingMentionNameFromMessage,
  type MentionCandidate,
  type OnlineKeeper,
} from '../../lib/mention-utils'

export interface OperatorMentionContext {
  onlineKeepers: OnlineKeeper[]
  /** Stable join used as a useEffect dependency to detect roster diffs. */
  onlineKeeperNames: string
  selectedKeeper: string | null
  selectedKeeperOnline: boolean
  mentionQuery: string | null
  trailingMention: string | null
  trailingMentionTarget: string | null
  unresolvedTrailingMention: boolean
  effectiveKeeper: string | null
  effectiveKeeperOnline: boolean
  mentionMatches: MentionCandidate[]
  mentionListOpen: boolean
  activeMention: MentionCandidate | null
  activeMentionOptionId: string | undefined
  activeMentionIndex: number
  setActiveMentionIndex: Dispatch<StateUpdater<number>>
  dismissedMentionQuery: string | null
  setDismissedMentionQuery: Dispatch<StateUpdater<string | null>>
}

export interface UseOperatorMentionContextOptions {
  message: string
  target: string
  /** True when the composer mode treats `@name` as a mention. */
  dmActive: boolean
  /** ARIA listbox id used to build per-option ids. Surfaces use different ids. */
  listboxId: string
}

export function useOperatorMentionContext(
  opts: UseOperatorMentionContextOptions,
): OperatorMentionContext {
  const { message, target, dmActive, listboxId } = opts

  const [activeMentionIndex, setActiveMentionIndex] = useState(0)
  const [dismissedMentionQuery, setDismissedMentionQuery] = useState<string | null>(null)

  const snapshot = operatorSnapshot.value
  // Paused keepers stay targetable so operators can DM/probe/resume them,
  // even when another lifecycle axis still carries an offline-ish token.
  const onlineKeepers: OnlineKeeper[] = (snapshot?.keepers ?? [])
    .filter(isKeeperOperatorTargetable)
    .map(keeper => ({ name: keeper.name, status: keeper.status }))
  const onlineKeeperNames = onlineKeepers.map(keeper => keeper.name).join('\0')

  const selectedKeeper = keeperNameFromTarget(target)
  const selectedKeeperOnline =
    !!selectedKeeper && onlineKeepers.some(keeper => keeper.name === selectedKeeper)

  const mentionQuery = dmActive ? mentionQueryFromMessage(message) : null
  const trailingMention = dmActive ? trailingMentionNameFromMessage(message) : null
  const trailingMentionTarget = dmActive
    ? onlineKeeperNameForMention(onlineKeepers, trailingMention)
    : null
  const unresolvedTrailingMention = dmActive && !!trailingMention && !trailingMentionTarget

  const effectiveKeeper = trailingMentionTarget ?? selectedKeeper
  const effectiveKeeperOnline = !!trailingMentionTarget || selectedKeeperOnline

  const mentionMatches = dmActive
    ? mentionCandidates(onlineKeepers, mentionQuery, effectiveKeeper)
    : []
  const mentionListOpen = mentionQuery !== null && dismissedMentionQuery !== mentionQuery
  const activeMention: MentionCandidate | null = mentionListOpen
    ? mentionMatches[activeMentionIndex] ?? mentionMatches[0] ?? null
    : null
  const activeMentionOptionId = activeMention
    ? `${listboxId}-option-${Math.max(mentionMatches.indexOf(activeMention), 0)}`
    : undefined

  useEffect(() => {
    setActiveMentionIndex(0)
    setDismissedMentionQuery(null)
  }, [mentionQuery, onlineKeeperNames])

  return {
    onlineKeepers,
    onlineKeeperNames,
    selectedKeeper,
    selectedKeeperOnline,
    mentionQuery,
    trailingMention,
    trailingMentionTarget,
    unresolvedTrailingMention,
    effectiveKeeper,
    effectiveKeeperOnline,
    mentionMatches,
    mentionListOpen,
    activeMention,
    activeMentionOptionId,
    activeMentionIndex,
    setActiveMentionIndex,
    dismissedMentionQuery,
    setDismissedMentionQuery,
  }
}
