import { signal } from '@preact/signals'
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

export interface CodeDocumentStore {
  readonly load: (source: unknown) => boolean
  readonly invalidate: () => void
  readonly document: () => CodeDocumentSnapshot
  readonly lines: () => ReadonlyArray<CodeDocumentLine>
  readonly line: (lineNumber: number) => CodeDocumentLine | null
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

  const load = (source: unknown): boolean => {
    const next = normalizeSource(source, maxLines)
    if (!next) return false
    snapshot.value = next
    return true
  }

  const invalidate = (): void => {
    snapshot.value = EMPTY_DOCUMENT
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
