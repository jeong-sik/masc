import { signal } from '@preact/signals'
import { fetchIdeRegions, type IdeCodeRegion } from '../../api/ide'
import { isRecord, asNullableString, isPositiveSafeInteger } from '../common/normalize'

export interface CodeDocumentSource {
  readonly file_path: string | null
  readonly language: string
  readonly content: string
}

export interface CodeDocumentLine {
  readonly num: number
  readonly text: string
  readonly is_blank: boolean
}

export interface CodeDocumentSnapshot extends CodeDocumentSource {
  readonly lines: ReadonlyArray<CodeDocumentLine>
}

export type CodeDocumentRegionsState = 'idle' | 'loading' | 'ready' | 'error'

export interface CodeDocumentStore {
  readonly load: (source: unknown) => boolean
  readonly invalidate: () => void
  readonly document: () => CodeDocumentSnapshot
  readonly lines: () => ReadonlyArray<CodeDocumentLine>
  readonly line: (lineNumber: number) => CodeDocumentLine | null
  readonly regions: () => ReadonlyArray<IdeCodeRegion>
  readonly regionsLoading: () => boolean
  readonly regionsState: () => CodeDocumentRegionsState
  readonly subscribeRegions: (listener: () => void) => () => void
  readonly loadRegions: (
    filePath: string,
    opts?: { keeper?: string; repoId?: string | null; signal?: AbortSignal },
  ) => Promise<void>
  readonly subscribe: (listener: () => void) => () => void
}

const EMPTY_DOCUMENT: CodeDocumentSnapshot = {
  file_path: null,
  language: 'text',
  content: '',
  lines: [],
}

export function createCodeDocumentStore(
  initialSource: unknown,
  opts: { readonly maxLines?: number } = {},
): CodeDocumentStore {
  const maxLines = normalizeMaxLines(opts.maxLines)
  const initial = normalizeSource(initialSource, maxLines) ?? EMPTY_DOCUMENT
  const snapshot = signal<CodeDocumentSnapshot>(initial)
  const regionsSignal = signal<ReadonlyArray<IdeCodeRegion>>([])
  const regionsStateSignal = signal<CodeDocumentRegionsState>('idle')
  let regionRequestId = 0

  const load = (source: unknown): boolean => {
    const next = normalizeSource(source, maxLines)
    if (!next) return false
    if (next.file_path !== snapshot.peek().file_path) {
      regionRequestId += 1
      regionsSignal.value = []
      regionsStateSignal.value = 'idle'
    }
    snapshot.value = next
    return true
  }

  const invalidate = (): void => {
    regionRequestId += 1
    snapshot.value = EMPTY_DOCUMENT
    regionsSignal.value = []
    regionsStateSignal.value = 'idle'
  }

  const loadRegions = async (
    filePath: string,
    opts?: { keeper?: string; repoId?: string | null; signal?: AbortSignal },
  ): Promise<void> => {
    const requestId = regionRequestId + 1
    regionRequestId = requestId
    regionsStateSignal.value = 'loading'
    try {
      const fetched = await fetchIdeRegions(filePath, opts ?? {})
      if (opts?.signal?.aborted || requestId !== regionRequestId) return
      regionsSignal.value = fetched
      regionsStateSignal.value = 'ready'
    } catch (error) {
      if (!opts?.signal?.aborted && requestId === regionRequestId) {
        regionsStateSignal.value = 'error'
      }
      throw error
    } finally {
      // A stale request must never clear the visible loading state of the
      // newer file/request that superseded it.
      if (requestId === regionRequestId && opts?.signal?.aborted) {
        regionsStateSignal.value = 'idle'
      }
    }
  }

  const subscribe = (listener: () => void): (() => void) => {
    let sawInitialSnapshot = false
    return snapshot.subscribe(() => {
      if (!sawInitialSnapshot) {
        sawInitialSnapshot = true
        return
      }
      listener()
    })
  }

  return {
    load,
    invalidate,
    document: () => snapshot.value,
    lines: () => snapshot.value.lines,
    line: lineNumber => snapshot.value.lines[lineNumber - 1] ?? null,
    regions: () => regionsSignal.value,
    regionsLoading: () => regionsStateSignal.value === 'loading',
    regionsState: () => regionsStateSignal.value,
    subscribeRegions: (listener: () => void) => {
      // Preact Signals notify immediately on subscribe. Wait until both
      // region-related signals have delivered that initial value, then expose
      // later loading/data changes as one document-metadata subscription.
      let initialNotifications = 2
      const notify = (): void => {
        if (initialNotifications > 0) {
          initialNotifications -= 1
          return
        }
        listener()
      }
      const unsubscribeRegions = regionsSignal.subscribe(notify)
      const unsubscribeState = regionsStateSignal.subscribe(notify)
      return () => {
        unsubscribeRegions()
        unsubscribeState()
      }
    },
    loadRegions,
    subscribe,
  }
}

function normalizeSource(source: unknown, maxLines: number): CodeDocumentSnapshot | null {
  if (!isRecord(source)) return null
  const filePath = asNullableString(source.file_path)
  const language = asNullableString(source.language)
  if (!filePath || !language || typeof source.content !== 'string') return null

  const content = source.content.replace(/\r\n?/g, '\n')
  return {
    file_path: filePath,
    language,
    content,
    lines: parseLines(content, maxLines),
  }
}

function parseLines(content: string, maxLines: number): ReadonlyArray<CodeDocumentLine> {
  if (content === '') return []
  const end = content.endsWith('\n') ? content.length - 1 : content.length
  const lines: CodeDocumentLine[] = []
  let start = 0

  while (lines.length < maxLines && start <= end) {
    const newlineIndex = content.indexOf('\n', start)
    const lineEnd = newlineIndex === -1 || newlineIndex > end ? end : newlineIndex
    const text = content.slice(start, lineEnd)
    lines.push({
      num: lines.length + 1,
      text,
      is_blank: text.trim() === '',
    })

    if (newlineIndex === -1 || newlineIndex >= end) break
    start = newlineIndex + 1
  }

  return lines
}

function normalizeMaxLines(value: number | undefined): number {
  if (isPositiveSafeInteger(value)) return value
  return 5_000
}
