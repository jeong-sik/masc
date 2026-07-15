import { Decoration, EditorView, WidgetType, lineNumbers, type DecorationSet } from '@codemirror/view'
import { Annotation, EditorState, Extension, RangeSetBuilder, StateField, StateEffect, type Text } from '@codemirror/state'
import type { LineOwnership } from './keeper-line-ownership-store'

// ── Read-only lock ────────────────────────────────────────────────
// Prevents all user input. CM6 6.x uses EditorState.changeFilter.

export const internalDocumentSync = Annotation.define<boolean>()

export function readOnlyExt(): Extension {
  return EditorState.changeFilter.of(transaction =>
    transaction.annotation(internalDocumentSync) === true,
  )
}

// ── Re-exports from extracted modules ─────────────────────────────
// Theme, language, trace gutter, and ownership were extracted to
// keep this file under the 300-line threshold.

export { themeExt, syntaxHighlightExt } from './ide-editor-theme'
export {
  languageExt,
  languageIdForFilePath,
} from './ide-editor-language'
export {
  type EditorKeeperTraceLineEvent,
  type EditorKeeperTraceLine,
  type KeeperTraceLineGutterOptions,
  keeperTraceLineGutterExt,
  keeperTraceLineChipExt,
  pushKeeperTraceLines,
  keeperTraceLinesForFile,
} from './ide-editor-trace-gutter'
export {
  setOwnership,
  pushOwnership,
  blameExtensions,
} from './ide-editor-ownership'

// ── Keeper line selection handler ─────────────────────────────────

export function keeperLineSelectExt(
  getOwnership: () => ReadonlyMap<number, LineOwnership>,
  onKeeperLineSelect: (keeperId: string, line: number) => void,
): Extension {
  return EditorView.domEventHandlers({
    click(event, view) {
      if (!(event instanceof MouseEvent) || event.button !== 0) return false
      const pos = view.posAtCoords({ x: event.clientX, y: event.clientY })
      if (pos === null) return false
      const line = view.state.doc.lineAt(pos)
      const owner = getOwnership().get(line.number)
      if (!owner) return false
      onKeeperLineSelect(owner.keeper_id, line.number)
      return false
    },
  })
}

// ── Context focus highlight ───────────────────────────────────────

export interface EditorContextFocusLine {
  readonly line: number
  readonly surface?: string
  readonly label?: string
  readonly keeperId?: string
  readonly linkCount?: number
}

const setContextFocusLine = StateEffect.define<EditorContextFocusLine | null>()

class ContextFocusChip extends WidgetType {
  constructor(private readonly focus: EditorContextFocusLine) {
    super()
  }

  toDOM(): HTMLElement {
    const el = document.createElement('span')
    el.className = 'cm-masc-context-focus-chip'
    const parts = contextFocusChipParts(this.focus)
    el.textContent = parts.join(' · ')
    el.title = `Focused ${parts.join(' · ')}`
    el.setAttribute('aria-label', contextFocusChipAriaLabel(this.focus))
    return el
  }

  eq(other: ContextFocusChip): boolean {
    return this.focus.line === other.focus.line
      && this.focus.surface === other.focus.surface
      && this.focus.label === other.focus.label
      && this.focus.keeperId === other.focus.keeperId
      && this.focus.linkCount === other.focus.linkCount
  }
}

const contextFocusLineField = StateField.define<DecorationSet>({
  create() {
    return Decoration.none
  },
  update(value, tr) {
    const mapped = value.map(tr.changes)
    for (const effect of tr.effects) {
      if (!effect.is(setContextFocusLine)) continue
      const focus = effect.value
      if (focus === null || focus.line < 1 || focus.line > tr.state.doc.lines) {
        return Decoration.none
      }
      const line = tr.state.doc.line(focus.line)
      return Decoration.set([
        Decoration.line({ class: 'cm-masc-context-focus' }).range(line.from),
        Decoration.widget({
          widget: new ContextFocusChip(focus),
          side: 1,
        }).range(line.to),
      ])
    }
    return mapped
  },
  provide: field => EditorView.decorations.from(field),
})

export function contextFocusLineExt(): Extension {
  return contextFocusLineField
}

export function focusEditorContextLine(
  view: EditorView,
  focus: number | EditorContextFocusLine | undefined,
): boolean {
  const nextFocus = typeof focus === 'number' ? { line: focus } : focus
  if (nextFocus === undefined || nextFocus.line < 1 || nextFocus.line > view.state.doc.lines) {
    view.dispatch({ effects: [setContextFocusLine.of(null)] })
    return false
  }
  const line = view.state.doc.line(nextFocus.line)
  view.dispatch({
    selection: { anchor: line.from },
    effects: [
      setContextFocusLine.of(nextFocus),
      EditorView.scrollIntoView(line.from, { y: 'center' }),
    ],
  })
  view.focus()
  return true
}

function contextFocusChipParts(focus: EditorContextFocusLine): ReadonlyArray<string> {
  return [
    focus.surface?.trim() || `L${focus.line}`,
    focus.label?.trim() || null,
    focus.keeperId?.trim() ? `keeper ${focus.keeperId.trim()}` : null,
    focus.linkCount && focus.linkCount > 0 ? `${focus.linkCount} links` : null,
  ].filter((part): part is string => part !== null)
}

function contextFocusChipAriaLabel(focus: EditorContextFocusLine): string {
  const parts = contextFocusChipParts(focus)
  return `Focused context on line ${focus.line}: ${parts.join(', ')}`
}

// ── Annotation line chips ─────────────────────────────────────────

export interface EditorAnnotationLine {
  readonly id: string
  readonly line: number
  readonly kind: string
  readonly keeperId: string
  readonly taskId?: string | null
}

const setAnnotationLines = StateEffect.define<ReadonlyArray<EditorAnnotationLine>>()

class AnnotationLineChip extends WidgetType {
  constructor(private readonly annotations: ReadonlyArray<EditorAnnotationLine>) {
    super()
  }

  toDOM(): HTMLElement {
    const el = document.createElement('span')
    el.className = 'cm-masc-annotation-chip'
    const text = annotationLineChipText(this.annotations)
    el.textContent = text
    el.title = annotationLineChipTitle(this.annotations)
    el.setAttribute('aria-label', annotationLineChipAriaLabel(this.annotations))
    return el
  }

  eq(other: AnnotationLineChip): boolean {
    return annotationLineKey(this.annotations) === annotationLineKey(other.annotations)
  }
}

const annotationLineField = StateField.define<DecorationSet>({
  create() {
    return Decoration.none
  },
  update(value, tr) {
    const mapped = value.map(tr.changes)
    for (const effect of tr.effects) {
      if (!effect.is(setAnnotationLines)) continue
      return buildAnnotationLineDecorations(tr.state.doc, effect.value)
    }
    return mapped
  },
  provide: field => EditorView.decorations.from(field),
})

export function annotationLineChipExt(): Extension {
  return annotationLineField
}

export function pushAnnotationLines(
  view: EditorView,
  annotations: ReadonlyArray<EditorAnnotationLine>,
): void {
  view.dispatch({ effects: [setAnnotationLines.of(annotations)] })
}

function buildAnnotationLineDecorations(
  doc: Text,
  annotations: ReadonlyArray<EditorAnnotationLine>,
): DecorationSet {
  const byLine = new Map<number, EditorAnnotationLine[]>()
  for (const annotation of annotations) {
    if (annotation.line < 1 || annotation.line > doc.lines) continue
    const existing = byLine.get(annotation.line) ?? []
    existing.push(annotation)
    byLine.set(annotation.line, existing)
  }
  const builder = new RangeSetBuilder<Decoration>()
  const sortedLines = [...byLine.entries()].sort(([left], [right]) => left - right)
  for (const [lineNumber, lineAnnotations] of sortedLines) {
    const line = doc.line(lineNumber)
    builder.add(
      line.to,
      line.to,
      Decoration.widget({
        widget: new AnnotationLineChip(lineAnnotations.sort(annotationLineSort)),
        side: 2,
      }),
    )
  }
  return builder.finish()
}

function annotationLineSort(left: EditorAnnotationLine, right: EditorAnnotationLine): number {
  return left.kind.localeCompare(right.kind)
    || left.keeperId.localeCompare(right.keeperId)
    || left.id.localeCompare(right.id)
}

function annotationLineChipText(annotations: ReadonlyArray<EditorAnnotationLine>): string {
  const first = annotations[0]
  if (!first) return 'Annotation'
  const parts = [
    first.kind,
    first.taskId ? `task ${first.taskId}` : null,
    `keeper ${first.keeperId}`,
    annotations.length > 1 ? `+${annotations.length - 1}` : null,
  ].filter((part): part is string => part !== null)
  return parts.join(' · ')
}

function annotationLineChipTitle(annotations: ReadonlyArray<EditorAnnotationLine>): string {
  return annotations.map(annotation => [
    annotation.kind,
    annotation.taskId ? `task ${annotation.taskId}` : null,
    `keeper ${annotation.keeperId}`,
  ].filter((part): part is string => part !== null).join(' · ')).join('\n')
}

function annotationLineChipAriaLabel(annotations: ReadonlyArray<EditorAnnotationLine>): string {
  const first = annotations[0]
  const line = first?.line ?? 0
  return `Line ${line} annotation context: ${annotationLineChipText(annotations)}`
}

function annotationLineKey(annotations: ReadonlyArray<EditorAnnotationLine>): string {
  return annotations.map(annotation =>
    `${annotation.id}:${annotation.line}:${annotation.kind}:${annotation.keeperId}:${annotation.taskId ?? ''}`,
  ).join('|')
}

// ── Line number gutter ────────────────────────────────────────────

export function lineNumberExt(): Extension {
  return lineNumbers()
}
