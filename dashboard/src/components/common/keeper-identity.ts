const adjectives = new Set([
  'swift', 'brave', 'calm', 'eager', 'fierce',
  'gentle', 'happy', 'jolly', 'keen', 'lucky',
  'merry', 'noble', 'proud', 'quick', 'witty',
  'bold', 'cool', 'deft', 'fair', 'grand',
  'hale', 'jade', 'kind', 'lean', 'neat',
  'pale', 'rare', 'sage', 'tame', 'warm',
])

const animals = new Set([
  'fox', 'bear', 'wolf', 'hawk', 'lion',
  'tiger', 'eagle', 'otter', 'panda', 'koala',
  'raven', 'falcon', 'badger', 'beaver', 'whale',
  'shark', 'crane', 'heron', 'moose', 'viper',
  'cobra', 'gecko', 'lemur', 'llama', 'manta',
  'orca', 'rhino', 'sloth', 'tapir', 'zebra',
])

function trimmedOrNull(value: string | null | undefined): string | null {
  const trimmed = value?.trim()
  return trimmed ? trimmed : null
}

function isValidKeeperName(value: string): boolean {
  return /^[A-Za-z0-9._-]+$/.test(value)
}

function isHex4(value: string): boolean {
  return /^[0-9a-f]{4}$/.test(value)
}

function extractGeneratedNicknamePrefix(name: string): string | null {
  const parts = name.split('-')
  if (parts.length === 0) return null

  const directPrefix = parts.slice(0, -2).join('-')
  const adjective = parts.length >= 2 ? parts[parts.length - 2] : undefined
  const animal = parts.length >= 1 ? parts[parts.length - 1] : undefined
  if (adjective && animal && adjectives.has(adjective) && animals.has(animal)) {
    return directPrefix || null
  }

  const uniquePrefix = parts.slice(0, -3).join('-')
  const uniqueAdjective = parts.length >= 3 ? parts[parts.length - 3] : undefined
  const uniqueAnimal = parts.length >= 2 ? parts[parts.length - 2] : undefined
  const suffix = parts.length >= 1 ? parts[parts.length - 1] : undefined
  if (
    suffix
    && uniqueAdjective
    && uniqueAnimal
    && isHex4(suffix)
    && adjectives.has(uniqueAdjective)
    && animals.has(uniqueAnimal)
  ) {
    return uniquePrefix || null
  }

  return null
}

function keeperNameFromAgentName(agentName: string | null | undefined): string | null {
  const trimmed = trimmedOrNull(agentName)
  if (!trimmed) return null

  if (trimmed.startsWith('keeper-') && trimmed.endsWith('-agent') && trimmed.length > 13) {
    const candidate = trimmed.slice(7, -6)
    return isValidKeeperName(candidate) ? candidate : null
  }

  return null
}

export function canonicalKeeperNameFromAgentName(agentName: string | null | undefined): string | null {
  const trimmed = trimmedOrNull(agentName)
  if (!trimmed) return null

  const aliasName = keeperNameFromAgentName(trimmed)
  if (aliasName) return aliasName

  const generatedPrefix = extractGeneratedNicknamePrefix(trimmed)
  return generatedPrefix && isValidKeeperName(generatedPrefix) ? generatedPrefix : null
}

export function canonicalKeeperName(rawName: string | null | undefined): string | null {
  const trimmed = trimmedOrNull(rawName)
  if (!trimmed) return null

  const aliasName = canonicalKeeperNameFromAgentName(trimmed)
  if (aliasName) return aliasName

  if (trimmed.startsWith('keeper-') && !trimmed.endsWith('-agent') && trimmed.length > 7) {
    const candidate = trimmed.slice(7)
    return isValidKeeperName(candidate) ? candidate : null
  }

  if (isValidKeeperName(trimmed)) return trimmed
  return null
}

export function runtimeAgentName(
  keeperName: string | null | undefined,
  agentName: string | null | undefined,
): string | null {
  const keeper = keeperPrimaryName(keeperName, agentName)
  const agent = trimmedOrNull(agentName)
  if (!agent) return null
  if (!keeper) return agent
  return agent === keeper ? null : agent
}

export function keeperPrimaryName(
  keeperName: string | null | undefined,
  agentName: string | null | undefined,
): string | null {
  const explicitKeeper = canonicalKeeperName(keeperName)
  if (explicitKeeper) return explicitKeeper
  return canonicalKeeperNameFromAgentName(agentName) ?? trimmedOrNull(agentName)
}

export function keeperPrincipalKey(
  keeperId: string | null | undefined,
  keeperName: string | null | undefined,
  agentName: string | null | undefined,
): string | null {
  const trimmedKeeperId = trimmedOrNull(keeperId)
  if (trimmedKeeperId) return `keeper_id:${trimmedKeeperId}`

  const canonicalName = keeperPrimaryName(keeperName, agentName)
  if (canonicalName) return `keeper:${canonicalName.toLowerCase()}`

  const runtime = trimmedOrNull(agentName)
  return runtime ? `agent:${runtime.toLowerCase()}` : null
}

export function keeperIdentityKeys(
  keeperId: string | null | undefined,
  keeperName: string | null | undefined,
  agentName: string | null | undefined,
): string[] {
  const values = [
    keeperPrincipalKey(keeperId, keeperName, agentName),
    trimmedOrNull(keeperId) ? `keeper_id:${trimmedOrNull(keeperId)}` : null,
    keeperPrimaryName(keeperName, agentName)?.toLowerCase() ?? null,
    canonicalKeeperName(keeperName)?.toLowerCase() ?? null,
    trimmedOrNull(keeperName)?.toLowerCase() ?? null,
    trimmedOrNull(agentName)?.toLowerCase() ?? null,
  ]

  return Array.from(new Set(values.filter((value): value is string => Boolean(value))))
}

export function keeperIdentitySearchTerms(
  keeperName: string | null | undefined,
  agentName: string | null | undefined,
): string[] {
  const primary = keeperPrimaryName(keeperName, agentName)
  const runtime = runtimeAgentName(keeperName, agentName)
  return [primary, runtime].filter((value): value is string => Boolean(value))
}

export function keeperIdentityHint(
  keeperName: string | null | undefined,
  agentName: string | null | undefined,
): string | null {
  const keeper = keeperPrimaryName(keeperName, agentName)
  const runtime = runtimeAgentName(keeper, agentName)
  if (!keeper) return null
  if (!runtime) return `키퍼 · ${keeper}`
  return `키퍼 · ${keeper} · 런타임 · ${runtime}`
}
