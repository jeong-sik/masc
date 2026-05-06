import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import {
  OverlayKeeperTrace,
  TRACE_CHIP_CAP,
  bucketTraceEvents,
} from './overlay-keeper-trace'
import {
  clearTraces,
  keeperTraceState,
  pushTrace,
} from './keeper-trace-store'

const mountedContainers: HTMLElement[] = []

function createContainer(): HTMLElement {
  const container = document.createElement('div')
  mountedContainers.push(container)
  return container
}

function pushAnchored(id: string, keeperName: string, line: number | null, tsMs: number, threadId = 'th'): void {
  pushTrace({
    id,
    tsMs,
    keeperName,
    source: 'anchored-thread',
    threadId,
    line,
  })
}

function pushBdi(id: string, keeperName: string, tsMs: number, intention: string | null = 'inspect'): void {
  pushTrace({
    id,
    tsMs,
    keeperName,
    source: 'bdi-snapshot',
    intention,
  })
}

function pushDecision(id: string, keeperName: string, tsMs: number): void {
  pushTrace({
    id,
    tsMs,
    keeperName,
    source: 'decision-log',
    decisionId: `dec-${id}`,
    semanticOutcome: 'success',
  })
}

beforeEach(() => {
  clearTraces()
})

afterEach(() => {
  for (const container of mountedContainers.splice(0)) {
    render(null, container)
  }
  clearTraces()
})

describe('bucketTraceEvents — RFC-0028 §5 grouping', () => {
  it('groups events by (keeperName, line)', () => {
    pushAnchored('a', 'scholar', 12, 1000)
    pushAnchored('b', 'scholar', 12, 1100) // same keeper, same line -> same bucket
    pushAnchored('c', 'scholar', 99, 1200) // same keeper, different line -> separate
    pushAnchored('d', 'moth', 12, 1300) // different keeper -> separate

    const buckets = bucketTraceEvents(keeperTraceState.value.events)
    const keys = buckets.map(b => `${b.keeperName}@${b.line}`).sort()
    expect(keys).toEqual(['moth@12', 'scholar@12', 'scholar@99'])
  })

  it('non-anchored sources fall into the keeper-level no-line bucket', () => {
    pushBdi('a', 'scholar', 1000)
    pushDecision('b', 'scholar', 1100)
    pushAnchored('c', 'scholar', 12, 1200)

    const buckets = bucketTraceEvents(keeperTraceState.value.events)
    const noLineBucket = buckets.find(b => b.line === null)
    expect(noLineBucket).toBeDefined()
    expect(noLineBucket?.events.length).toBe(2)
    expect(noLineBucket?.events.map(e => e.source).sort()).toEqual(['bdi-snapshot', 'decision-log'])
  })

  it('sorts events newest-first within each bucket', () => {
    pushAnchored('a', 'scholar', 12, 1000)
    pushAnchored('b', 'scholar', 12, 3000)
    pushAnchored('c', 'scholar', 12, 2000)

    const buckets = bucketTraceEvents(keeperTraceState.value.events)
    expect(buckets[0]?.events.map(e => e.id)).toEqual(['b', 'c', 'a'])
  })

  it('orders buckets by most-recent head event first', () => {
    pushAnchored('old-h', 'scholar', 12, 1000)
    pushAnchored('mid-h', 'moth', 30, 5000)
    pushAnchored('new-h', 'luna', 50, 9000)

    const buckets = bucketTraceEvents(keeperTraceState.value.events)
    expect(buckets.map(b => b.keeperName)).toEqual(['luna', 'moth', 'scholar'])
  })
})

describe('OverlayKeeperTrace — render gating', () => {
  it('returns null when active=false', () => {
    pushAnchored('a', 'scholar', 12, 1000)

    const container = createContainer()
    render(html`<${OverlayKeeperTrace} active=${false} />`, container)
    expect(container.querySelector('[data-overlay="keeper-trace"]')).toBeNull()
  })

  it('returns null when active=true but no events', () => {
    const container = createContainer()
    render(html`<${OverlayKeeperTrace} active=${true} />`, container)
    expect(container.querySelector('[data-overlay="keeper-trace"]')).toBeNull()
  })

  it('renders the overlay region when active and events exist', () => {
    pushAnchored('a', 'scholar', 12, 1000)

    const container = createContainer()
    render(html`<${OverlayKeeperTrace} active=${true} />`, container)
    const region = container.querySelector('[role="region"][aria-label="Keeper trace overlay"]')
    expect(region).not.toBeNull()
    expect(region?.getAttribute('data-overlay')).toBe('keeper-trace')
  })
})

describe('OverlayKeeperTrace — bucket render (RFC-0028 §5)', () => {
  it('renders one bucket per (keeperName, line) tuple with the keeper + line label', () => {
    pushAnchored('a', 'scholar', 12, 1000)
    pushAnchored('b', 'moth', 30, 1100)

    const container = createContainer()
    render(html`<${OverlayKeeperTrace} active=${true} />`, container)
    const buckets = container.querySelectorAll('[data-overlay="keeper-trace"] [role="group"][data-keeper]')
    expect(buckets.length).toBe(2)
    const lineLabels = Array.from(buckets).map(b => b.textContent ?? '')
    expect(lineLabels.some(t => t.includes('L12'))).toBe(true)
    expect(lineLabels.some(t => t.includes('L30'))).toBe(true)
  })

  it('caps visible chips to TRACE_CHIP_CAP and renders +N overflow', () => {
    // Push 5 events, all anchored at scholar L12 within retention.
    // None coalesce because each tsMs is > COALESCE_WINDOW_MS apart.
    for (let i = 0; i < 5; i += 1) {
      pushAnchored(`e${i}`, 'scholar', 12, 1000 + i * 100, 'th')
    }

    const container = createContainer()
    render(html`<${OverlayKeeperTrace} active=${true} />`, container)

    const bucket = container.querySelector('[role="group"][data-keeper="scholar"][data-line="12"]')
    const chips = bucket?.querySelectorAll('li[role="img"]')
    expect(chips?.length).toBe(TRACE_CHIP_CAP)

    const overflow = bucket?.querySelector('[data-overflow]')
    expect(overflow?.textContent).toBe(`+${5 - TRACE_CHIP_CAP}`)
    expect(overflow?.getAttribute('data-overflow')).toBe(String(5 - TRACE_CHIP_CAP))
  })

  it('does not render overflow chip when bucket size <= TRACE_CHIP_CAP', () => {
    pushAnchored('e0', 'scholar', 12, 1000, 'th')
    pushAnchored('e1', 'scholar', 12, 1100, 'th')
    pushAnchored('e2', 'scholar', 12, 1200, 'th')

    const container = createContainer()
    render(html`<${OverlayKeeperTrace} active=${true} />`, container)
    const bucket = container.querySelector('[role="group"][data-keeper="scholar"]')
    const chips = bucket?.querySelectorAll('li[role="img"]')
    expect(chips?.length).toBe(3)
    expect(bucket?.querySelector('[data-overflow]')).toBeNull()
  })

  it('chips carry data-source attribute matching the event source', () => {
    pushAnchored('a', 'scholar', null, 1000) // no line → no-line bucket
    pushBdi('b', 'scholar', 1100)
    pushDecision('c', 'scholar', 1200)

    const container = createContainer()
    render(html`<${OverlayKeeperTrace} active=${true} />`, container)
    const bucket = container.querySelector('[role="group"][data-keeper="scholar"]')
    const chips = Array.from(bucket?.querySelectorAll('li[role="img"]') ?? [])
    const sources = chips.map(c => c.getAttribute('data-source'))
    expect(sources).toEqual(expect.arrayContaining(['anchored-thread', 'bdi-snapshot', 'decision-log']))
  })

  it('chip aria-label includes source + line + count', () => {
    pushAnchored('a', 'scholar', 42, 1000)
    pushAnchored('b', 'scholar', 42, 1010, 'th-2') // coalesces with 'a' (within COALESCE_WINDOW_MS)

    const container = createContainer()
    render(html`<${OverlayKeeperTrace} active=${true} />`, container)
    const chip = container.querySelector('li[role="img"]')
    // The single coalesced chip should have count 2.
    expect(chip?.getAttribute('aria-label')).toContain('thread')
    expect(chip?.getAttribute('aria-label')).toContain('L42')
    expect(chip?.getAttribute('aria-label')).toContain('×2')
  })
})

describe('OverlayKeeperTrace — keeperFilter', () => {
  it('renders only the named keeper\'s buckets when keeperFilter is set', () => {
    pushAnchored('a', 'scholar', 12, 1000)
    pushAnchored('b', 'moth', 30, 1100)
    pushAnchored('c', 'luna', 50, 1200)

    const container = createContainer()
    render(html`<${OverlayKeeperTrace} active=${true} keeperFilter=${'moth'} />`, container)
    const buckets = container.querySelectorAll('[role="group"][data-keeper]')
    expect(buckets.length).toBe(1)
    expect(buckets[0]?.getAttribute('data-keeper')).toBe('moth')
  })

  it('returns null when the named keeper has no events', () => {
    pushAnchored('a', 'scholar', 12, 1000)

    const container = createContainer()
    render(html`<${OverlayKeeperTrace} active=${true} keeperFilter=${'nobody'} />`, container)
    expect(container.querySelector('[data-overlay="keeper-trace"]')).toBeNull()
  })
})
