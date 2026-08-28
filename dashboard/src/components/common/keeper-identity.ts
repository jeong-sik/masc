// RFC-0393: a keeper has exactly one name. Nothing is encoded inside the
// string and nothing is recovered from other spellings by parsing — the
// wrapper/prefix strips and the generated-nickname dictionary that used to
// live here mirrored the OCaml parsers deleted by the same RFC.

function trimmedOrNull(value: string | null | undefined): string | null {
  const trimmed = value?.trim()
  return trimmed ? trimmed : null
}

function isValidKeeperName(value: string): boolean {
  return /^[A-Za-z0-9._-]+$/.test(value)
}

export function canonicalKeeperName(rawName: string | null | undefined): string | null {
  const trimmed = trimmedOrNull(rawName)
  if (!trimmed) return null
  return isValidKeeperName(trimmed) ? trimmed : null
}

export function keeperPrimaryName(keeperName: string | null | undefined): string | null {
  return canonicalKeeperName(keeperName)
}

export function keeperPrincipalKey(
  keeperId: string | null | undefined,
  keeperName: string | null | undefined,
): string | null {
  const trimmedKeeperId = trimmedOrNull(keeperId)
  if (trimmedKeeperId) return `keeper_id:${trimmedKeeperId}`

  const canonicalName = keeperPrimaryName(keeperName)
  return canonicalName ? `keeper:${canonicalName.toLowerCase()}` : null
}

export function keeperIdentityKeys(
  keeperId: string | null | undefined,
  keeperName: string | null | undefined,
): string[] {
  const values = [
    keeperPrincipalKey(keeperId, keeperName),
    trimmedOrNull(keeperId) ? `keeper_id:${trimmedOrNull(keeperId)}` : null,
    keeperPrimaryName(keeperName)?.toLowerCase() ?? null,
    trimmedOrNull(keeperName)?.toLowerCase() ?? null,
  ]

  return Array.from(new Set(values.filter((value): value is string => Boolean(value))))
}

export function keeperIdentityHint(keeperName: string | null | undefined): string | null {
  const keeper = keeperPrimaryName(keeperName)
  return keeper ? `키퍼 · ${keeper}` : null
}
