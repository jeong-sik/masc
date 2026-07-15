import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { fireEvent } from '@testing-library/preact'
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
import { ideReplayUntilMs, setIdeReplayUntilMs } from './ide-replay-state'
import { ideContextFocus } from './ide-state'

const mountedContainers: HTMLElement[] = []

function createContainer(): HTMLElement {
  const container = document.createElement('div')
  mountedContainers.push(container)
  return container
}

function pushAnchored(
  id: string,
  keeperName: string,
  line: number | null,
  tsMs: number,
  threadId = 'th',
  filePath: string | null = null,
): void {
  pushTrace({
    id,
    tsMs,
    keeperName,
    source: 'anchored-thread',
    threadId,
    filePath,
    line,
  })
}

function pushRuntime(id: string, keeperName: string, tsMs: number): void {
  pushTrace({
    id,
    tsMs,
    keeperName,
    source: 'runtime-hop',
    hopId: `hop-${id}`,
    provider: 'weighted_score',
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

function pushActivity(
  id: string,
  keeperName: string,
  line: number,
  tsMs: number,
  filePath = 'runtime.ts',
  refs: Partial<Extract<KeeperTraceEventForTest, { source: 'activity-event' }>> = {},
): void {
  pushTrace({
    id,
    tsMs,
    keeperName,
    source: 'activity-event',
    eventId: `evt-${id}`,
    filePath,
    line,
    surface: 'Task',
    ...refs,
  })
}

type KeeperTraceEventForTest = Parameters<typeof pushTrace>[0]

beforeEach(() => {
  clearTraces()
  ideContextFocus.value = null
})

afterEach(() => {
  window.location.hash = ''
  for (const container of mountedContainers.splice(0)) {
    render(null, container)
  }
  setIdeReplayUntilMs(null)
  ideContextFocus.value = null
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

  it('keeps same-line trace buckets separate when file paths differ', () => {
    pushAnchored('a', 'scholar', 12, 1000, 'th-a', 'runtime.ts')
    pushAnchored('b', 'scholar', 12, 1100, 'th-b', 'worker.ts')

    const buckets = bucketTraceEvents(keeperTraceState.value.events)
    expect(buckets.map(b => `${b.keeperName}@${b.filePath}@${b.line}`).sort())
      .toEqual(['scholar@runtime.ts@12', 'scholar@worker.ts@12'])
  })

  it('non-anchored sources fall into the keeper-level no-line bucket', () => {
    pushRuntime('a', 'scholar', 1000)
    pushDecision('b', 'scholar', 1100)
    pushAnchored('c', 'scholar', 12, 1200, 'th-c', 'runtime.ts')
    pushActivity('d', 'scholar', 12, 1300)

    const buckets = bucketTraceEvents(keeperTraceState.value.events)
    const noLineBucket = buckets.find(b => b.line === null)
    expect(noLineBucket).toBeDefined()
    expect(noLineBucket?.events.length).toBe(2)
    expect(noLineBucket?.events.map(e => e.source).sort()).toEqual(['decision-log', 'runtime-hop'])
    const lineBucket = buckets.find(b => b.filePath === 'runtime.ts' && b.line === 12)
    expect(lineBucket?.events.map(e => e.source).sort()).toEqual(['activity-event', 'anchored-thread'])
  })

  it('record traces with optional file context enter file-line buckets', () => {
    pushTrace({
      id: 'runtime-context-scholar',
      tsMs: 1000,
      keeperName: 'scholar',
      source: 'runtime-hop',
      hopId: 'scholar-1',
      provider: 'weighted_score',
      filePath: 'runtime.ts',
      line: 12,
    })
    pushTrace({
      id: 'decision-context',
      tsMs: 1100,
      keeperName: 'scholar',
      source: 'decision-log',
      decisionId: 'decision:scholar:1:tool',
      semanticOutcome: 'success',
      filePath: 'runtime.ts',
      line: 12,
    })
    pushTrace({
      id: 'runtime-context',
      tsMs: 1200,
      keeperName: 'mainline',
      source: 'runtime-hop',
      hopId: 'mainline-7',
      provider: 'weighted_score',
      filePath: 'router.ts',
      line: 44,
    })

    const buckets = bucketTraceEvents(keeperTraceState.value.events)
    const runtimeBucket = buckets.find(b => b.filePath === 'runtime.ts' && b.line === 12)
    expect(runtimeBucket?.events.map(e => e.source).sort()).toEqual(['decision-log', 'runtime-hop'])
    const routerBucket = buckets.find(b => b.filePath === 'router.ts' && b.line === 44)
    expect(routerBucket?.events.map(e => e.source)).toEqual(['runtime-hop'])
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

  it('projects buckets through the shared audit replay cursor', () => {
    pushAnchored('old', 'scholar', 12, 1000, 'old-thread', 'runtime.ts')
    pushAnchored('future', 'scholar', 99, 3000, 'future-thread', 'runtime.ts')
    setIdeReplayUntilMs(1500)

    const container = createContainer()
    render(html`<${OverlayKeeperTrace} active=${true} />`, container)

    expect(container.querySelector('[data-line="12"]')).not.toBeNull()
    expect(container.querySelector('[data-line="99"]')).toBeNull()
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

  it('renders sibling rows when same (keeper, line) buckets differ only by filePath', () => {
    // Regression for PR #15162 P2: bucket key now includes filePath but the
    // rendered row key did not, so Preact reconciliation could reuse one
    // bucket's DOM for a sibling whose keeperName + line matched but whose
    // filePath differed. The render must produce two distinct rows.
    pushAnchored('a', 'scholar', 12, 1000, 'th-a', 'runtime.ts')
    pushAnchored('b', 'scholar', 12, 1100, 'th-b', 'worker.ts')

    const container = createContainer()
    render(html`<${OverlayKeeperTrace} active=${true} />`, container)
    const buckets = container.querySelectorAll('[role="group"][data-keeper="scholar"][data-line="12"]')
    expect(buckets.length).toBe(2)
    const filePaths = Array.from(buckets).map(b => b.getAttribute('data-file')).sort()
    expect(filePaths).toEqual(['runtime.ts', 'worker.ts'])
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
    const chips = bucket?.querySelectorAll('.ide-trace-chip')
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
    const chips = bucket?.querySelectorAll('.ide-trace-chip')
    expect(chips?.length).toBe(3)
    expect(bucket?.querySelector('[data-overflow]')).toBeNull()
  })

  it('chips carry data-source attribute matching the event source', () => {
    pushAnchored('a', 'scholar', null, 1000) // no line → no-line bucket
    pushRuntime('b', 'scholar', 1100)
    pushDecision('c', 'scholar', 1200)
    pushActivity('d', 'scholar', 4, 1300)

    const container = createContainer()
    render(html`<${OverlayKeeperTrace} active=${true} />`, container)
    const bucket = container.querySelector('[role="group"][data-keeper="scholar"][data-line="no-line"]')
    const chips = Array.from(bucket?.querySelectorAll('.ide-trace-chip') ?? [])
    const sources = chips.map(c => c.getAttribute('data-source'))
    expect(sources).toEqual(expect.arrayContaining(['anchored-thread', 'decision-log', 'runtime-hop']))
    const lineBucket = container.querySelector('[role="group"][data-keeper="scholar"][data-line="4"]')
    expect(lineBucket?.querySelector('.ide-trace-chip')?.getAttribute('data-source')).toBe('activity-event')
  })

  it('chip aria-label includes source + line + count', () => {
    pushAnchored('a', 'scholar', 42, 1000)
    pushAnchored('b', 'scholar', 42, 1010, 'th-2') // coalesces with 'a' (within COALESCE_WINDOW_MS)

    const container = createContainer()
    render(html`<${OverlayKeeperTrace} active=${true} />`, container)
    const chip = container.querySelector('.ide-trace-chip')
    // The single coalesced chip should have count 2.
    expect(chip?.getAttribute('aria-label')).toContain('thread')
    expect(chip?.getAttribute('aria-label')).toContain('L42')
    expect(chip?.getAttribute('aria-label')).toContain('×2')
  })

  it('clicking a trace chip jumps the shared replay cursor and focuses IDE context', () => {
    pushActivity('a', 'scholar', 12, 2000, 'runtime.ts', {
      eventId: 'evt-a',
      taskId: 'task-runtime',
      logId: 'turn-12',
    })

    const container = createContainer()
    render(html`<${OverlayKeeperTrace} active=${true} />`, container)

    const chip = container.querySelector<HTMLButtonElement>('.ide-trace-chip[data-event-id="a"]')
    expect(chip).not.toBeNull()
    fireEvent.click(chip!)

    expect(ideReplayUntilMs.value).toBe(2000)
    expect(ideContextFocus.value).toMatchObject({
      file_path: 'runtime.ts',
      line: 12,
      surface: 'Task',
      label: 'Task activity evt-a',
      source_id: 'trace:a',
      keeper_id: 'scholar',
    })
    expect(ideContextFocus.value?.route_links?.map(link => link.label)).toEqual([
      'Code',
      'Task',
      'Log',
      'Telemetry',
      'Keeper',
    ])
  })

  it('renders operational route links for enriched activity traces', () => {
    pushActivity('a', 'scholar', 12, 1000, 'runtime.ts', {
      eventId: 'evt-a',
      taskId: 'task-runtime',
      prId: '15035',
      gitRef: 'main',
      logId: 'turn-12',
      sessionId: 'sess-runtime',
      operationId: 'op-runtime',
      workerRunId: 'wr-runtime',
    })

    const container = createContainer()
    render(html`<${OverlayKeeperTrace} active=${true} />`, container)

    const links = [...container.querySelectorAll<HTMLButtonElement>('.ide-trace-route-link')]
    expect(links.map(link => link.textContent)).toEqual([
      'Code',
      'Task',
      'PR',
      'Git',
      'Log',
      'Telemetry',
      'Keeper',
    ])
    const badge = container.querySelector<HTMLElement>('.ide-trace-context-badge')
    expect(badge?.textContent?.trim()).toBe('CTX 7')
    expect(badge?.getAttribute('data-context-route-count')).toBe('7')
    expect(badge?.getAttribute('title'))
      .toBe('Linked context: Code, Task, PR, Git, Log, Telemetry, Keeper')
    expect(badge?.getAttribute('aria-label'))
      .toBe('scholar trace has 7 linked context routes: Code, Task, PR, Git, Log, Telemetry, Keeper')

    fireEvent.click(links[0]!)
    expect(window.location.hash).toBe(
      '#code?section=ide-shell&view=source&file=runtime.ts&line=12&surface=Task&label=Task+activity+evt-a&source_id=trace%3Aa&keeper=scholar',
    )

    fireEvent.click(links[4]!)
    expect(window.location.hash).toBe('#monitoring?section=runtime&view=audit&log_id=turn-12')

    fireEvent.click(links[5]!)
    expect(window.location.hash).toBe(
      '#monitoring?section=fleet-health&view=event-log&session_id=sess-runtime&operation_id=op-runtime&worker_run_id=wr-runtime&q=turn-12',
    )

    fireEvent.click(links[6]!)
    expect(window.location.hash).toBe('#monitoring?section=agents&view=keepers&keeper=scholar')
  })

  it('renders operational route links for contextual decision traces', () => {
    pushTrace({
      id: 'decision-context',
      tsMs: 2000,
      keeperName: 'scholar',
      source: 'decision-log',
      decisionId: 'decision:scholar:2000:tool_use',
      semanticOutcome: 'error_retryable',
      decisionChoice: 'use_shell',
      decisionReason: 'verify touched test target',
      filePath: 'runtime.ts',
      line: 19,
      taskId: 'task-decision',
      boardPostId: 'post-decision',
      commentId: 'comment-decision',
      prId: '15035',
      gitRef: 'refs/heads/decision-route',
      logId: 'decision-turn-19',
      sessionId: 'sess-decision',
      operationId: 'op-decision',
      workerRunId: 'worker-decision',
    })

    const container = createContainer()
    render(html`<${OverlayKeeperTrace} active=${true} />`, container)

    const bucket = container.querySelector('[role="group"][data-keeper="scholar"][data-line="19"]')
    expect(bucket?.getAttribute('data-file')).toBe('runtime.ts')
    const links = [...container.querySelectorAll<HTMLButtonElement>('.ide-trace-route-link')]
    expect(links.map(link => link.textContent)).toEqual([
      'Code',
      'Task',
      'Board',
      'Comment',
      'PR',
      'Git',
      'Log',
      'Telemetry',
      'Keeper',
    ])

    const chip = container.querySelector<HTMLButtonElement>('.ide-trace-chip[data-event-id="decision-context"]')
    expect(chip).not.toBeNull()
    fireEvent.click(chip!)
    expect(ideReplayUntilMs.value).toBe(2000)
    expect(ideContextFocus.value).toMatchObject({
      file_path: 'runtime.ts',
      line: 19,
      surface: 'Decision',
      label: 'use_shell: verify touched test target',
      source_id: 'trace:decision-context',
      keeper_id: 'scholar',
    })
    expect(ideContextFocus.value?.route_links?.map(link => link.label)).toEqual([
      'Code',
      'Task',
      'Board',
      'Comment',
      'PR',
      'Git',
      'Log',
      'Telemetry',
      'Keeper',
    ])
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
