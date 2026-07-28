// @vitest-environment happy-dom
import { cleanup, render, waitFor } from '@testing-library/preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { afterEach, describe, expect, it, vi } from 'vitest'

import {
  fetchKeeperStateDiagram,
  type KeeperStateDiagramResponse,
} from '../../api/keeper'
import { activeKeeperName } from '../../keeper-state'
import { keepers } from '../../store'
import { IdePersistencePanel } from './ide-persistence-panel'

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
})

describe('IdePersistencePanel a11y', () => {
  it('has no axe violations for lifecycle content', async () => {
    activeKeeperName.value = 'sangsu'
    keepers.value = [{
      name: 'sangsu',
      status: 'online',
      phase: 'Running',
      last_heartbeat: '2026-05-06T00:00:00Z',
    }]
    fetchKeeperStateDiagramMock.mockResolvedValue({
      keeper: 'sangsu',
      current_phase: 'Running',
      mermaid: 'graph TD',
    } satisfies KeeperStateDiagramResponse)

    const { container, findByTestId } = render(html`<${IdePersistencePanel} pollMs=${60_000} />`)
    await findByTestId('ide-persistence-lifecycle')
    await waitFor(() => expect(fetchKeeperStateDiagramMock).toHaveBeenCalled())

    expect(await axe(container)).toHaveNoViolations()
  })
})
