// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { html } from 'htm/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'

import {
  fetchKeeperStateDiagram,
  type KeeperStateDiagramResponse,
  type MemoryKindUsageEntry,
} from '../../api/keeper'
import { activeKeeperName } from '../../keeper-state'
import { keepers } from '../../store'
import {
  buildMemoryGraphModel,
  IdePersistencePanel,
  lifecycleStateFromKeeperPhase,
  persistenceStateFromKeeperPhase,
} from './ide-persistence-panel'
import { cursorOverlaySignal } from './keeper-cursor-overlay'

vi.mock('../../api/keeper', async () => {
  const actual = await vi.importActual<typeof import('../../api/keeper')>('../../api/keeper')
  return {
    ...actual,
    fetchKeeperStateDiagram: vi.fn(),
  }
})

const fetchKeeperStateDiagramMock = vi.mocked(fetchKeeperStateDiagram)

const usage: MemoryKindUsageEntry[] = [
  { kind: 'tool_result', used: 10, cap: 10, priority: 1 },
  { kind: 'semantic_note', used: 3, cap: 12, priority: 2 },
  { kind: 'turn_summary', used: 7, cap: 20, priority: 3 },
]

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
  activeKeeperName.value = ''
  keepers.value = []
  cursorOverlaySignal.value = {
    cursors: new Map(),
    heatmap: new Map(),
    collisions: [],
    active_file: null,
  }
  window.location.hash = ''
})

describe('ide persistence helpers', () => {
  it('maps keeper phases to lifecycle states', () => {
    expect(lifecycleStateFromKeeperPhase(null)).toBe('created')
    expect(lifecycleStateFromKeeperPhase('Running')).toBe('active')
    expect(lifecycleStateFromKeeperPhase('Paused')).toBe('idle')
    expect(lifecycleStateFromKeeperPhase('Crashed')).toBe('terminated')
  })

  it('maps keeper phases to persistence states', () => {
    expect(persistenceStateFromKeeperPhase('Running')).toBe('saved')
    expect(persistenceStateFromKeeperPhase('Compacting')).toBe('syncing')
    expect(persistenceStateFromKeeperPhase('Overflowed')).toBe('conflict')
    expect(persistenceStateFromKeeperPhase('Offline')).toBe('offline')
    expect(persistenceStateFromKeeperPhase('Running', true)).toBe('offline')
  })

  it('builds a keeper-centered memory graph from memory usage rows', () => {
    const graph = buildMemoryGraphModel('sangsu', usage)
    expect(graph.nodes.map(node => node.id)).toEqual([
      'keeper',
      'memory-tool_result',
      'memory-turn_summary',
      'memory-semantic_note',
    ])
    expect(graph.edges).toHaveLength(3)
    expect(graph.totalUsed).toBe(20)
    expect(graph.totalCap).toBe(42)
    expect(graph.saturatedCount).toBe(1)
  })
})

describe('IdePersistencePanel', () => {
  it('renders active keeper lifecycle and memory graph from the state diagram endpoint', async () => {
    activeKeeperName.value = 'sangsu'
    keepers.value = [{
      name: 'sangsu',
      status: 'online',
      phase: 'Running',
      last_heartbeat: '2026-05-06T00:00:00Z',
      memory_recent_note: 'kept the workspace root on main',
    }]
    fetchKeeperStateDiagramMock.mockResolvedValue({
      keeper: 'sangsu',
      current_phase: 'Compacting',
      mermaid: 'graph TD',
      memory_kind_usage: usage,
    } satisfies KeeperStateDiagramResponse)

    render(html`<${IdePersistencePanel} pollMs=${60_000} />`)

    await waitFor(() => expect(fetchKeeperStateDiagramMock).toHaveBeenCalledWith(
      'sangsu',
      expect.objectContaining({ signal: expect.any(AbortSignal) }),
    ))

    expect(screen.getByText('PERSISTENCE MAP')).toBeTruthy()
    expect(screen.getByText('MEMORY GRAPH')).toBeTruthy()
    expect(screen.getByTestId('ide-persistence-lifecycle')).toBeTruthy()
    expect(screen.getByTestId('ide-memory-graph')).toBeTruthy()
    expect(screen.getByText(/tool_result/)).toBeTruthy()
    expect(screen.getByText('kept the workspace root on main')).toBeTruthy()
  })

  it('falls back to the explicit keeper name when no active keeper is selected', async () => {
    fetchKeeperStateDiagramMock.mockResolvedValue({
      keeper: 'keeper-2',
      current_phase: 'Running',
      mermaid: 'graph TD',
      memory_kind_usage: [],
    } satisfies KeeperStateDiagramResponse)

    render(html`<${IdePersistencePanel} keeperName="keeper-2" pollMs=${60_000} />`)

    await waitFor(() => expect(fetchKeeperStateDiagramMock).toHaveBeenCalledWith(
      'keeper-2',
      expect.objectContaining({ signal: expect.any(AbortSignal) }),
    ))
    expect(screen.getByText('keeper-2')).toBeTruthy()
    expect(screen.getByText('memory bank data unavailable')).toBeTruthy()
  })

  it('links persistence state back to code focus and keeper runtime context', async () => {
    activeKeeperName.value = 'sangsu'
    keepers.value = [{
      name: 'sangsu',
      status: 'online',
      phase: 'Running',
    }]
    cursorOverlaySignal.value = {
      cursors: new Map([[
        'sangsu',
        {
          keeper_id: 'sangsu',
          file_path: 'lib/runtime.ml',
          line: 42,
          column: 1,
          focus_mode: 'editing',
          last_update: 100,
        },
      ]]),
      heatmap: new Map(),
      collisions: [],
      active_file: 'lib/runtime.ml',
    }
    fetchKeeperStateDiagramMock.mockResolvedValue({
      keeper: 'sangsu',
      current_phase: 'Running',
      mermaid: 'graph TD',
      memory_kind_usage: [],
    } satisfies KeeperStateDiagramResponse)

    render(html`<${IdePersistencePanel} pollMs=${60_000} />`)

    await waitFor(() => expect(fetchKeeperStateDiagramMock).toHaveBeenCalled())
    const focusChip = screen.getByRole('button', {
      name: 'Open current persistence focus Code lib/runtime.ml:42',
    })
    fireEvent.click(focusChip)
    expect(window.location.hash).toBe(
      '#code?section=ide-shell&view=source&file=lib%2Fruntime.ml&line=42&surface=Persistence&label=sangsu+current+focus&source_id=persistence%3Asangsu&keeper=sangsu',
    )

    const links = Array.from(screen.getByLabelText('Persistence context links')
      .querySelectorAll<HTMLButtonElement>('button'))
    expect(links.map(link => link.textContent)).toEqual(['Code', 'Telemetry', 'Keeper'])
    expect(links[0]?.title).toBe('Code lib/runtime.ml:42')
    expect(links[1]?.title).toBe('Fleet telemetry event log · query sangsu')
    expect(links[2]?.title).toBe('Keeper sangsu')

    const badge = screen.getByText('CTX 3')
    expect(badge.getAttribute('data-context-route-count')).toBe('3')
    expect(badge.getAttribute('title')).toBe('Linked context: Code, Telemetry, Keeper')
    expect(badge.getAttribute('aria-label'))
      .toBe('Persistence map has 3 linked context routes: Code, Telemetry, Keeper')

    fireEvent.click(links[0]!)
    expect(window.location.hash).toBe(
      '#code?section=ide-shell&view=source&file=lib%2Fruntime.ml&line=42&surface=Persistence&label=sangsu+current+focus&source_id=persistence%3Asangsu&keeper=sangsu',
    )

    fireEvent.click(links[1]!)
    expect(window.location.hash).toBe('#monitoring?section=fleet-health&view=event-log&q=sangsu')
  })
})
