import { Decoration, EditorView, GutterMarker, WidgetType, gutter, lineNumbers, type DecorationSet, type ViewUpdate } from '@codemirror/view'
import { Annotation, EditorState, Extension, RangeSetBuilder, StateField, StateEffect, type Text } from '@codemirror/state'
import {
  defaultHighlightStyle,
  StreamLanguage,
  syntaxHighlighting,
  type StringStream,
  type StreamParser,
} from '@codemirror/language'
import type { LineOwnership } from './keeper-line-ownership-store'
import type { KeeperTraceEvent, KeeperTraceSource } from './keeper-trace-store'
import { kSigil } from '../keeper-badge'

// ── Read-only lock ────────────────────────────────────────────────
// Prevents all user input. CM6 6.x uses EditorState.changeFilter.

export const internalDocumentSync = Annotation.define<boolean>()

export function readOnlyExt(): Extension {
  return EditorState.changeFilter.of(transaction =>
    transaction.annotation(internalDocumentSync) === true,
  )
}

// ── Theme from design-system CSS variables ────────────────────────
// Maps semantic tokens to CM6 theme facets so the editor matches the
// dashboard light/dark theme without a hardcoded theme object.

export function themeExt(): Extension {
  return EditorView.theme({
    '&': {
      background: 'var(--color-bg-page)',
      color: 'var(--color-fg-secondary)',
      fontFamily: 'var(--font-mono)',
      fontSize: 'var(--fs-13)',
      lineHeight: '1.6',
      height: '100%',
    },
    '.cm-scroller': {
      overflow: 'auto',
      minHeight: '0',
    },
    '.cm-content': {
      caretColor: 'transparent',
      padding: 'var(--sp-2) 0',
      minHeight: '100%',
    },
    '.cm-line': {
      padding: '0 var(--sp-3)',
    },
    '.cm-gutters': {
      background: 'var(--color-bg-page)',
      color: 'var(--color-fg-disabled)',
      border: 'none',
      fontSize: 'var(--fs-11)',
      minWidth: '44px',
      position: 'sticky',
      left: '0',
      zIndex: '2',
    },
    '.cm-gutterElement': {
      textAlign: 'right',
      paddingRight: 'var(--sp-2)',
    },
    '.cm-lineNumbers': {
      borderRight: '1px solid var(--color-border-default)',
    },
    '.cm-blame-gutter': {
      minWidth: '78px',
      borderRight: '1px solid var(--color-border-default)',
      background: 'var(--color-bg-surface)',
    },
    '.cm-blame-gutter .cm-gutterElement': {
      padding: '0 var(--sp-2)',
      textAlign: 'left',
    },
    '.cm-blame-marker': {
      display: 'inline-grid',
      gridTemplateColumns: '18px minmax(0, 1fr)',
      alignItems: 'center',
      gap: 'var(--sp-1)',
      width: '68px',
      minWidth: '0',
      color: 'var(--cm-blame-color)',
      fontSize: 'var(--fs-10)',
      lineHeight: '1.4',
    },
    '.cm-blame-sigil': {
      display: 'inline-flex',
      alignItems: 'center',
      justifyContent: 'center',
      width: '16px',
      height: '14px',
      borderRadius: 'var(--r-0)',
      color: 'var(--color-bg-page)',
      background: 'var(--cm-blame-color)',
      fontSize: 'var(--fs-9)',
      fontWeight: '700',
      letterSpacing: '0',
    },
    '.cm-blame-name': {
      overflow: 'hidden',
      textOverflow: 'ellipsis',
      whiteSpace: 'nowrap',
    },
    '.cm-trace-gutter': {
      minWidth: '34px',
      borderRight: '1px solid var(--color-border-default)',
      background: 'var(--color-bg-page)',
    },
    '.cm-trace-gutter .cm-gutterElement': {
      padding: '0 var(--sp-1)',
      textAlign: 'left',
    },
    '.cm-trace-stack': {
      display: 'inline-flex',
      alignItems: 'center',
      justifyContent: 'flex-start',
      gap: '2px',
      minWidth: '28px',
      height: '100%',
      padding: '0',
      border: '0',
      background: 'transparent',
      color: 'inherit',
      cursor: 'pointer',
    },
    '.cm-trace-stack:focus-visible': {
      outline: '1px solid var(--color-accent-fg)',
      outlineOffset: '1px',
    },
    '.cm-trace-dot': {
      display: 'inline-block',
      width: '6px',
      height: '6px',
      borderRadius: '999px',
      background: 'var(--cm-trace-color)',
      boxShadow: '0 0 0 1px var(--color-bg-page)',
    },
    '.cm-trace-overflow': {
      color: 'var(--color-fg-muted)',
      fontSize: 'var(--fs-9)',
      lineHeight: '1',
    },
    '&.cm-focused': {
      outline: 'none',
    },
    '.cm-cursor': {
      display: 'none',
    },
    '.cm-selectionBackground': {
      background: 'transparent !important',
    },
    '.cm-line.cm-masc-context-focus': {
      background: 'color-mix(in srgb, var(--color-accent-fg) 12%, transparent)',
      boxShadow: 'inset 2px 0 0 var(--color-accent-fg)',
    },
    '.cm-masc-context-focus-chip': {
      display: 'inline-flex',
      alignItems: 'center',
      maxWidth: '36ch',
      marginLeft: 'var(--sp-2)',
      padding: '0 var(--sp-2)',
      border: '1px solid var(--color-border-default)',
      borderRadius: 'var(--r-0)',
      background: 'var(--color-bg-elevated)',
      color: 'var(--color-accent-fg)',
      fontFamily: 'var(--font-mono)',
      fontSize: 'var(--fs-10)',
      lineHeight: '1.4',
      verticalAlign: 'baseline',
      whiteSpace: 'nowrap',
      overflow: 'hidden',
      textOverflow: 'ellipsis',
      pointerEvents: 'none',
      userSelect: 'none',
    },
    '.cm-masc-annotation-chip': {
      display: 'inline-flex',
      alignItems: 'center',
      maxWidth: '34ch',
      marginLeft: 'var(--sp-2)',
      padding: '0 var(--sp-2)',
      border: '1px solid var(--color-border-default)',
      borderRadius: 'var(--r-0)',
      background: 'var(--color-bg-surface)',
      color: 'var(--color-fg-muted)',
      fontFamily: 'var(--font-mono)',
      fontSize: 'var(--fs-10)',
      lineHeight: '1.4',
      verticalAlign: 'baseline',
      whiteSpace: 'nowrap',
      overflow: 'hidden',
      textOverflow: 'ellipsis',
      pointerEvents: 'none',
      userSelect: 'none',
    },
  })
}

export function syntaxHighlightExt(): Extension {
  return syntaxHighlighting(defaultHighlightStyle, { fallback: true })
}

// ── Blame gutter ──────────────────────────────────────────────────
// Left gutter showing keeper ownership per line. Uses a StateEffect
// to push ownership updates into the gutter marker.

interface BlameMarkerValue {
  readonly keeperId: string
  readonly hueIndex: number
  readonly editKind: string
}

class BlameMarker extends GutterMarker {
  constructor(private readonly info: BlameMarkerValue | null) {
    super()
  }

  toDOM(): HTMLElement {
    const el = document.createElement('span')
    if (!this.info) {
      el.textContent = '—'
      el.style.color = 'var(--color-fg-disabled)'
      el.style.fontSize = 'var(--fs-11)'
      return el
    }
    const slot = Math.min(12, Math.max(1, this.info.hueIndex || 1))
    const color = `var(--color-keeper-${slot}, var(--k-${slot}))`
    el.className = 'cm-blame-marker'
    el.style.setProperty('--cm-blame-color', color)
    el.title = `${this.info.keeperId} · ${this.info.editKind}`
    const sigil = document.createElement('span')
    sigil.className = 'cm-blame-sigil'
    sigil.textContent = kSigil(this.info.keeperId)
    sigil.setAttribute('aria-hidden', 'true')
    const name = document.createElement('span')
    name.className = 'cm-blame-name'
    name.textContent = this.info.keeperId
    el.append(sigil, name)
    return el
  }

  eq(other: BlameMarker): boolean {
    if (!this.info && !other.info) return true
    if (!this.info || !other.info) return false
    return this.info.keeperId === other.info.keeperId && this.info.editKind === other.info.editKind
  }
}

const BLAME_EMPTY = new BlameMarker(null)

const setOwnership = StateEffect.define<ReadonlyMap<number, LineOwnership>>()

const blameMarkerField = StateField.define<BlameMarker[]>({
  create() {
    return []
  },
  update(markers, tr) {
    for (const effect of tr.effects) {
      if (effect.is(setOwnership)) {
        const ownership = effect.value
        const newMarkers: BlameMarker[] = []
        const doc = tr.state.doc
        for (let i = 1; i <= doc.lines; i++) {
          const owner = ownership.get(i)
          if (owner) {
            newMarkers.push(new BlameMarker({
              keeperId: owner.keeper_id,
              hueIndex: owner.hue_index,
              editKind: owner.last_edit_kind,
            }))
          } else {
            newMarkers.push(BLAME_EMPTY)
          }
        }
        return newMarkers
      }
    }
    return markers
  },
})

function blameGutterExt(): Extension {
  return [
    blameMarkerField,
    gutter({
      class: 'cm-blame-gutter',
      lineMarkerChange(update: ViewUpdate) {
        return update.startState.field(blameMarkerField, false) !== update.state.field(blameMarkerField, false)
      },
      lineMarker(view, block) {
        const line = view.state.doc.lineAt(block.from)
        const field = view.state.field(blameMarkerField, false)
        return field?.[line.number - 1] ?? BLAME_EMPTY
      },
      initialSpacer: () => BLAME_EMPTY,
    }),
  ]
}

export function pushOwnership(view: EditorView, ownership: ReadonlyMap<number, LineOwnership>): void {
  view.dispatch({ effects: [setOwnership.of(ownership)] })
}

// ── Keeper trace gutter ───────────────────────────────────────────
// File-scoped line trace dots for the `keeper-trace` layer.

const TRACE_DOT_CAP = 3

export interface EditorKeeperTraceLineEvent {
  readonly id?: string
  readonly source: KeeperTraceSource
  readonly keeperName: string
  readonly count: number
  readonly tsMs: number
  readonly filePath?: string
  readonly line?: number
  readonly eventId?: string
  readonly threadId?: string
  readonly surface?: string
  readonly goalId?: string
  readonly taskId?: string
  readonly boardPostId?: string
  readonly commentId?: string
  readonly prId?: string
  readonly gitRef?: string
  readonly logId?: string
  readonly sessionId?: string
  readonly operationId?: string
  readonly workerRunId?: string
}

export interface EditorKeeperTraceLine {
  readonly line: number
  readonly events: ReadonlyArray<EditorKeeperTraceLineEvent>
}

export interface KeeperTraceLineGutterOptions {
  readonly getTraceLines?: () => ReadonlyArray<EditorKeeperTraceLine>
  readonly onTraceLineSelect?: (event: EditorKeeperTraceLineEvent, line: number) => void
}

const setKeeperTraceLines = StateEffect.define<ReadonlyArray<EditorKeeperTraceLine>>()

class TraceLineMarker extends GutterMarker {
  constructor(
    private readonly line: number,
    private readonly events: ReadonlyArray<EditorKeeperTraceLineEvent>,
  ) {
    super()
  }

  toDOM(): HTMLElement {
    if (this.events.length === 0) {
      const el = document.createElement('span')
      el.className = 'cm-trace-stack'
      el.setAttribute('aria-hidden', 'true')
      return el
    }
    const el = document.createElement('button')
    el.type = 'button'
    el.className = 'cm-trace-stack'
    el.dataset.line = String(this.line)
    el.setAttribute('aria-label', traceLineAriaLabel(this.line, this.events))
    el.title = traceLineTitle(this.line, this.events)
    const visible = this.events.slice(0, TRACE_DOT_CAP)
    for (const event of visible) {
      const dot = document.createElement('span')
      dot.className = 'cm-trace-dot'
      dot.setAttribute('role', 'img')
      dot.setAttribute('aria-label', traceEventLabel(event))
      dot.setAttribute('data-source', event.source)
      dot.style.setProperty('--cm-trace-color', traceSourceColor(event.source))
      el.append(dot)
    }
    const overflow = this.events.length - visible.length
    if (overflow > 0) {
      const more = document.createElement('span')
      more.className = 'cm-trace-overflow'
      more.textContent = `+${overflow}`
      more.setAttribute('aria-label', `${overflow} more trace events`)
      el.append(more)
    }
    return el
  }

  eq(other: TraceLineMarker): boolean {
    return this.line === other.line && traceLineKey(this.events) === traceLineKey(other.events)
  }
}

const TRACE_SPACER = new TraceLineMarker(0, [])

const keeperTraceLineField = StateField.define<ReadonlyMap<number, TraceLineMarker>>({
  create() {
    return new Map()
  },
  update(markers, tr) {
    for (const effect of tr.effects) {
      if (!effect.is(setKeeperTraceLines)) continue
      const next = new Map<number, TraceLineMarker>()
      for (const traceLine of effect.value) {
        if (traceLine.line < 1 || traceLine.line > tr.state.doc.lines || traceLine.events.length === 0) continue
        next.set(traceLine.line, new TraceLineMarker(traceLine.line, traceLine.events))
      }
      return next
    }
    return markers
  },
})

export function keeperTraceLineGutterExt(options: KeeperTraceLineGutterOptions = {}): Extension {
  const canSelect = options.getTraceLines && options.onTraceLineSelect
  return [
    keeperTraceLineField,
    gutter({
      class: 'cm-trace-gutter',
      lineMarkerChange(update: ViewUpdate) {
        return update.startState.field(keeperTraceLineField, false) !== update.state.field(keeperTraceLineField, false)
      },
      lineMarker(view, block) {
        const line = view.state.doc.lineAt(block.from)
        const field = view.state.field(keeperTraceLineField, false)
        return field?.get(line.number) ?? null
      },
      ...(canSelect
        ? {
            domEventHandlers: {
              click: (view, block, event) => selectTraceLineFromGutterClick(
                view.state.doc.lineAt(block.from).number,
                event,
                options.getTraceLines!,
                options.onTraceLineSelect!,
              ),
            },
          }
        : {}),
      initialSpacer: () => TRACE_SPACER,
    }),
  ]
}

function selectTraceLineFromGutterClick(
  blockLine: number,
  event: Event,
  getTraceLines: () => ReadonlyArray<EditorKeeperTraceLine>,
  onTraceLineSelect: (event: EditorKeeperTraceLineEvent, line: number) => void,
): boolean {
  if (!(event instanceof MouseEvent) || event.button !== 0) return false
  const target = event.target
  if (!(target instanceof Element)) return false
  const stack = target.closest('.cm-trace-stack')
  if (!(stack instanceof HTMLElement) || stack.getAttribute('aria-hidden') === 'true') return false
  const lineFromMarker = Number(stack.dataset.line)
  const line = Number.isSafeInteger(lineFromMarker) && lineFromMarker >= 1
    ? lineFromMarker
    : blockLine
  const traceLine = getTraceLines().find(candidate => candidate.line === line)
  const topEvent = traceLine?.events[0]
  if (!topEvent) return false
  event.stopPropagation()
  onTraceLineSelect(topEvent, line)
  return true
}

export function pushKeeperTraceLines(
  view: EditorView,
  traceLines: ReadonlyArray<EditorKeeperTraceLine>,
): void {
  view.dispatch({ effects: [setKeeperTraceLines.of(traceLines)] })
}

export function keeperTraceLinesForFile(
  filePath: string,
  events: ReadonlyArray<KeeperTraceEvent>,
): ReadonlyArray<EditorKeeperTraceLine> {
  const normalizedFilePath = filePath.trim()
  if (!normalizedFilePath) return []

  const byLine = new Map<number, EditorKeeperTraceLineEvent[]>()
  for (const event of events) {
    const filePath = traceEventFilePath(event)
    const line = traceEventLine(event)
    if (filePath !== normalizedFilePath) continue
    if (line === null) continue
    const existing = byLine.get(line) ?? []
    existing.push({
      id: event.id,
      source: event.source,
      keeperName: event.keeperName,
      count: event.count,
      tsMs: event.tsMs,
      filePath,
      line,
      eventId: event.source === 'activity-event' ? event.eventId : undefined,
      threadId: event.source === 'anchored-thread' ? event.threadId : undefined,
      surface: traceEventSurface(event),
      goalId: event.source === 'activity-event' ? event.goalId : undefined,
      taskId: event.source === 'activity-event' ? event.taskId : undefined,
      boardPostId: event.source === 'activity-event' ? event.boardPostId : undefined,
      commentId: event.source === 'activity-event' ? event.commentId : undefined,
      prId: event.source === 'activity-event' ? event.prId : undefined,
      gitRef: event.source === 'activity-event' ? event.gitRef : undefined,
      logId: event.source === 'activity-event' ? event.logId : undefined,
      sessionId: event.source === 'activity-event' ? event.sessionId : undefined,
      operationId: event.source === 'activity-event' ? event.operationId : undefined,
      workerRunId: event.source === 'activity-event' ? event.workerRunId : undefined,
    })
    byLine.set(line, existing)
  }

  return [...byLine.entries()]
    .sort(([left], [right]) => left - right)
    .map(([line, eventsForLine]) => ({
      line,
      events: eventsForLine.sort((left, right) => right.tsMs - left.tsMs),
    }))
}

function traceSourceColor(source: KeeperTraceSource): string {
  switch (source) {
    case 'anchored-thread':
      return 'var(--color-status-info)'
    case 'activity-event':
      return 'var(--color-status-info)'
    case 'cascade-hop':
      return 'var(--color-accent-fg)'
    case 'bdi-snapshot':
      return 'var(--color-status-ok)'
    case 'decision-log':
      return 'var(--color-status-warn)'
  }
}

function traceSourceLabel(source: KeeperTraceSource): string {
  switch (source) {
    case 'anchored-thread':
      return 'thread'
    case 'activity-event':
      return 'activity'
    case 'cascade-hop':
      return 'cascade'
    case 'bdi-snapshot':
      return 'BDI'
    case 'decision-log':
      return 'decision'
  }
}

function traceEventFilePath(event: KeeperTraceEvent): string | null {
  if (event.source === 'anchored-thread') return event.filePath ?? null
  if (event.source === 'activity-event') return event.filePath
  return null
}

function traceEventLine(event: KeeperTraceEvent): number | null {
  if (event.source === 'anchored-thread') {
    return event.line !== null && Number.isSafeInteger(event.line) && event.line >= 1
      ? event.line
      : null
  }
  if (event.source === 'activity-event') {
    return Number.isSafeInteger(event.line) && event.line >= 1
      ? event.line
      : null
  }
  return null
}

function traceEventSurface(event: KeeperTraceEvent): string | undefined {
  return event.source === 'activity-event' ? event.surface : undefined
}

function traceEventLabel(event: EditorKeeperTraceLineEvent): string {
  const count = event.count > 1 ? ` x${event.count}` : ''
  const rawSurface = event.surface?.trim()
  const surface = event.source === 'activity-event'
    && rawSurface
    && rawSurface.toLowerCase() !== 'activity'
    ? ` ${rawSurface}`
    : ''
  return `${traceSourceLabel(event.source)}${surface} ${event.keeperName}${count}`
}

function traceLineAriaLabel(line: number, events: ReadonlyArray<EditorKeeperTraceLineEvent>): string {
  return `Line ${line} keeper trace: ${events.map(traceEventLabel).join(', ')}`
}

function traceLineTitle(line: number, events: ReadonlyArray<EditorKeeperTraceLineEvent>): string {
  return [`L${line}`, ...events.map(traceEventLabel)].join('\n')
}

function traceLineKey(events: ReadonlyArray<EditorKeeperTraceLineEvent>): string {
  return events
    .map(event => [
      event.id ?? '',
      event.source,
      event.surface ?? '',
      event.keeperName,
      event.count,
      event.tsMs,
      event.goalId ?? '',
      event.taskId ?? '',
      event.prId ?? '',
      event.logId ?? '',
    ].join(':'))
    .join('|')
}

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
  readonly goalId?: string | null
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
    first.goalId ? `goal ${first.goalId}` : null,
    first.taskId ? `task ${first.taskId}` : null,
    `keeper ${first.keeperId}`,
    annotations.length > 1 ? `+${annotations.length - 1}` : null,
  ].filter((part): part is string => part !== null)
  return parts.join(' · ')
}

function annotationLineChipTitle(annotations: ReadonlyArray<EditorAnnotationLine>): string {
  return annotations.map(annotation => [
    annotation.kind,
    annotation.goalId ? `goal ${annotation.goalId}` : null,
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
    `${annotation.id}:${annotation.line}:${annotation.kind}:${annotation.keeperId}:${annotation.goalId ?? ''}:${annotation.taskId ?? ''}`,
  ).join('|')
}

// ── Language support (dynamic import) ─────────────────────────────

type LanguageModule = () => Promise<{ extension: Extension }>

interface LanguageEntry {
  readonly id: string
  readonly load: LanguageModule
}

interface OcamlStreamState {
  commentDepth: number
  stringQuote: '"' | null
}

const OCAML_KEYWORDS = new Set([
  'and',
  'as',
  'assert',
  'begin',
  'class',
  'constraint',
  'do',
  'done',
  'downto',
  'else',
  'end',
  'exception',
  'external',
  'for',
  'fun',
  'function',
  'functor',
  'if',
  'in',
  'include',
  'inherit',
  'initializer',
  'lazy',
  'let',
  'match',
  'method',
  'module',
  'mutable',
  'new',
  'nonrec',
  'object',
  'of',
  'open',
  'private',
  'rec',
  'sig',
  'struct',
  'then',
  'to',
  'try',
  'type',
  'val',
  'virtual',
  'when',
  'while',
  'with',
])

const OCAML_ATOMS = new Set(['false', 'true', 'None', 'Some', 'Ok', 'Error'])

const OCAML_BUILTINS = new Set([
  'bool',
  'char',
  'exn',
  'float',
  'int',
  'list',
  'option',
  'result',
  'string',
  'unit',
])

const ocamlStreamParser: StreamParser<OcamlStreamState> = {
  name: 'ocaml',
  startState: () => ({ commentDepth: 0, stringQuote: null }),
  copyState: state => ({ ...state }),
  languageData: {
    name: 'ocaml',
    commentTokens: { block: { open: '(*', close: '*)' } },
  },
  token(stream, state) {
    if (state.commentDepth > 0) return readOcamlComment(stream, state)
    if (state.stringQuote !== null) return readOcamlString(stream, state)
    if (stream.eatSpace()) return null

    if (stream.match('(*')) {
      state.commentDepth = 1
      return readOcamlComment(stream, state)
    }

    const ch = stream.next()
    if (ch === undefined) return null

    if (ch === '"') {
      state.stringQuote = '"'
      return readOcamlString(stream, state)
    }

    if (ch === '\'') {
      if (stream.match(/^\\?.'/)) return 'string'
      stream.eatWhile(/[A-Za-z0-9_']/)
      return 'typeName'
    }

    if (/[0-9]/.test(ch)) {
      stream.eatWhile(/[A-Za-z0-9_'.]/)
      return 'number'
    }

    if (/[A-Z]/.test(ch)) {
      stream.eatWhile(/[A-Za-z0-9_']/)
      const ident = stream.current()
      return OCAML_ATOMS.has(ident) ? 'atom' : 'typeName'
    }

    if (/[a-z_]/.test(ch)) {
      stream.eatWhile(/[A-Za-z0-9_']/)
      const ident = stream.current()
      if (OCAML_KEYWORDS.has(ident)) return 'keyword'
      if (OCAML_ATOMS.has(ident)) return 'atom'
      if (OCAML_BUILTINS.has(ident)) return 'standard variableName'
      return 'variableName'
    }

    if (/[-+*/=<>@^|&$%!?~:.;,#]/.test(ch)) {
      stream.eatWhile(/[-+*/=<>@^|&$%!?~:.;,#]/)
      return 'operator'
    }

    return null
  },
}

const ocamlLanguage = StreamLanguage.define(ocamlStreamParser)

// ── TOML StreamLanguage ──────────────────────────────

interface TomlStreamState {
  readonly inSection: boolean
}

const tomlStreamParser: StreamParser<TomlStreamState> = {
  name: 'toml',
  startState: () => ({ inSection: false }),
  copyState: state => ({ ...state }),
  languageData: {
    name: 'toml',
    commentTokens: { line: '#' },
  },
  token(stream, state) {
    if (stream.eatSpace()) return null

    if (stream.sol() && stream.peek() === '#') {
      stream.skipToEnd()
      return 'comment'
    }

    if (stream.sol() && stream.peek() === '[') {
      stream.skipToEnd()
      return 'heading'
    }

    if (stream.peek() === '=') {
      stream.next()
      return 'operator'
    }

    if (stream.peek() === '"' || stream.peek() === '\'') {
      const quote = stream.next()!
      let escaped = false
      while (!stream.eol()) {
        const ch = stream.next()!
        if (escaped) { escaped = false; continue }
        if (ch === '\\') { escaped = true; continue }
        if (ch === quote) break
      }
      return 'string'
    }

    if (/[0-9\-]/.test(stream.peek() ?? '') && stream.match(/^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/)) {
      return 'number'
    }

    if (stream.match(/^true\b/) || stream.match(/^false\b/)) {
      return 'atom'
    }

    if (stream.match(/^\d{4}-\d{2}-\d{2}/)) {
      stream.eatWhile(/[T :\d.Z]/)
      return 'number'
    }

    if (/[A-Za-z_]/.test(stream.peek() ?? '')) {
      stream.eatWhile(/[A-Za-z0-9_.\-]/)
      return state.inSection ? 'propertyName' : 'variableName'
    }

    stream.next()
    return null
  },
}

const tomlLanguage = StreamLanguage.define(tomlStreamParser)

// ── YAML StreamLanguage ──────────────────────────────

interface YamlStreamState {
  inKey: boolean
}

const YAML_KEYWORDS = new Set(['true', 'false', 'null', '~', 'yes', 'no', 'on', 'off'])

const yamlStreamParser: StreamParser<YamlStreamState> = {
  name: 'yaml',
  startState: () => ({ inKey: true }),
  copyState: state => ({ ...state }),
  languageData: {
    name: 'yaml',
    commentTokens: { line: '#' },
  },
  token(stream, state) {
    if (stream.eatSpace()) return null

    if (stream.peek() === '#') {
      stream.skipToEnd()
      return 'comment'
    }

    if (stream.sol() && (stream.match(/^---/) || stream.match(/^\.\.\./))) {
      stream.eatSpace()
      return 'operator'
    }

    if (stream.sol() && stream.peek() === '-') {
      stream.next()
      if (stream.eatSpace()) return 'operator'
    }

    if (stream.peek() === '"' || stream.peek() === '\'') {
      const quote = stream.next()!
      let escaped = false
      while (!stream.eol()) {
        const ch = stream.next()!
        if (escaped) { escaped = false; continue }
        if (ch === '\\') { escaped = true; continue }
        if (ch === quote) break
      }
      state.inKey = false
      return 'string'
    }

    if (stream.peek() === ':') {
      stream.next()
      if (stream.eatSpace()) {
        state.inKey = true
        return 'operator'
      }
      return null
    }

    if (/[0-9\-]/.test(stream.peek() ?? '') && stream.match(/^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/)) {
      state.inKey = false
      return 'number'
    }

    if (/[A-Za-z_]/.test(stream.peek() ?? '')) {
      stream.eatWhile(/[A-Za-z0-9_.\-]/)
      const word = stream.current()
      if (YAML_KEYWORDS.has(word)) {
        state.inKey = false
        return 'atom'
      }
      if (state.inKey) return 'propertyName'
      state.inKey = false
      return 'string'
    }

    if (stream.peek() === '[' || stream.peek() === ']' || stream.peek() === '{' || stream.peek() === '}' || stream.peek() === ',') {
      stream.next()
      return 'operator'
    }

    stream.next()
    state.inKey = false
    return null
  },
}

const yamlLanguage = StreamLanguage.define(yamlStreamParser)

function readOcamlComment(stream: StringStream, state: OcamlStreamState): string {
  while (!stream.eol()) {
    if (stream.match('(*')) {
      state.commentDepth += 1
      continue
    }
    if (stream.match('*)')) {
      state.commentDepth -= 1
      if (state.commentDepth <= 0) {
        state.commentDepth = 0
        break
      }
      continue
    }
    stream.next()
  }
  return 'comment'
}

function readOcamlString(stream: StringStream, state: OcamlStreamState): string {
  let escaped = false
  while (!stream.eol()) {
    const ch = stream.next()
    if (escaped) {
      escaped = false
    } else if (ch === '\\') {
      escaped = true
    } else if (ch === state.stringQuote) {
      state.stringQuote = null
      break
    }
  }
  return 'string'
}

const LANGUAGE_MAP: Readonly<Record<string, LanguageEntry>> = {
  '.ts': { id: 'typescript', load: () => import('@codemirror/lang-javascript').then(m => m.javascript({ typescript: true })) },
  '.tsx': { id: 'typescript', load: () => import('@codemirror/lang-javascript').then(m => m.javascript({ typescript: true, jsx: true })) },
  '.js': { id: 'javascript', load: () => import('@codemirror/lang-javascript').then(m => m.javascript()) },
  '.jsx': { id: 'javascript', load: () => import('@codemirror/lang-javascript').then(m => m.javascript({ jsx: true })) },
  '.py': { id: 'python', load: () => import('@codemirror/lang-python').then(m => m.python()) },
  '.html': { id: 'html', load: () => import('@codemirror/lang-html').then(m => m.html()) },
  '.css': { id: 'css', load: () => import('@codemirror/lang-css').then(m => m.css()) },
  '.json': { id: 'json', load: () => import('@codemirror/lang-json').then(m => m.json()) },
  '.md': { id: 'markdown', load: () => import('@codemirror/lang-markdown').then(m => m.markdown()) },
  '.ocaml': { id: 'ocaml', load: () => Promise.resolve(ocamlLanguage) },
  '.ml': { id: 'ocaml', load: () => Promise.resolve(ocamlLanguage) },
  '.mli': { id: 'ocaml', load: () => Promise.resolve(ocamlLanguage) },
  '.rs': { id: 'rust', load: () => import('@codemirror/lang-rust').then(m => m.rust()) },
  '.go': { id: 'go', load: () => import('@codemirror/lang-go').then(m => m.go()) },
  '.toml': { id: 'toml', load: () => Promise.resolve(tomlLanguage) },
  '.yaml': { id: 'yaml', load: () => Promise.resolve(yamlLanguage) },
  '.yml': { id: 'yaml', load: () => Promise.resolve(yamlLanguage) },
}

export function languageIdForFilePath(filePath: string): string | null {
  const ext = filePath.slice(filePath.lastIndexOf('.'))
  return LANGUAGE_MAP[ext]?.id ?? null
}

export async function languageExt(filePath: string): Promise<Extension> {
  const ext = filePath.slice(filePath.lastIndexOf('.'))
  const loader = LANGUAGE_MAP[ext]?.load
  if (!loader) return []
  try {
    return await loader()
  } catch {
    return []
  }
}

// ── Line number gutter ────────────────────────────────────────────

export function lineNumberExt(): Extension {
  return lineNumbers()
}

// ── Blame mode extensions bundle ──────────────────────────────────

export function blameExtensions(): Extension[] {
  return [blameGutterExt()]
}

export { setOwnership }
