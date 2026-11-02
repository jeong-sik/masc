// Goal_store uses OCaml String.trim, whose boundary whitespace is limited to
// these five ASCII characters. JavaScript's trim() also removes other Unicode
// characters that the Goal store treats as part of the ID.
function isGoalBoundarySpace(char: string): boolean {
  return char === ' ' || char === '\t' || char === '\n' || char === '\r' || char === '\f'
}

/** Preserve the wire ID exactly; validity is checked at the action boundary. */
export function exactGoalId(value: unknown): string | undefined {
  return typeof value === 'string' && value.length > 0 ? value : undefined
}

export function exactGoalIds(value: unknown): string[] {
  return Array.isArray(value)
    ? value.filter((item): item is string => exactGoalId(item) !== undefined)
    : []
}

export function goalIdComparisonKey(id: string): string {
  let start = 0
  let end = id.length
  while (start < end && isGoalBoundarySpace(id[start]!)) start += 1
  while (end > start && isGoalBoundarySpace(id[end - 1]!)) end -= 1
  return id.slice(start, end)
}

/** Preserve a nonblank observed ID without changing its boundary characters. */
export function nonblankGoalId(value: unknown): string | undefined {
  const id = exactGoalId(value)
  return id !== undefined && goalIdComparisonKey(id) !== '' ? id : undefined
}

export function isCanonicalGoalId(id: string): boolean {
  const key = goalIdComparisonKey(id)
  return key.length > 0 && key === id
}

/** The observed list cannot establish uniqueness outside that observation. */
export function isUnambiguousGoalId(id: string, observedIds: readonly string[]): boolean {
  if (!isCanonicalGoalId(id)) return false
  let matches = 0
  for (const observed of observedIds) {
    if (goalIdComparisonKey(observed) === id && ++matches > 1) return false
  }
  return matches === 1
}

export type GoalIdentityObservation = { readonly ids: readonly string[]; readonly complete: boolean }

/** Collect IDs before display decoding can discard an otherwise identifiable row. */
export function observeGoalIds(rows: unknown, nested = false): GoalIdentityObservation {
  const ids: string[] = []
  let complete = true
  function collect(value: unknown): void {
    if (!Array.isArray(value)) { complete = false; return }
    for (const item of value) {
      if (typeof item !== 'object' || item === null || Array.isArray(item)) { complete = false; continue }
      const row = item as Record<string, unknown>
      if (typeof row.id === 'string') ids.push(row.id)
      else complete = false
      if (nested && row.children !== undefined) collect(row.children)
    }
  }
  collect(rows)
  return { ids, complete }
}
