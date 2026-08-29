// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { html } from 'htm/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'

import {
  fetchKeeperStateDiagram,
  type KeeperStateDiagramResponse,
} from '../../api/keeper'
import { activeKeeperName } from '../../keeper-state'
import { keepers } from '../../store'
import {
  IdePersistencePanel,
  lifecycleStateFromKeeperPhase,
  persistenceStateFromKeeperPhase,
} from './ide-persistence-panel'

vi.mock('../../api/keeper', async () => {
  const actual = await vi.importActual<typeof import('../../api/keeper')>('../../api/keeper')
  return {
    ...actual,
    fetchKeeperStateDiagram: vi.fn(),
  }
})

const fetchKeeperStateDiagramMock = vi.mocked(fetchKeeperStateDiagram)

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
  activeKeeperName.value = ''
  keepers.value = []
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
    expect(persistenceStateFromKeeperPhase('Offline')).toBe('offline')
    expect(persistenceStateFromKeeperPhase('Running', true)).toBe('offline')
  })
})

describe('IdePersistencePanel', () => {
  it('renders active keeper lifecycle from the state diagram endpoint', async () => {
    activeKeeperName.value = 'sangsu'
    keepers.value = [{
      name: 'sangsu',
      status: 'online',
      phase: 'Running',
      last_heartbeat: '2026-05-06T00:00:00Z',
    }]
    fetchKeeperStateDiagramMock.mockResolvedValue({
      keeper: 'sangsu',
      current_phase: 'Compacting',
      mermaid: 'graph TD',
    } satisfies KeeperStateDiagramResponse)

    render(html`<${IdePersistencePanel} pollMs=${60_000} />`)

    await waitFor(() => expect(fetchKeeperStateDiagramMock).toHaveBeenCalledWith(
      'sangsu',
      expect.objectContaining({ signal: expect.any(AbortSignal) }),
    ))

    expect(screen.getByText('PERSISTENCE MAP')).toBeTruthy()
    expect(screen.getByTestId('ide-persistence-lifecycle')).toBeTruthy()
  })

  it('falls back to the explicit keeper name when no active keeper is selected', async () => {
    fetchKeeperStateDiagramMock.mockResolvedValue({
      keeper: 'keeper-2',
      current_phase: 'Running',
      mermaid: 'graph TD',
    } satisfies KeeperStateDiagramResponse)

    render(html`<${IdePersistencePanel} keeperName="keeper-2" pollMs=${60_000} />`)

    await waitFor(() => expect(fetchKeeperStateDiagramMock).toHaveBeenCalledWith(
      'keeper-2',
      expect.objectContaining({ signal: expect.any(AbortSignal) }),
    ))
    expect(screen.getByText('keeper-2')).toBeTruthy()
  })

  it('links persistence state back to keeper runtime context', async () => {
    activeKeeperName.value = 'sangsu'
    keepers.value = [{
      name: 'sangsu',
      status: 'online',
      phase: 'Running',
    }]
    fetchKeeperStateDiagramMock.mockResolvedValue({
      keeper: 'sangsu',
      current_phase: 'Running',
      mermaid: 'graph TD',
    } satisfies KeeperStateDiagramResponse)

    render(html`<${IdePersistencePanel} pollMs=${60_000} />`)

    await waitFor(() => expect(fetchKeeperStateDiagramMock).toHaveBeenCalled())

    const links = Array.from(screen.getByLabelText('Persistence context links')
      .querySelectorAll<HTMLButtonElement>('button'))
    expect(links.map(link => link.textContent)).toEqual(['Telemetry', 'Keeper'])
    expect(links[0]?.title).toBe('Fleet telemetry event log · query sangsu')
    expect(links[1]?.title).toBe('Keeper sangsu')

    const badge = screen.getByText('CTX 2')
    expect(badge.getAttribute('data-context-route-count')).toBe('2')
    expect(badge.getAttribute('title')).toBe('Linked context: Telemetry, Keeper')
    expect(badge.getAttribute('aria-label'))
      .toBe('Persistence map has 2 linked context routes: Telemetry, Keeper')

    fireEvent.click(links[0]!)
    expect(window.location.hash).toBe('#monitoring?section=fleet-health&view=event-log&q=sangsu')
  })
})
