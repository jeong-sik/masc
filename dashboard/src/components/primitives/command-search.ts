/**
 * `@leeoniya/ufuzzy` command search helper for `⌘K` Command Palette.
 *
 * - Uses uFuzzy (`unicode: true`, `intraMode: 1`) for fast Latin/identifier fuzzy matching
 *   with highlight range extraction.
 * - Seamlessly falls back to token-aware case-insensitive substring matching for Hangul/CJK
 *   queries so Korean labels and Keeper names match accurately with highlight ranges.
 */

import uFuzzy from '@leeoniya/ufuzzy'

export interface CommandSearchItem {
  readonly id: string
  readonly label: string
  readonly keywords?: readonly string[]
  readonly category?: string
}

export interface CommandSearchMatch<T extends CommandSearchItem> {
  readonly item: T
  /** Inclusive-start, exclusive-end highlight ranges within `item.label` */
  readonly labelRanges: readonly [number, number][]
  readonly score: number
}

const HANGUL_RE = /[\u1100-\u11FF\u3130-\u318F\uAC00-\uD7AF]/

const DEFAULT_UFUZZY = new uFuzzy({
  unicode: true,
  intraMode: 0,
  intraIns: 6,
})

function findSubstringRanges(text: string, tokens: readonly string[]): [number, number][] {
  const lower = text.toLowerCase()
  const ranges: [number, number][] = []
  for (const tok of tokens) {
    if (!tok) continue
    const idx = lower.indexOf(tok)
    if (idx !== -1) {
      ranges.push([idx, idx + tok.length])
    }
  }
  ranges.sort((a, b) => a[0] - b[0])
  return ranges
}

function clampRangesToLabel(rawRanges: number[] | undefined, labelLen: number): [number, number][] {
  if (!rawRanges || rawRanges.length < 2) return []
  const out: [number, number][] = []
  for (let i = 0; i + 1 < rawRanges.length; i += 2) {
    const start = rawRanges[i]!
    const end = rawRanges[i + 1]!
    if (start < labelLen) {
      out.push([start, Math.min(end, labelLen)])
    }
  }
  return out
}

export interface CommandSearcher<T extends CommandSearchItem> {
  search(query: string, limit?: number): readonly CommandSearchMatch<T>[]
}

export function createCommandSearcher<T extends CommandSearchItem>(
  items: readonly T[],
): CommandSearcher<T> {
  const haystacks = items.map((item) => {
    const extra = item.keywords?.length ? ` ${item.keywords.join(' ')}` : ''
    const cat = item.category ? ` ${item.category}` : ''
    return `${item.label}${cat}${extra}`
  })

  return {
    search(query: string, limit = 25): readonly CommandSearchMatch<T>[] {
      const trimmed = query.trim()
      if (!trimmed) {
        return items.slice(0, limit).map((item, idx) => ({
          item,
          labelRanges: [],
          score: idx,
        }))
      }

      const tokens = trimmed.toLowerCase().split(/\s+/).filter(Boolean)
      const useFallbackFirst = HANGUL_RE.test(trimmed)

      if (!useFallbackFirst) {
        const [idxs, info, order] = DEFAULT_UFUZZY.search(haystacks, trimmed)
        if (idxs && idxs.length > 0) {
          const ordered = info && order
            ? order.map((infoIdx, rank) => {
                const itemIdx = info.idx[infoIdx]!
                const item = items[itemIdx]!
                const ranges = clampRangesToLabel(info.ranges[infoIdx], item.label.length)
                return { item, labelRanges: ranges, score: rank }
              })
            : idxs.map((itemIdx, rank) => {
                const item = items[itemIdx]!
                return {
                  item,
                  labelRanges: findSubstringRanges(item.label, tokens),
                  score: rank,
                }
              })
          return ordered.slice(0, limit)
        }
      }

      // Hangul / CJK or substring fallback: every whitespace-separated token must appear
      const matches: CommandSearchMatch<T>[] = []
      for (let i = 0; i < items.length; i++) {
        const hayLower = haystacks[i]!.toLowerCase()
        if (!tokens.every((tok) => hayLower.includes(tok))) continue
        const item = items[i]!
        const labelLower = item.label.toLowerCase()
        const startsWithFirst = labelLower.startsWith(tokens[0]!) ? 0 : 1
        const inLabel = labelLower.includes(tokens[0]!) ? 0 : 2
        matches.push({
          item,
          labelRanges: findSubstringRanges(item.label, tokens),
          score: startsWithFirst + inLabel,
        })
      }
      matches.sort((a, b) => a.score - b.score)
      return matches.slice(0, limit)
    },
  }
}

export function searchCommands<T extends CommandSearchItem>(
  items: readonly T[],
  query: string,
  limit = 25,
): readonly CommandSearchMatch<T>[] {
  return createCommandSearcher(items).search(query, limit)
}
