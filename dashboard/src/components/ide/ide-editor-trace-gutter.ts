import { Decoration, EditorView, GutterMarker, WidgetType, gutter, type DecorationSet, type ViewUpdate } from '@codemirror/view'
import { Extension, RangeSetBuilder, StateField, StateEffect, type Text } from '@codemirror/state'
import type { KeeperTraceContextFields, KeeperTraceEvent, KeeperTraceSource } from './keeper-trace-store'
import { isPositiveSafeInteger } from '../common/normalize'

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
  readonly taskId?: string
  readonly boardPostId?: string
  readonly commentId?: string
  readonly prId?: string
  readonly gitRef?: string
  readonly logId?: string
  readonly sessionId?: string
  readonly operationId?: string
  readonly workerRunId?: string
  readonly decisionChoice?: string | null
  readonly decisionReason?: string | null
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

class TraceLineChip extends WidgetType {
  constructor(private readonly traceLine: EditorKeeperTraceLine) {
    super()
  }

  toDOM(): HTMLElement {
    const el = document.createElement('span')
    const first = this.traceLine.events[0]
    el.className = 'cm-masc-trace-chip'
    el.textContent = traceLineChipText(this.traceLine)
    el.title = traceLineChipTitle(this.traceLine)
    el.setAttribute('aria-label', traceLineChipAriaLabel(this.traceLine))
    if (first) el.style.setProperty('--cm-trace-chip-color', traceSourceColor(first.source))
    return el
  }

  eq(other: TraceLineChip): boolean {
    return this.traceLine.line === other.traceLine.line
      && traceLineKey(this.traceLine.events) === traceLineKey(other.traceLine.events)
  }
}

const keeperTraceLineChipField = StateField.define<DecorationSet>({
  create() {
    return Decoration.none
  },
  update(value, tr) {
    const mapped = value.map(tr.changes)
    for (const effect of tr.effects) {
      if (!effect.is(setKeeperTraceLines)) continue
      return buildTraceLineChipDecorations(tr.state.doc, effect.value)
    }
    return mapped
  },
  provide: field => EditorView.decorations.from(field),
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

export function keeperTraceLineChipExt(): Extension {
  return keeperTraceLineChipField
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
  const line = isPositiveSafeInteger(lineFromMarker) ? lineFromMarker : blockLine
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
    const context = traceEventContextFields(event)
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
      taskId: context.taskId,
      boardPostId: context.boardPostId,
      commentId: context.commentId,
      prId: context.prId,
      gitRef: context.gitRef,
      logId: context.logId,
      sessionId: context.sessionId,
      operationId: context.operationId,
      workerRunId: context.workerRunId,
      decisionChoice: event.source === 'decision-log' ? event.decisionChoice : undefined,
      decisionReason: event.source === 'decision-log' ? event.decisionReason : undefined,
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

function buildTraceLineChipDecorations(
  doc: Text,
  traceLines: ReadonlyArray<EditorKeeperTraceLine>,
): DecorationSet {
  const builder = new RangeSetBuilder<Decoration>()
  const sorted = [...traceLines]
    .filter(traceLine =>
      traceLine.line >= 1
      && traceLine.line <= doc.lines
      && traceLine.events.length > 0,
    )
    .sort((left, right) => left.line - right.line)

  for (const traceLine of sorted) {
    const line = doc.line(traceLine.line)
    builder.add(
      line.to,
      line.to,
      Decoration.widget({
        widget: new TraceLineChip(traceLine),
        side: 3,
      }),
    )
  }

  return builder.finish()
}

function traceSourceColor(source: KeeperTraceSource): string {
  switch (source) {
    case 'anchored-thread':
      return 'var(--color-status-info)'
    case 'activity-event':
      return 'var(--color-status-info)'
    case 'runtime-hop':
      return 'var(--color-accent-fg)'
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
    case 'runtime-hop':
      return 'runtime'
    case 'decision-log':
      return 'decision'
  }
}

function traceEventFilePath(event: KeeperTraceEvent): string | null {
  if (event.source === 'anchored-thread') return event.filePath ?? null
  if (event.source === 'activity-event') return event.filePath
  if (
    event.source === 'runtime-hop'
    || event.source === 'decision-log'
  ) return event.filePath ?? null
  return null
}

function traceEventLine(event: KeeperTraceEvent): number | null {
  if (event.source === 'anchored-thread') {
    return isPositiveSafeInteger(event.line) ? event.line : null
  }
  if (event.source === 'activity-event') {
    return isPositiveSafeInteger(event.line) ? event.line : null
  }
  if (
    event.source === 'runtime-hop'
    || event.source === 'decision-log'
  ) {
    const line = event.line
    return isPositiveSafeInteger(line)
      ? line
      : null
  }
  return null
}

function traceEventSurface(event: KeeperTraceEvent): string | undefined {
  return event.source === 'activity-event' ? event.surface : undefined
}

function traceEventContextFields(event: KeeperTraceEvent): KeeperTraceContextFields {
  if (
    event.source === 'activity-event'
    || event.source === 'runtime-hop'
    || event.source === 'decision-log'
  ) return event
  return {}
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

function traceLineChipText(traceLine: EditorKeeperTraceLine): string {
  const first = traceLine.events[0]
  if (!first) return 'Trace'
  const parts = [
    'Trace',
    traceLineChipSurface(first),
    ...traceEventContextParts(first),
    `keeper ${first.keeperName}`,
    traceLine.events.length > 1 ? `+${traceLine.events.length - 1}` : null,
  ].filter((part): part is string => part !== null)
  return parts.join(' · ')
}

function traceLineChipTitle(traceLine: EditorKeeperTraceLine): string {
  return traceLine.events
    .map(event => [
      traceLineChipSurface(event),
      traceLineChipLabel(event),
      ...traceEventContextParts(event),
      `keeper ${event.keeperName}`,
    ].filter((part): part is string => part !== null).join(' · '))
    .join('\n')
}

function traceLineChipAriaLabel(traceLine: EditorKeeperTraceLine): string {
  return `Line ${traceLine.line} keeper trace context: ${traceLineChipText(traceLine)}`
}

function traceLineChipSurface(event: EditorKeeperTraceLineEvent): string {
  if (event.source === 'activity-event') return event.surface?.trim() || 'Activity'
  if (event.source === 'anchored-thread') return 'Thread'
  if (event.source === 'runtime-hop') return 'Runtime'
  return 'Decision'
}

function traceLineChipLabel(event: EditorKeeperTraceLineEvent): string {
  if (event.source === 'activity-event') {
    const surface = traceLineChipSurface(event)
    return event.eventId ? `${surface} activity ${event.eventId}` : surface
  }
  if (event.source === 'anchored-thread') {
    return event.threadId ? `thread ${event.threadId}` : 'thread'
  }
  if (event.source === 'decision-log') {
    const choice = event.decisionChoice?.trim()
    const reason = event.decisionReason?.trim()
    if (choice && reason) return `${choice}: ${reason}`
    if (choice) return choice
    if (reason) return reason
  }
  return traceLineChipSurface(event)
}

function traceEventContextParts(event: EditorKeeperTraceLineEvent): ReadonlyArray<string> {
  return [
    event.eventId ? `event ${event.eventId}` : null,
    event.threadId ? `thread ${event.threadId}` : null,
    event.taskId ? `task ${event.taskId}` : null,
    event.boardPostId ? `board ${event.boardPostId}` : null,
    event.commentId ? `comment ${event.commentId}` : null,
    event.prId ? `pr #${event.prId}` : null,
    event.gitRef ? `git ${shortGitRef(event.gitRef)}` : null,
    event.logId ? `log ${event.logId}` : null,
    event.sessionId ? `session ${event.sessionId}` : null,
    event.operationId ? `op ${event.operationId}` : null,
    event.workerRunId ? `run ${event.workerRunId}` : null,
  ].filter((part): part is string => part !== null)
}

function shortGitRef(ref: string): string {
  return ref.replace(/^refs\/heads\//, '').replace(/^refs\/tags\//, '')
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
      event.taskId ?? '',
      event.boardPostId ?? '',
      event.commentId ?? '',
      event.prId ?? '',
      event.gitRef ?? '',
      event.logId ?? '',
      event.sessionId ?? '',
      event.operationId ?? '',
      event.workerRunId ?? '',
    ].join(':'))
    .join('|')
}
