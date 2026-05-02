import { signal } from '@preact/signals'

export interface CodeDocumentSource {
  readonly file_path: string
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
  readonly document: () => CodeDocumentSnapshot
  readonly lines: () => ReadonlyArray<CodeDocumentLine>
  readonly line: (lineNumber: number) => CodeDocumentLine | null
  readonly subscribe: (listener: () => void) => () => void
}

const EMPTY_DOCUMENT: CodeDocumentSnapshot = {
  file_path: '(no file)',
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
    document: () => snapshot.value,
    lines: () => snapshot.value.lines,
    line: lineNumber => snapshot.value.lines[lineNumber - 1] ?? null,
    subscribe,
  }
}

function normalizeSource(source: unknown, maxLines: number): CodeDocumentSnapshot | null {
  if (!isRecord(source)) return null
  const filePath = normalizeNonEmptyString(source.file_path)
  const language = normalizeNonEmptyString(source.language)
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
  const rawLines = content.endsWith('\n')
    ? content.slice(0, -1).split('\n')
    : content.split('\n')
  return rawLines.slice(0, maxLines).map((text, index) => ({
    num: index + 1,
    text,
    is_blank: text.trim() === '',
  }))
}

function normalizeMaxLines(value: number | undefined): number {
  if (typeof value === 'number' && Number.isSafeInteger(value) && value > 0) return value
  return 5_000
}

function normalizeNonEmptyString(value: unknown): string | null {
  return typeof value === 'string' && value.trim() !== '' ? value.trim() : null
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}
