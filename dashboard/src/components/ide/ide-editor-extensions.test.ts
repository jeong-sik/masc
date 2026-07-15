import { fireEvent } from '@testing-library/preact'
import { describe, it, expect, vi } from 'vitest'
import { EditorState, type Extension } from '@codemirror/state'
import { EditorView } from '@codemirror/view'
import {
  readOnlyExt,
  themeExt,
  languageExt,
  languageIdForFilePath,
  lineNumberExt,
  syntaxHighlightExt,
  blameExtensions,
  keeperTraceLineGutterExt,
  keeperTraceLineChipExt,
  keeperTraceLinesForFile,
  pushOwnership,
  pushKeeperTraceLines,
  setOwnership,
} from './ide-editor-extensions'
import type { LineOwnership } from './keeper-line-ownership-store'
import type { KeeperTraceEvent } from './keeper-trace-store'

function createTestView(extensions: Extension[], doc = 'hello\nworld\n') {
  const container = document.createElement('div')
  document.body.appendChild(container)
  const state = EditorState.create({ doc, extensions })
  const view = new EditorView({ state, parent: container })
  return { view, container }
}

describe('readOnlyExt', () => {
  it('blocks all changes', () => {
    const { view } = createTestView([readOnlyExt()])
    const len = view.state.doc.length
    view.dispatch({ changes: { from: 0, to: len, insert: 'changed' } })
    expect(view.state.doc.toString()).toBe('hello\nworld\n')
    view.destroy()
  })
})

describe('themeExt', () => {
  it('returns a non-empty extension', () => {
    const ext = themeExt()
    expect(ext).toBeDefined()
    const { view, container } = createTestView([ext])
    expect(view.dom).toBeInstanceOf(HTMLElement)
    view.destroy()
    container.remove()
  })
})

describe('lineNumberExt + syntaxHighlightExt', () => {
  it('renders line numbers and syntax highlight spans', async () => {
    const lang = await languageExt('index.ts')
    const { view, container } = createTestView([
      themeExt(),
      lineNumberExt(),
      syntaxHighlightExt(),
      lang,
    ], 'const answer = 42\n')

    expect(container.querySelector('.cm-lineNumbers')).not.toBeNull()
    expect(container.querySelectorAll('.cm-lineNumbers .cm-gutterElement').length).toBeGreaterThan(0)
    expect(container.querySelector('.cm-line span')).not.toBeNull()

    view.destroy()
    container.remove()
  })
})

describe('languageExt', () => {
  it('returns empty extension for unknown file types', async () => {
    const ext = await languageExt('readme.xyz')
    expect(ext).toEqual([])
  })

  it('returns a language extension for .ts files', async () => {
    const ext = await languageExt('index.ts')
    expect(Array.isArray(ext) ? ext.length : ext).toBeDefined()
  })

  it('returns a language extension for .py files', async () => {
    const ext = await languageExt('main.py')
    expect(ext).toBeDefined()
  })

  it('returns a language extension for .json files', async () => {
    const ext = await languageExt('package.json')
    expect(ext).toBeDefined()
  })

  it('maps OCaml source and interface files to the OCaml language', async () => {
    expect(languageIdForFilePath('lib/server.ml')).toBe('ocaml')
    expect(languageIdForFilePath('lib/server.mli')).toBe('ocaml')
    expect(languageIdForFilePath('scratch.ocaml')).toBe('ocaml')

    const lang = await languageExt('lib/server.ml')
    const { view, container } = createTestView([
      themeExt(),
      lineNumberExt(),
      syntaxHighlightExt(),
      lang,
    ], 'module type S = sig\n  val run : unit -> int\nend\n')

    expect(container.querySelector('.cm-line span')).not.toBeNull()
    expect(view.state.languageDataAt('name', 0)).toContain('ocaml')

    view.destroy()
    container.remove()
  })
})

describe('blameExtensions', () => {
  it('returns an array of extensions', () => {
    const exts = blameExtensions()
    expect(Array.isArray(exts)).toBe(true)
    expect(exts.length).toBeGreaterThan(0)
  })
})

describe('pushOwnership + setOwnership effect', () => {
  it('dispatches ownership data without error', () => {
    const exts = [readOnlyExt(), ...blameExtensions()]
    const { view, container } = createTestView(exts)

    const ownership = new Map([
      [1, { keeper_id: 'alpha', hue_index: 1, last_edit_kind: 'edit', last_edit_ms: Date.now() }],
      [2, { keeper_id: 'beta', hue_index: 2, last_edit_kind: 'create', last_edit_ms: Date.now() }],
    ]) as ReadonlyMap<number, LineOwnership>

    expect(() => pushOwnership(view, ownership)).not.toThrow()
    expect(view.state.doc.toString()).toBe('hello\nworld\n')

    view.destroy()
    container.remove()
  })

  it('renders keeper sigil and name markers in the blame gutter', () => {
    const exts = [themeExt(), readOnlyExt(), ...blameExtensions()]
    const { view, container } = createTestView(exts)

    const ownership = new Map([
      [1, { keeper_id: 'alpha-keeper', hue_index: 3, last_edit_kind: 'edit', last_edit_ms: 1000 }],
    ]) as ReadonlyMap<number, LineOwnership>

    pushOwnership(view, ownership)

    expect(container.querySelector('.cm-blame-marker')).not.toBeNull()
    expect(container.querySelector('.cm-blame-sigil')?.textContent).toBe('AK')
    expect(container.querySelector('.cm-blame-name')?.textContent).toBe('alpha-keeper')

    view.destroy()
    container.remove()
  })

  it('setOwnership effect carries the ownership map', () => {
    const ownership = new Map([
      [1, { keeper_id: 'gamma', hue_index: 2, last_edit_kind: 'edit', last_edit_ms: 1000 }],
    ]) as ReadonlyMap<number, LineOwnership>
    const effect = (setOwnership as any).of(ownership)
    expect((effect as any).is(setOwnership)).toBe(true)
    expect((effect as any).value).toBe(ownership)
    expect((effect as any).value.get(1)?.keeper_id).toBe('gamma')
  })
})

describe('keeperTraceLinesForFile + keeper trace gutter', () => {
  it('keeps only line-anchored trace events for the current file', () => {
    const events: KeeperTraceEvent[] = [
      {
        id: 'thread-1',
        tsMs: 2000,
        keeperName: 'scholar',
        count: 1,
        source: 'anchored-thread',
        threadId: 'thread-1',
        filePath: 'runtime.ts',
        line: 2,
      },
      {
        id: 'thread-other',
        tsMs: 3000,
        keeperName: 'moth',
        count: 1,
        source: 'anchored-thread',
        threadId: 'thread-other',
        filePath: 'other.ts',
        line: 2,
      },
      {
        id: 'thread-unscoped',
        tsMs: 4000,
        keeperName: 'luna',
        count: 1,
        source: 'anchored-thread',
        threadId: 'thread-unscoped',
        line: 3,
      },
      {
        id: 'activity-1',
        tsMs: 5000,
        keeperName: 'sangsu',
        count: 1,
        source: 'activity-event',
        eventId: 'evt-1',
        filePath: 'runtime.ts',
        line: 2,
        surface: 'Task',
      },
      {
        id: 'decision-1',
        tsMs: 6000,
        keeperName: 'scholar',
        count: 1,
        source: 'decision-log',
        decisionId: 'decision:scholar:6000:tool_use',
        semanticOutcome: 'ok',
        decisionChoice: 'use_shell',
        decisionReason: 'verify touched test target',
        filePath: 'runtime.ts',
        line: 2,
        taskId: 'task-decision',
      },
    ]

    const traceLines = keeperTraceLinesForFile('runtime.ts', events)
    expect(traceLines).toHaveLength(1)
    expect(traceLines[0]?.line).toBe(2)
    expect(traceLines[0]?.events).toHaveLength(3)
    expect(traceLines[0]?.events[0]).toMatchObject({
      id: 'decision-1',
      source: 'decision-log',
      keeperName: 'scholar',
      count: 1,
      tsMs: 6000,
      filePath: 'runtime.ts',
      line: 2,
      taskId: 'task-decision',
      decisionChoice: 'use_shell',
      decisionReason: 'verify touched test target',
    })
    expect(traceLines[0]?.events[1]).toMatchObject({
      id: 'activity-1',
      source: 'activity-event',
      keeperName: 'sangsu',
      count: 1,
      tsMs: 5000,
      filePath: 'runtime.ts',
      line: 2,
      eventId: 'evt-1',
      surface: 'Task',
    })
    expect(traceLines[0]?.events[2]).toMatchObject({
      id: 'thread-1',
      source: 'anchored-thread',
      keeperName: 'scholar',
      count: 1,
      tsMs: 2000,
      filePath: 'runtime.ts',
      line: 2,
      threadId: 'thread-1',
    })
  })

  it('renders file-scoped trace dots in the trace gutter', () => {
    const exts = [themeExt(), readOnlyExt(), keeperTraceLineGutterExt()]
    const { view, container } = createTestView(exts, 'one\ntwo\nthree\n')

    pushKeeperTraceLines(view, [
      {
        line: 2,
        events: [
          { source: 'anchored-thread', keeperName: 'scholar', count: 2, tsMs: 2000 },
          { source: 'activity-event', keeperName: 'sangsu', count: 1, tsMs: 1500, surface: 'PR' },
          { source: 'anchored-thread', keeperName: 'moth', count: 1, tsMs: 1000 },
        ],
      },
    ])

    const gutter = container.querySelector('.cm-trace-gutter')
    expect(gutter).not.toBeNull()
    const dots = gutter?.querySelectorAll('.cm-trace-dot')
    expect(dots?.length).toBe(3)
    expect(dots?.[0]?.getAttribute('data-source')).toBe('anchored-thread')
    expect(dots?.[0]?.getAttribute('aria-label')).toBe('thread scholar x2')
    expect(dots?.[1]?.getAttribute('data-source')).toBe('activity-event')
    expect(dots?.[1]?.getAttribute('aria-label')).toBe('activity PR sangsu')
    const stack = gutter?.querySelector<HTMLButtonElement>('button.cm-trace-stack')
    expect(stack?.getAttribute('aria-label')).toContain('Line 2 keeper trace')
    expect(stack?.dataset.line).toBe('2')

    view.destroy()
    container.remove()
  })

  it('selects the top trace event when a trace gutter stack is clicked', () => {
    const onSelect = vi.fn()
    const traceLines = [
      {
        line: 2,
        events: [
          {
            id: 'activity-1',
            source: 'activity-event' as const,
            keeperName: 'sangsu',
            count: 1,
            tsMs: 3000,
            surface: 'PR',
            eventId: 'evt-1',
          },
          {
            id: 'thread-1',
            source: 'anchored-thread' as const,
            keeperName: 'scholar',
            count: 1,
            tsMs: 2000,
            threadId: 'thread-1',
          },
        ],
      },
    ]
    const exts = [
      themeExt(),
      readOnlyExt(),
      keeperTraceLineGutterExt({
        getTraceLines: () => traceLines,
        onTraceLineSelect: onSelect,
      }),
    ]
    const { view, container } = createTestView(exts, 'one\ntwo\nthree\n')

    pushKeeperTraceLines(view, traceLines)

    const stack = container.querySelector<HTMLButtonElement>('button.cm-trace-stack')
    expect(stack).not.toBeNull()
    fireEvent.click(stack!)
    expect(onSelect).toHaveBeenCalledTimes(1)
    expect(onSelect).toHaveBeenCalledWith(traceLines[0]!.events[0], 2)

    view.destroy()
    container.remove()
  })

  it('renders inline trace context chips with operational route metadata', () => {
    const exts = [
      themeExt(),
      readOnlyExt(),
      keeperTraceLineGutterExt(),
      keeperTraceLineChipExt(),
    ]
    const { view, container } = createTestView(exts, 'one\ntwo\nthree\n')

    pushKeeperTraceLines(view, [
      {
        line: 2,
        events: [
          {
            id: 'activity-1',
            source: 'activity-event',
            keeperName: 'sangsu',
            count: 1,
            tsMs: 3000,
            surface: 'PR',
            eventId: 'evt-1',
            taskId: 'task-runtime',
            boardPostId: 'post-runtime',
            commentId: 'comment-runtime',
            prId: '15035',
            gitRef: 'refs/heads/review-response',
            logId: 'turn-2',
            sessionId: 'sess-runtime',
            operationId: 'op-runtime',
            workerRunId: 'worker-runtime',
          },
          {
            id: 'thread-1',
            source: 'anchored-thread',
            keeperName: 'scholar',
            count: 1,
            tsMs: 2000,
            threadId: 'thread-1',
          },
        ],
      },
    ])

    const expectedText = 'Trace · PR · event evt-1 · task task-runtime · board post-runtime · comment comment-runtime · pr #15035 · git review-response · log turn-2 · session sess-runtime · op op-runtime · run worker-runtime · keeper sangsu · +1'
    const chip = container.querySelector('.cm-masc-trace-chip')
    expect(chip?.textContent).toBe(expectedText)
    expect(chip?.getAttribute('aria-label')).toBe(`Line 2 keeper trace context: ${expectedText}`)
    expect((chip as HTMLElement).style.getPropertyValue('--cm-trace-chip-color'))
      .toBe('var(--color-status-info)')

    view.destroy()
    container.remove()
  })
})
