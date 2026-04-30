/**
 * InlineSuggestion — at-the-change-site agent proposal primitive (RFC 0011).
 *
 * Manager-plus-controller pair. Manager owns the suggestion roster across
 * the editor surface and routes accept/reject callbacks. Controller binds
 * to one suggestion and emits ARIA-correct prop bundles for the editor's
 * suggestion region. Tab → accept, Escape → reject (RFC §4 keyboard
 * contract; non-standard Tab override permitted by ARIA APG for
 * role-specific affordances).
 *
 * MVP scope (RFC 0011 §3, §4, §5, §6, §7):
 *   - propose / retract / accept / reject mutation surface
 *   - inFile / inRange / topAtLine queries
 *   - same-range mutual reject on accept (winner takes the slot,
 *     losers fire onReject)
 *   - TTL default 30s; ttlMs:0 disables auto-rejection
 *   - data-agent-color carries `--k-N` for stripe coloring
 *   - aria-label format: "Suggestion from <name>: replace lines N-M.
 *     Press Tab to accept or Escape to reject."
 *
 * Out of scope (deferred per RFC 0011 §11):
 *   - LLM streaming partial UI (consumer concern)
 *   - Suggestion application (consumer writes file in onAccept)
 *   - Diff rendering (consumer renders before/after lines)
 *   - Cross-file suggestion bundles
 */

import { createIdGenerator } from './id-generator'

export interface SuggestionRange {
  readonly file: string
  readonly fromLine: number
  readonly toLine: number
}

export interface InlineSuggestion {
  readonly id: string
  readonly agentId: string
  readonly agentName: string
  readonly agentColorSlot: number
  readonly range: SuggestionRange
  readonly before: ReadonlyArray<string>
  readonly after: ReadonlyArray<string>
  readonly rationale?: string
  readonly confidence: number
  readonly createdAt: string
}

export interface InlineSuggestionInput {
  readonly agentId: string
  readonly agentName: string
  readonly agentColorSlot: number
  readonly range: SuggestionRange
  readonly before: ReadonlyArray<string>
  readonly after: ReadonlyArray<string>
  readonly rationale?: string
  readonly confidence: number
}

export interface InlineSuggestionOptions {
  onAccept?: (suggestion: InlineSuggestion) => void
  onReject?: (suggestion: InlineSuggestion) => void
  /** Auto-reject after Nms with no interaction. 0 = persistent. Default 30000. */
  ttlMs?: number
  now?: () => string
}

export interface InlineSuggestionManager {
  propose(input: InlineSuggestionInput): string
  retract(id: string): void
  accept(id: string): void
  reject(id: string): void

  getAll(): ReadonlyArray<InlineSuggestion>
  inFile(file: string): ReadonlyArray<InlineSuggestion>
  inRange(file: string, fromLine: number, toLine: number): ReadonlyArray<InlineSuggestion>
  topAtLine(file: string, line: number): InlineSuggestion | undefined

  subscribeFile(
    file: string,
    listener: (suggestions: ReadonlyArray<InlineSuggestion>) => void,
  ): () => void
}

export interface SuggestionKeyEvent {
  readonly key: string
  readonly metaKey?: boolean
  readonly ctrlKey?: boolean
  readonly shiftKey?: boolean
  readonly altKey?: boolean
  preventDefault(): void
}

export interface SuggestionRootProps {
  readonly id: string
  readonly role: 'region'
  readonly 'aria-label': string
  readonly 'aria-keyshortcuts': 'Tab Escape'
  readonly 'data-state': 'suggested'
  readonly 'data-agent-color': string
  readonly tabIndex: 0
  readonly onKeyDown: (e: SuggestionKeyEvent) => void
}

export interface SuggestionButtonProps {
  readonly type: 'button'
  readonly 'aria-label': string
  readonly 'aria-keyshortcuts': string
  readonly onClick: () => void
}

export interface SuggestionController {
  readonly suggestion: InlineSuggestion
  getRootProps(): SuggestionRootProps
  getAcceptButtonProps(): SuggestionButtonProps
  getRejectButtonProps(): SuggestionButtonProps
}

const DEFAULT_TTL_MS = 30000

function rangesOverlap(a: SuggestionRange, b: SuggestionRange): boolean {
  if (a.file !== b.file) return false
  // Inclusive fromLine, exclusive toLine per RFC §3.1.
  return a.fromLine < b.toLine && b.fromLine < a.toLine
}

export function createInlineSuggestionManager(
  opts?: InlineSuggestionOptions,
): InlineSuggestionManager {
  const ttlMs = opts?.ttlMs ?? DEFAULT_TTL_MS
  const now = opts?.now ?? (() => new Date().toISOString())
  const idGen = createIdGenerator('inline-suggestion')

  const suggestions = new Map<string, InlineSuggestion>()
  const ttlTimers = new Map<string, ReturnType<typeof setTimeout>>()
  const fileListeners = new Map<
    string,
    Set<(s: ReadonlyArray<InlineSuggestion>) => void>
  >()

  function emitFile(file: string): void {
    const set = fileListeners.get(file)
    if (set === undefined || set.size === 0) return
    const listing = inFile(file)
    for (const l of set) l(listing)
  }

  function clearTimer(id: string): void {
    const t = ttlTimers.get(id)
    if (t !== undefined) {
      clearTimeout(t)
      ttlTimers.delete(id)
    }
  }

  function inFile(file: string): ReadonlyArray<InlineSuggestion> {
    const out: InlineSuggestion[] = []
    for (const s of suggestions.values()) {
      if (s.range.file === file) out.push(s)
    }
    return Object.freeze(out)
  }

  function propose(input: InlineSuggestionInput): string {
    const id = idGen.next()
    const full: InlineSuggestion = Object.freeze({
      ...input,
      id,
      createdAt: now(),
    })
    suggestions.set(id, full)
    if (ttlMs > 0) {
      const timer = setTimeout(() => {
        // Only auto-reject if still present.
        if (suggestions.has(id)) reject(id)
      }, ttlMs)
      ttlTimers.set(id, timer)
    }
    emitFile(full.range.file)
    return id
  }

  function retract(id: string): void {
    const s = suggestions.get(id)
    if (s === undefined) return
    suggestions.delete(id)
    clearTimer(id)
    emitFile(s.range.file)
  }

  function accept(id: string): void {
    const s = suggestions.get(id)
    if (s === undefined) return
    suggestions.delete(id)
    clearTimer(id)
    if (opts?.onAccept !== undefined) opts.onAccept(s)
    // Reject any other suggestion at an overlapping range in the same file.
    const losers: InlineSuggestion[] = []
    for (const other of Array.from(suggestions.values())) {
      if (rangesOverlap(other.range, s.range)) {
        losers.push(other)
      }
    }
    for (const other of losers) {
      suggestions.delete(other.id)
      clearTimer(other.id)
      if (opts?.onReject !== undefined) opts.onReject(other)
    }
    emitFile(s.range.file)
  }

  function reject(id: string): void {
    const s = suggestions.get(id)
    if (s === undefined) return
    suggestions.delete(id)
    clearTimer(id)
    if (opts?.onReject !== undefined) opts.onReject(s)
    emitFile(s.range.file)
  }

  return {
    propose,
    retract,
    accept,
    reject,

    getAll(): ReadonlyArray<InlineSuggestion> {
      return Object.freeze(Array.from(suggestions.values()))
    },

    inFile,

    inRange(
      file: string,
      fromLine: number,
      toLine: number,
    ): ReadonlyArray<InlineSuggestion> {
      const probe: SuggestionRange = { file, fromLine, toLine }
      const out: InlineSuggestion[] = []
      for (const s of suggestions.values()) {
        if (rangesOverlap(s.range, probe)) out.push(s)
      }
      return Object.freeze(out)
    },

    topAtLine(file: string, line: number): InlineSuggestion | undefined {
      let best: InlineSuggestion | undefined
      for (const s of suggestions.values()) {
        if (s.range.file !== file) continue
        if (line < s.range.fromLine || line >= s.range.toLine) continue
        if (best === undefined || s.confidence > best.confidence) {
          best = s
        }
      }
      return best
    },

    subscribeFile(
      file: string,
      listener: (s: ReadonlyArray<InlineSuggestion>) => void,
    ): () => void {
      let set = fileListeners.get(file)
      if (set === undefined) {
        set = new Set()
        fileListeners.set(file, set)
      }
      set.add(listener)
      return () => {
        set!.delete(listener)
        if (set!.size === 0) fileListeners.delete(file)
      }
    },
  }
}

export function createSuggestionController(
  manager: InlineSuggestionManager,
  suggestionId: string,
): SuggestionController {
  const found = manager.getAll().find((s) => s.id === suggestionId)
  if (found === undefined) {
    throw new Error(`InlineSuggestion not found: ${suggestionId}`)
  }
  const suggestion: InlineSuggestion = found

  const lineLabel =
    suggestion.range.fromLine === suggestion.range.toLine - 1
      ? `line ${suggestion.range.fromLine}`
      : `lines ${suggestion.range.fromLine}-${suggestion.range.toLine - 1}`

  const baseLabel = `Suggestion from ${suggestion.agentName}: replace ${lineLabel}. Press Tab to accept or Escape to reject.`

  function handleKeyDown(e: SuggestionKeyEvent): void {
    if (e.metaKey === true || e.ctrlKey === true || e.altKey === true) return
    if (e.key === 'Tab' && e.shiftKey !== true) {
      e.preventDefault()
      manager.accept(suggestionId)
      return
    }
    if (e.key === 'Escape') {
      e.preventDefault()
      manager.reject(suggestionId)
    }
  }

  return Object.freeze({
    suggestion,

    getRootProps(): SuggestionRootProps {
      return Object.freeze({
        id: `suggestion-${suggestion.id}`,
        role: 'region' as const,
        'aria-label': baseLabel,
        'aria-keyshortcuts': 'Tab Escape' as const,
        'data-state': 'suggested' as const,
        'data-agent-color': `--k-${suggestion.agentColorSlot}`,
        tabIndex: 0 as const,
        onKeyDown: handleKeyDown,
      })
    },

    getAcceptButtonProps(): SuggestionButtonProps {
      return Object.freeze({
        type: 'button' as const,
        'aria-label': `Accept suggestion from ${suggestion.agentName}`,
        'aria-keyshortcuts': 'Tab',
        onClick: () => manager.accept(suggestionId),
      })
    },

    getRejectButtonProps(): SuggestionButtonProps {
      return Object.freeze({
        type: 'button' as const,
        'aria-label': `Reject suggestion from ${suggestion.agentName}`,
        'aria-keyshortcuts': 'Escape',
        onClick: () => manager.reject(suggestionId),
      })
    },
  })
}
