// Pure TS unit tests for InlineSuggestion. No DOM.
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import {
  createInlineSuggestionManager,
  createSuggestionController,
  type InlineSuggestion,
  type InlineSuggestionInput,
  type SuggestionKeyEvent,
} from './inline-suggestion'

function makeKey(
  key: string,
  opts?: Partial<SuggestionKeyEvent>,
): SuggestionKeyEvent & { _prevented: boolean } {
  let prevented = false
  return {
    key,
    metaKey: opts?.metaKey,
    ctrlKey: opts?.ctrlKey,
    shiftKey: opts?.shiftKey,
    altKey: opts?.altKey,
    preventDefault() {
      prevented = true
    },
    get _prevented() {
      return prevented
    },
  } as SuggestionKeyEvent & { _prevented: boolean }
}

function input(
  patch: Partial<InlineSuggestionInput> = {},
): InlineSuggestionInput {
  return {
    agentId: patch.agentId ?? 'a1',
    agentName: patch.agentName ?? 'Alice',
    agentColorSlot: patch.agentColorSlot ?? 1,
    range: patch.range ?? { file: 'src/x.ts', fromLine: 10, toLine: 12 },
    before: patch.before ?? ['old'],
    after: patch.after ?? ['new'],
    confidence: patch.confidence ?? 0.5,
    rationale: patch.rationale,
  }
}

beforeEach(() => {
  vi.useFakeTimers()
})
afterEach(() => {
  vi.useRealTimers()
})

describe('createInlineSuggestionManager — propose / queries', () => {
  it('propose returns id formatted by IdGenerator', () => {
    const m = createInlineSuggestionManager()
    const id = m.propose(input())
    expect(id).toMatch(/^inline-suggestion-/)
    expect(m.getAll().length).toBe(1)
  })

  it('inFile filters by file', () => {
    const m = createInlineSuggestionManager()
    m.propose(input({ range: { file: 'a.ts', fromLine: 1, toLine: 2 } }))
    m.propose(input({ range: { file: 'b.ts', fromLine: 1, toLine: 2 } }))
    expect(m.inFile('a.ts').length).toBe(1)
    expect(m.inFile('b.ts').length).toBe(1)
  })

  it('inRange returns overlapping suggestions', () => {
    const m = createInlineSuggestionManager()
    m.propose(input({ range: { file: 'f', fromLine: 10, toLine: 16 } }))
    m.propose(input({ range: { file: 'f', fromLine: 13, toLine: 21 } }))
    m.propose(input({ range: { file: 'f', fromLine: 50, toLine: 52 } }))
    expect(m.inRange('f', 12, 17).length).toBe(2)
    expect(m.inRange('f', 50, 51).length).toBe(1)
  })

  it('topAtLine returns highest-confidence overlap', () => {
    const m = createInlineSuggestionManager()
    m.propose(input({ confidence: 0.4, range: { file: 'f', fromLine: 10, toLine: 16 } }))
    m.propose(input({ confidence: 0.9, range: { file: 'f', fromLine: 12, toLine: 14 } }))
    m.propose(input({ confidence: 0.6, range: { file: 'f', fromLine: 13, toLine: 15 } }))
    const top = m.topAtLine('f', 13)
    expect(top).toBeDefined()
    expect(top!.confidence).toBe(0.9)
  })

  it('topAtLine undefined when no overlap', () => {
    const m = createInlineSuggestionManager()
    m.propose(input({ range: { file: 'f', fromLine: 10, toLine: 12 } }))
    expect(m.topAtLine('f', 50)).toBeUndefined()
    expect(m.topAtLine('other', 11)).toBeUndefined()
  })
})

describe('createInlineSuggestionManager — accept / reject lifecycle', () => {
  it('accept fires onAccept and removes', () => {
    const accepts: InlineSuggestion[] = []
    const m = createInlineSuggestionManager({
      onAccept: (s) => accepts.push(s),
    })
    const id = m.propose(input())
    m.accept(id)
    expect(accepts.length).toBe(1)
    expect(m.getAll().length).toBe(0)
  })

  it('reject fires onReject and removes', () => {
    const rejects: InlineSuggestion[] = []
    const m = createInlineSuggestionManager({
      onReject: (s) => rejects.push(s),
    })
    const id = m.propose(input())
    m.reject(id)
    expect(rejects.length).toBe(1)
    expect(m.getAll().length).toBe(0)
  })

  it('retract removes silently — no onReject fire', () => {
    const rejects: InlineSuggestion[] = []
    const m = createInlineSuggestionManager({
      onReject: (s) => rejects.push(s),
    })
    const id = m.propose(input())
    m.retract(id)
    expect(rejects.length).toBe(0)
    expect(m.getAll().length).toBe(0)
  })

  it('accept on overlapping range auto-rejects others in same file', () => {
    const rejects: InlineSuggestion[] = []
    const m = createInlineSuggestionManager({
      onReject: (s) => rejects.push(s),
    })
    const winnerId = m.propose(
      input({ range: { file: 'f', fromLine: 10, toLine: 15 } }),
    )
    m.propose(input({ range: { file: 'f', fromLine: 13, toLine: 18 } }))
    m.propose(input({ range: { file: 'f', fromLine: 50, toLine: 52 } })) // disjoint
    m.accept(winnerId)
    expect(rejects.length).toBe(1)
    // Disjoint suggestion still alive.
    expect(m.getAll().length).toBe(1)
    expect(m.getAll()[0]!.range.fromLine).toBe(50)
  })
})

describe('createInlineSuggestionManager — TTL', () => {
  it('TTL auto-rejects after ttlMs', () => {
    const rejects: InlineSuggestion[] = []
    const m = createInlineSuggestionManager({
      ttlMs: 100,
      onReject: (s) => rejects.push(s),
    })
    m.propose(input())
    expect(rejects.length).toBe(0)
    vi.advanceTimersByTime(99)
    expect(rejects.length).toBe(0)
    vi.advanceTimersByTime(2)
    expect(rejects.length).toBe(1)
    expect(m.getAll().length).toBe(0)
  })

  it('ttlMs:0 disables auto-rejection', () => {
    const rejects: InlineSuggestion[] = []
    const m = createInlineSuggestionManager({
      ttlMs: 0,
      onReject: (s) => rejects.push(s),
    })
    m.propose(input())
    vi.advanceTimersByTime(60_000)
    expect(rejects.length).toBe(0)
    expect(m.getAll().length).toBe(1)
  })

  it('accept clears TTL — no double reject after', () => {
    const rejects: InlineSuggestion[] = []
    const m = createInlineSuggestionManager({
      ttlMs: 100,
      onReject: (s) => rejects.push(s),
    })
    const id = m.propose(input())
    m.accept(id)
    vi.advanceTimersByTime(200)
    expect(rejects.length).toBe(0)
  })
})

describe('createInlineSuggestionManager — subscribeFile', () => {
  it('subscribeFile fires on propose / accept / reject within file', () => {
    const m = createInlineSuggestionManager()
    let fires = 0
    m.subscribeFile('f', () => {
      fires += 1
    })
    const id = m.propose(input({ range: { file: 'f', fromLine: 1, toLine: 2 } }))
    expect(fires).toBe(1)
    m.accept(id)
    expect(fires).toBe(2)
  })

  it('subscribeFile isolates by file', () => {
    const m = createInlineSuggestionManager()
    let aFires = 0
    let bFires = 0
    m.subscribeFile('a.ts', () => {
      aFires += 1
    })
    m.subscribeFile('b.ts', () => {
      bFires += 1
    })
    m.propose(input({ range: { file: 'a.ts', fromLine: 1, toLine: 2 } }))
    expect(aFires).toBe(1)
    expect(bFires).toBe(0)
  })
})

describe('createSuggestionController — ARIA props', () => {
  it('aria-label includes agent + line range + keyboard hint', () => {
    const m = createInlineSuggestionManager()
    const id = m.propose(
      input({
        agentName: 'Bob',
        range: { file: 'f', fromLine: 42, toLine: 46 },
      }),
    )
    const c = createSuggestionController(m, id)
    const root = c.getRootProps()
    expect(root['aria-label']).toBe(
      'Suggestion from Bob: replace lines 42-45. Press Tab to accept or Escape to reject.',
    )
    expect(root['aria-keyshortcuts']).toBe('Tab Escape')
    expect(root['data-state']).toBe('suggested')
    expect(root.role).toBe('region')
    expect(root.tabIndex).toBe(0)
  })

  it('data-agent-color matches --k-N', () => {
    const m = createInlineSuggestionManager()
    const id = m.propose(input({ agentColorSlot: 7 }))
    const c = createSuggestionController(m, id)
    expect(c.getRootProps()['data-agent-color']).toBe('--k-7')
  })

  it('Tab keydown accepts; Escape rejects', () => {
    const accepts: InlineSuggestion[] = []
    const rejects: InlineSuggestion[] = []
    const m = createInlineSuggestionManager({
      onAccept: (s) => accepts.push(s),
      onReject: (s) => rejects.push(s),
    })
    const id1 = m.propose(input())
    const c1 = createSuggestionController(m, id1)
    c1.getRootProps().onKeyDown(makeKey('Tab'))
    expect(accepts.length).toBe(1)

    const id2 = m.propose(input())
    const c2 = createSuggestionController(m, id2)
    c2.getRootProps().onKeyDown(makeKey('Escape'))
    expect(rejects.length).toBe(1)
  })

  it('Shift+Tab does NOT accept (reserved for outer focus reverse)', () => {
    const accepts: InlineSuggestion[] = []
    const m = createInlineSuggestionManager({
      onAccept: (s) => accepts.push(s),
    })
    const id = m.propose(input())
    const c = createSuggestionController(m, id)
    c.getRootProps().onKeyDown(makeKey('Tab', { shiftKey: true }))
    expect(accepts.length).toBe(0)
  })

  it('Mod+Tab does NOT accept', () => {
    const accepts: InlineSuggestion[] = []
    const m = createInlineSuggestionManager({
      onAccept: (s) => accepts.push(s),
    })
    const id = m.propose(input())
    const c = createSuggestionController(m, id)
    c.getRootProps().onKeyDown(makeKey('Tab', { metaKey: true }))
    expect(accepts.length).toBe(0)
  })

  it('button props expose correct labels and shortcuts', () => {
    const m = createInlineSuggestionManager()
    const id = m.propose(input({ agentName: 'Carol' }))
    const c = createSuggestionController(m, id)
    const accept = c.getAcceptButtonProps()
    const reject = c.getRejectButtonProps()
    expect(accept['aria-label']).toBe('Accept suggestion from Carol')
    expect(accept['aria-keyshortcuts']).toBe('Tab')
    expect(reject['aria-label']).toBe('Reject suggestion from Carol')
    expect(reject['aria-keyshortcuts']).toBe('Escape')
  })

  it('controller throws when suggestion id missing', () => {
    const m = createInlineSuggestionManager()
    expect(() => createSuggestionController(m, 'nonexistent')).toThrow()
  })
})

describe('createInlineSuggestionManager — single-line label edge case', () => {
  it('single-line range labels as "line N" (singular)', () => {
    const m = createInlineSuggestionManager()
    const id = m.propose(
      input({
        agentName: 'Dave',
        range: { file: 'f', fromLine: 7, toLine: 8 }, // toLine exclusive → 1 line
      }),
    )
    const c = createSuggestionController(m, id)
    expect(c.getRootProps()['aria-label']).toBe(
      'Suggestion from Dave: replace line 7. Press Tab to accept or Escape to reject.',
    )
  })
})
