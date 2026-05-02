/**
 * AnchoredThreadRail - framework-agnostic controller for RFC 0021.
 *
 * The controller scopes review/conversation threads to the active file,
 * answers line-range lookup queries, and emits focus changes without
 * coupling the editor viewport to the rail renderer.
 */

export type ThreadKind = 'flag' | 'question' | 'approve' | 'note' | 'suggest'

export interface ThreadAnchor {
  readonly file_path: string
  readonly line_start: number | null
  readonly line_end: number | null
  readonly symbol_hint?: string
}

export interface AnchoredThread {
  readonly id: string
  readonly kind: ThreadKind
  readonly author_keeper_id: string
  readonly anchor: ThreadAnchor
  readonly body: string
  readonly created_ms: number
  readonly resolved: boolean
  readonly reply_count: number
}

export interface AnchoredThreadRailController {
  readonly filePath: () => string
  readonly visibleThreads: () => ReadonlyArray<AnchoredThread>
  readonly threadsForLine: (line: number) => ReadonlyArray<AnchoredThread>
  readonly focusedThreadId: () => string | null
  readonly focusedThread: () => AnchoredThread | null
  readonly focusThread: (id: string) => boolean
  readonly clearFocus: () => void
  readonly subscribe: (listener: () => void) => () => void
}

export function createAnchoredThreadRail(opts: {
  readonly filePath: () => string
  readonly threads: () => ReadonlyArray<AnchoredThread>
}): AnchoredThreadRailController {
  let focusedId: string | null = null
  const listeners = new Set<() => void>()

  const filePath = (): string => opts.filePath()

  const visibleThreads = (): ReadonlyArray<AnchoredThread> => {
    const activeFile = opts.filePath()
    return opts.threads()
      .filter(thread => validThreadForFile(thread, activeFile))
      .slice()
      .sort(compareThreads)
  }

  const focusedThread = (): AnchoredThread | null => {
    if (focusedId === null) return null
    return visibleThreads().find(thread => thread.id === focusedId) ?? null
  }

  const focusedThreadId = (): string | null => focusedThread()?.id ?? null

  const emit = (): void => {
    for (const listener of listeners) listener()
  }

  const focusThread = (id: string): boolean => {
    const next = visibleThreads().find(thread => thread.id === id)
    if (next === undefined) return false
    if (focusedId === next.id) return true
    focusedId = next.id
    emit()
    return true
  }

  const clearFocus = (): void => {
    if (focusedId === null) return
    focusedId = null
    emit()
  }

  const threadsForLine = (line: number): ReadonlyArray<AnchoredThread> => {
    if (!Number.isSafeInteger(line) || line < 1) return []
    return visibleThreads().filter(thread => anchorContainsLine(thread.anchor, line))
  }

  const subscribe = (listener: () => void): (() => void) => {
    listeners.add(listener)
    return () => {
      listeners.delete(listener)
    }
  }

  return {
    filePath,
    visibleThreads,
    threadsForLine,
    focusedThreadId,
    focusedThread,
    focusThread,
    clearFocus,
    subscribe,
  }
}

function compareThreads(a: AnchoredThread, b: AnchoredThread): number {
  if (a.created_ms !== b.created_ms) return b.created_ms - a.created_ms
  return a.id.localeCompare(b.id)
}

function validThreadForFile(thread: AnchoredThread, filePath: string): boolean {
  if (thread.id.trim() === '') return false
  if (thread.author_keeper_id.trim() === '') return false
  if (!Number.isFinite(thread.created_ms)) return false
  if (!Number.isSafeInteger(thread.reply_count) || thread.reply_count < 0) return false
  return validAnchorForFile(thread.anchor, filePath)
}

function validAnchorForFile(anchor: ThreadAnchor, filePath: string): boolean {
  if (anchor.file_path !== filePath) return false
  const start = anchor.line_start
  const end = anchor.line_end
  if (start === null && end === null) return true
  if (start === null || end === null) return false
  return Number.isSafeInteger(start) && Number.isSafeInteger(end) && start >= 1 && end >= start
}

function anchorContainsLine(anchor: ThreadAnchor, line: number): boolean {
  if (anchor.line_start === null || anchor.line_end === null) return false
  return line >= anchor.line_start && line <= anchor.line_end
}
