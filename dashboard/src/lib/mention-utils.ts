// Shared mention utilities — SSOT for keeper mention UI logic.
// Used by composer-v2.ts and quick-intervene.ts.

export interface OnlineKeeper {
  name: string
  status?: string
}

export interface MentionCandidate {
  name: string
  status?: string
  selected: boolean
}

export function keeperNameFromTarget(value: string): string | null {
  if (!value.startsWith('keeper:')) return null
  const name = value.slice('keeper:'.length).trim()
  return name || null
}

export function mentionQueryFromMessage(message: string): string | null {
  const match = message.match(/(?:^|\s)@([A-Za-z0-9_.-]*)$/)
  return match?.[1] ?? null
}

export function trailingMentionNameFromMessage(message: string): string | null {
  const match = message.match(/(?:^|\s)@([A-Za-z0-9_.-]+)\s*$/)
  return match?.[1] ?? null
}

export function onlineKeeperNameForMention(onlineKeepers: OnlineKeeper[], mentionName: string | null): string | null {
  if (!mentionName) return null
  const normalized = mentionName.toLowerCase()
  return onlineKeepers.find(keeper => keeper.name.toLowerCase() === normalized)?.name ?? null
}

export function mentionCandidates(onlineKeepers: OnlineKeeper[], query: string | null, selectedKeeper: string | null): MentionCandidate[] {
  const normalizedQuery = query?.toLowerCase() ?? ''
  return onlineKeepers
    .filter(keeper => normalizedQuery === '' || keeper.name.toLowerCase().includes(normalizedQuery))
    .map(keeper => ({
      name: keeper.name,
      status: keeper.status,
      selected: keeper.name === selectedKeeper,
    }))
    .sort((a, b) => Number(b.selected) - Number(a.selected) || a.name.localeCompare(b.name))
    .slice(0, 5)
}

export function replaceTrailingMentionDraft(message: string, keeperName: string): string {
  if (/(?:^|\s)@[A-Za-z0-9_.-]*$/.test(message)) {
    return message.replace(/(^|\s)@[A-Za-z0-9_.-]*$/, `$1@${keeperName} `)
  }
  const spacer = message.trimEnd().length > 0 ? ' ' : ''
  return `${message.trimEnd()}${spacer}@${keeperName} `
}
