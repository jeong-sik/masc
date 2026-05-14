// @vitest-environment happy-dom
import { cleanup, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { html } from 'htm/preact'
import {
  fetchKeeperComposite,
  fetchKeeperStateDiagram,
  type KeeperCompositeSnapshot,
  type KeeperStateDiagramResponse,
  type MemoryKindUsageEntry,
} from '../api/keeper'
import { filterMemoryKindUsage, KeeperMemoryTierPanel } from './keeper-memory-tier-panel'

vi.mock('../api/keeper', async () => {
  const actual = await vi.importActual<typeof import('../api/keeper')>('../api/keeper')
  return {
    ...actual,
    fetchKeeperComposite: vi.fn(),
    fetchKeeperStateDiagram: vi.fn(),
  }
})

const fetchKeeperCompositeMock = vi.mocked(fetchKeeperComposite)
const fetchKeeperStateDiagramMock = vi.mocked(fetchKeeperStateDiagram)

const sample: MemoryKindUsageEntry[] = [
  { kind: 'tool_result', used: 10, cap: 10, priority: 1 },
  { kind: 'tool_call', used: 5, cap: 10, priority: 1 },
  { kind: 'text', used: 20, cap: 20, priority: 2 },
  { kind: 'board_post', used: 3, cap: 8, priority: 3 },
  { kind: 'uncapped', used: 99, cap: 0, priority: 4 },
]

describe('filterMemoryKindUsage', () => {
  it('returns the input reference when query empty and filter=all', () => {
    expect(filterMemoryKindUsage(sample, '')).toBe(sample)
    expect(filterMemoryKindUsage(sample, '   ')).toBe(sample)
  })

  it('filters by case-insensitive substring on kind', () => {
    const out = filterMemoryKindUsage(sample, 'TOOL')
    expect(out.map(r => r.kind)).toEqual(['tool_result', 'tool_call'])
  })

  it('trims the query before matching', () => {
    const out = filterMemoryKindUsage(sample, '  board  ')
    expect(out.map(r => r.kind)).toEqual(['board_post'])
  })

  it('returns an empty array when no kind matches', () => {
    expect(filterMemoryKindUsage(sample, 'nonexistent_kind')).toEqual([])
  })

  it('keeps only saturated rows when filter=saturated', () => {
    const out = filterMemoryKindUsage(sample, '', 'saturated')
    expect(out.map(r => r.kind)).toEqual(['tool_result', 'text'])
  })

  it('treats cap=0 as never saturated (no div-by-zero framing)', () => {
    const out = filterMemoryKindUsage(sample, '', 'saturated')
    expect(out.some(r => r.kind === 'uncapped')).toBe(false)
  })

  it('combines saturated filter with substring query', () => {
    const out = filterMemoryKindUsage(sample, 'tool', 'saturated')
    expect(out.map(r => r.kind)).toEqual(['tool_result'])
  })

  it('saturated filter with empty query still narrows rows', () => {
    const out = filterMemoryKindUsage(sample, '   ', 'saturated')
    expect(out).toHaveLength(2)
  })

  it('does not mutate the input array', () => {
    const snapshot = sample.slice()
    filterMemoryKindUsage(sample, 'tool', 'saturated')
    expect(sample).toEqual(snapshot)
  })

  it('returns an empty array when saturated filter matches nothing', () => {
    const noneSaturated: MemoryKindUsageEntry[] = [
      { kind: 'a', used: 1, cap: 10, priority: 1 },
      { kind: 'b', used: 0, cap: 5, priority: 2 },
    ]
    expect(filterMemoryKindUsage(noneSaturated, '', 'saturated')).toEqual([])
  })
})

function mockMemoryTierFetches(usage: MemoryKindUsageEntry[]) {
  fetchKeeperStateDiagramMock.mockResolvedValue({
    keeper: 'keeper-1',
    current_phase: 'Compacting',
    mermaid: 'graph TD',
    memory_kind_usage: usage,
  } satisfies KeeperStateDiagramResponse)
  const composite = {
    correlation_id: 'keeper-1:run-1',
    run_id: 'run-1',
    ts: 0,
    phase: 'Compacting',
    turn_phase: 'idle',
    decision: { stage: 'idle' },
    cascade: { state: 'idle' },
    compaction: { stage: 'compacting' },
    measurement: { captured: false },
    invariants: {
      phase_turn_alignment: true,
      no_cascade_before_measurement: true,
      compaction_atomicity: true,
      event_priority_monotone: true,
      phase_derivation_agreement: true,
    },
    fsm_guard_violations: 0,
    is_live: true,
    last_outcome: null,
    recommended_actions: [],
  } satisfies KeeperCompositeSnapshot
  fetchKeeperCompositeMock.mockResolvedValue(composite)
}

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('KeeperMemoryTierPanel status chips', () => {
  it('renders memory tier labels through StatusChip without uppercasing', async () => {
    mockMemoryTierFetches([{ kind: 'tool_result', used: 10, cap: 10, priority: 1 }])

    render(html`<${KeeperMemoryTierPanel} keeperName="keeper-1" />`)

    await waitFor(() => expect(screen.getByText('KMC compacting')).toBeTruthy())

    const chips = Array.from(document.querySelectorAll('[data-status-chip]'))
    const kmcChip = chips.find(chip => chip.textContent === 'KMC compacting')
    const compactingChip = chips.find(chip => chip.textContent === 'compacting')

    expect(kmcChip?.getAttribute('data-status-chip-tone')).toBe('neutral')
    expect(kmcChip?.getAttribute('data-status-chip-uppercase')).toBe('false')
    expect(compactingChip?.getAttribute('data-status-chip-tone')).toBe('warn')
    expect(compactingChip?.getAttribute('data-status-chip-uppercase')).toBe('false')
  })
})
