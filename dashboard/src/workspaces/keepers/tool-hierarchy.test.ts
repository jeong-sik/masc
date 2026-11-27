import { html } from 'htm/preact'
import { cleanup, render } from '@testing-library/preact'
import { afterEach, describe, expect, it } from 'vitest'
import {
  ToolHierarchyView,
  buildOpenWorkHierarchy,
  buildToolCallHierarchy,
  type KeeperToolCallWithMeta,
} from './tool-hierarchy'
import { decodeOpenActivities, openWorkHierarchy } from './turn-open-work'

function makeEntry(overrides: Partial<KeeperToolCallWithMeta>): KeeperToolCallWithMeta {
  return {
    ts: 1_700_000_000,
    record_kind: 'tool_call',
    keeper: 'sangsu',
    tool: 'Read',
    duration_ms: 100,
    wire_outcome: 'ok',
    disposition: 'completed',
    input: {},
    output: 'ok',
    ...overrides,
  }
}

describe('tool-hierarchy', () => {
  afterEach(() => {
    cleanup()
  })

  it('groups concurrent parallel batches by cohort.batch_index and computes wall time vs summed duration', () => {
    const entries: KeeperToolCallWithMeta[] = [
      makeEntry({
        execution_id: 'e1',
        tool: 'WebFetch',
        ts: 1000,
        duration_ms: 300,
        turn: 1,
        cohort: { batch_index: 0, batch_size: 2, concurrent: true },
        reach: 'network',
      }),
      makeEntry({
        execution_id: 'e2',
        tool: 'Execute',
        ts: 1000.05,
        duration_ms: 200,
        turn: 1,
        cohort: { batch_index: 0, batch_size: 2, concurrent: true },
        reach: 'sandbox',
      }),
      makeEntry({
        execution_id: 'e3',
        tool: 'masc_status',
        ts: 1001,
        duration_ms: 40,
        turn: 1,
      }),
    ]

    const nodes = buildToolCallHierarchy(entries)
    expect(nodes).toHaveLength(2)
    const batch = nodes[0]!
    expect(batch.kind).toBe('parallel_batch')
    if (batch.kind !== 'parallel_batch') throw new Error('expected parallel_batch')
    expect(batch.members).toHaveLength(2)
    expect(batch.wallTimeMs).toBe(300)
    expect(batch.summedDurationMs).toBe(500)
    expect(batch.reaches).toEqual(['외부 · 네트워크', '샌드박스'])
    expect(batch.members[0]!.overlapStartPct).toBe(0)
    expect(batch.members[1]!.overlapStartPct).toBeGreaterThan(0)
  })

  it('groups overlapping execution windows into a ParallelBatchGroup even without explicit cohort metadata', () => {
    const entries: KeeperToolCallWithMeta[] = [
      makeEntry({ execution_id: 'o1', tool: 'Read', ts: 2000, duration_ms: 500, turn: 2 }),
      makeEntry({ execution_id: 'o2', tool: 'Grep', ts: 2000.1, duration_ms: 300, turn: 2 }),
      makeEntry({ execution_id: 'o3', tool: 'Write', ts: 2002, duration_ms: 50, turn: 2 }),
    ]

    const nodes = buildToolCallHierarchy(entries)
    expect(nodes).toHaveLength(2)
    expect(nodes[0]!.kind).toBe('parallel_batch')
    expect(nodes[1]!.kind).toBe('single')
  })

  it('groups async delegation lifecycles by operation_id and default-collapses status polls in UI', () => {
    const entries: KeeperToolCallWithMeta[] = [
      makeEntry({
        execution_id: 'd1',
        tool: 'masc_keeper_delegate',
        ts: 3000,
        duration_ms: 120,
        input: { target: 'reviewer' },
        output: JSON.stringify({ operation_id: 'op-async-42', state: 'queued' }),
      }),
      makeEntry({
        execution_id: 'd2',
        tool: 'masc_keeper_delegate_status',
        ts: 3002,
        duration_ms: 15,
        input: { operation_id: 'op-async-42' },
        output: JSON.stringify({ state: 'running' }),
      }),
      makeEntry({
        execution_id: 'd3',
        tool: 'masc_keeper_delegate_status_poll',
        ts: 3004,
        duration_ms: 18,
        input: { operation_id: 'op-async-42' },
        output: JSON.stringify({ state: 'completed' }),
      }),
    ]

    const nodes = buildToolCallHierarchy(entries)
    expect(nodes).toHaveLength(1)
    const chain = nodes[0]!
    expect(chain.kind).toBe('delegate_chain')
    if (chain.kind !== 'delegate_chain') throw new Error('expected delegate_chain')
    expect(chain.operationId).toBe('op-async-42')
    expect(chain.launch?.execution_id).toBe('d1')
    expect(chain.statusPolls).toHaveLength(2)
    expect(chain.totalCalls).toBe(3)

    const view = render(html`<${ToolHierarchyView} nodes=${nodes} activeExecutionId="d1" />`)
    const pollsDetails = view.getByTestId('tool-hierarchy-delegate-polls') as HTMLDetailsElement
    expect(pollsDetails.open).toBe(false)
    expect(pollsDetails.textContent).toContain('상태 폴링 2회')
  })

  it('builds open work hierarchy with deduplicated reach badges from turn-open-work', () => {
    const open = decodeOpenActivities([
      {
        kind: 'tool',
        tool_use_id: 't1',
        name: 'WebFetch',
        stage: 'executing',
        started_at_unix: 10,
        since_unix: 10,
        cohort: { batch_index: 1, batch_size: 2, concurrent: true },
        reach: 'network',
      },
      {
        kind: 'tool',
        tool_use_id: 't2',
        name: 'Execute',
        stage: 'executing',
        started_at_unix: 10,
        since_unix: 10,
        cohort: { batch_index: 1, batch_size: 2, concurrent: true },
        reach: 'sandbox',
      },
    ])!

    const h1 = buildOpenWorkHierarchy(open)
    const h2 = openWorkHierarchy(open)
    expect(h1).toEqual(h2)
    expect(h1).toHaveLength(1)
    expect(h1[0]!.kind).toBe('parallel_batch')
    if (h1[0]!.kind === 'parallel_batch') {
      expect(h1[0]!.reaches).toEqual(['외부 · 네트워크', '샌드박스'])
    }
  })
})
