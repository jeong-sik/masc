import { html } from 'htm/preact'
import { render } from 'preact'
import { waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { FusionRunRecord } from '../api/dashboard-fusion'
import { navigate } from '../router'
import { fusionRuns, refreshFusionRuns } from '../store'
import { KeeperFusionRuns } from './keeper-detail-fusion'

vi.mock('../store', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../store')>()
  return { ...actual, refreshFusionRuns: vi.fn() }
})

vi.mock('../router', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../router')>()
  return { ...actual, navigate: vi.fn() }
})

function run(overrides: Partial<FusionRunRecord> & { runId: string; keeper: string }): FusionRunRecord {
  const { runId, keeper, ...rest } = overrides
  return {
    runId,
    keeper,
    preset: 'trio',
    topology: null,
    startedAt: 1_788_503_280,
    status: 'completed',
    ...rest,
  }
}

describe('KeeperFusionRuns', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    fusionRuns.value = []
    vi.mocked(refreshFusionRuns).mockClear()
    vi.mocked(navigate).mockClear()
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    fusionRuns.value = []
  })

  it('fetches the run registry on mount', async () => {
    render(html`<${KeeperFusionRuns} keeperName="polisher" />`, container)
    await waitFor(() => expect(refreshFusionRuns).toHaveBeenCalledTimes(1))
  })

  it('lists only this keeper runs and links each to the fusion surface', () => {
    fusionRuns.value = [
      run({ runId: 'fus-rondo', keeper: 'rondo' }),
      run({ runId: 'fus-mine', keeper: 'polisher', status: 'failed' }),
    ]

    render(html`<${KeeperFusionRuns} keeperName="polisher" />`, container)

    const rows = container.querySelectorAll('[data-testid="keeper-fusion-runs"] button')
    expect(rows.length).toBe(1)
    expect(rows[0]?.getAttribute('data-run-id')).toBe('fus-mine')
    expect(container.textContent).toContain('fus-mine')
    expect(container.textContent).toContain('실패')

    rows[0]?.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    expect(navigate).toHaveBeenCalledWith('fusion', { run_id: 'fus-mine' })
  })

  it('renders nothing when this keeper has no fusion runs', () => {
    fusionRuns.value = [run({ runId: 'fus-rondo', keeper: 'rondo' })]

    render(html`<${KeeperFusionRuns} keeperName="polisher" />`, container)

    expect(container.querySelector('[data-testid="keeper-fusion-runs"]')).toBeNull()
    expect(container.textContent ?? '').not.toContain('Fusion deliberations')
  })
})
