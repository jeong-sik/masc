/** masc:// references, as the TUI writes them.
 *
 * The TUI prints a reference beside the thing it names — a verdict says which
 * task it judged, a board row says its own id — and follows them with Ctrl-].
 * The dashboard reads the same posts and could not read the same references,
 * so a post that named a task said it only to whoever was in the terminal.
 *
 * Only what the writer could have produced is read back. A post that spells an
 * id in prose is not linked to it: a connection the writer did not make is one
 * nobody checked, and following it would go somewhere they never meant.
 */

export type MascReferenceKind = 'post' | 'goal' | 'schedule' | 'task' | 'run' | 'keeper'

export interface MascReference {
  kind: MascReferenceKind
  id: string
}

const SCHEME = 'masc://'

/** Wire paths, matching bin/masc_tui_link.ml. Two segments for tasks, which
 *  live inside the overview namespace rather than on a surface of their own. */
const PATH_TO_KIND: ReadonlyMap<string, MascReferenceKind> = new Map([
  ['board', 'post'],
  ['planning', 'goal'],
  ['schedules', 'schedule'],
  ['overview/tasks', 'task'],
  ['fusion', 'run'],
  ['keepers', 'keeper'],
])

/** The unreserved set the writer leaves alone; everything else is escaped. */
function isUnreserved(char: string): boolean {
  return /[A-Za-z0-9\-._~]/.test(char)
}

/** A reference runs until a byte the writer would never have emitted. */
function isReferenceChar(char: string): boolean {
  return isUnreserved(char) || char === '%' || char === '/'
}

function decodeSegment(segment: string): string | null {
  try {
    // decodeURIComponent rejects a stray or truncated escape, which is exactly
    // the answer wanted: that text is not a reference this program wrote.
    return decodeURIComponent(segment)
  } catch {
    return null
  }
}

/** Read one reference, or null when the text is not one this program wrote. */
export function parseMascReference(text: string): MascReference | null {
  if (!text.startsWith(SCHEME) || text.length <= SCHEME.length) return null
  const rest = text.slice(SCHEME.length)
  const cut = rest.lastIndexOf('/')
  if (cut <= 0) return null
  const kind = PATH_TO_KIND.get(rest.slice(0, cut))
  if (!kind) return null
  const rawId = rest.slice(cut + 1)
  if (rawId === '') return null
  const id = decodeSegment(rawId)
  if (id === null || id === '') return null
  return { kind, id }
}

/** Every reference in a body, in the order it appears, without repeats. */
export function scanMascReferences(body: string | null | undefined): MascReference[] {
  if (!body) return []
  const found: MascReference[] = []
  const seen = new Set<string>()
  let index = 0
  while (index < body.length) {
    if (!body.startsWith(SCHEME, index)) {
      index += 1
      continue
    }
    let stop = index + SCHEME.length
    while (stop < body.length && isReferenceChar(body[stop]!)) stop += 1
    const hit = parseMascReference(body.slice(index, stop))
    if (hit) {
      const key = `${hit.kind}:${hit.id}`
      if (!seen.has(key)) {
        seen.add(key)
        found.push(hit)
      }
    }
    index = stop
  }
  return found
}

/** Posts that point at something this post also points at.
 *
 * Ordered as the caller supplied them, so a list sorted by recency stays that
 * way. The post itself is never its own relation. */
export function postsSharingReferences<T extends { id: string; body?: string | null }>(
  post: T,
  candidates: readonly T[],
): T[] {
  const mine = scanMascReferences(post.body)
  if (mine.length === 0) return []
  const keys = new Set(mine.map(hit => `${hit.kind}:${hit.id}`))
  return candidates.filter(
    other =>
      other.id !== post.id &&
      scanMascReferences(other.body).some(hit => keys.has(`${hit.kind}:${hit.id}`)),
  )
}
