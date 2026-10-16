import { html } from 'htm/preact'
import { cleanup, fireEvent, render, waitFor } from '@testing-library/preact'
import { act } from 'preact/test-utils'
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
    topology: 'simple',
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
    cleanup()
    container.remove()
    fusionRuns.value = []
  })

  it('fetches the run registry on mount', async () => {
    render(html`<${KeeperFusionRuns} keeperName="polisher" />`, { container })
    await waitFor(() => expect(refreshFusionRuns).toHaveBeenCalledTimes(1))
  })

  it('lists only this keeper runs and links each to the fusion surface', () => {
    fusionRuns.value = [
      run({ runId: 'fus-rondo', keeper: 'rondo' }),
      run({ runId: 'fus-mine', keeper: 'polisher', status: 'failed' }),
    ]

    render(html`<${KeeperFusionRuns} keeperName="polisher" />`, { container })

    const rows = container.querySelectorAll('[data-testid="keeper-fusion-runs"] button')
    expect(rows.length).toBe(1)
    expect(rows[0]?.getAttribute('data-run-id')).toBe('fus-mine')
    expect(container.textContent).toContain('fus-mine')
    expect(container.textContent).toContain('실패')

    if (!rows[0]) throw new Error('expected this keeper run')
    fireEvent.click(rows[0])
    expect(navigate).toHaveBeenCalledWith('fusion', { run_id: 'fus-mine' })
  })

  it('renders nothing when this keeper has no fusion runs', () => {
    fusionRuns.value = [run({ runId: 'fus-rondo', keeper: 'rondo' })]

    render(html`<${KeeperFusionRuns} keeperName="polisher" />`, { container })

    expect(container.querySelector('[data-testid="keeper-fusion-runs"]')).toBeNull()
    expect(container.textContent ?? '').not.toContain('Fusion deliberations')
  })

  it('renders a delayed registry result and stays unmounted after later signal updates', async () => {
    let resolveRecords: (records: FusionRunRecord[]) => void = () => {
      throw new Error('registry fixture was not initialized')
    }
    const pending = new Promise<FusionRunRecord[]>(resolve => { resolveRecords = resolve })
    const refresh = pending.then(records => { fusionRuns.value = records })
    vi.mocked(refreshFusionRuns).mockImplementationOnce(() => refresh)
    const { unmount } = render(html`<${KeeperFusionRuns} keeperName="polisher" />`, { container })
    await waitFor(() => expect(refreshFusionRuns).toHaveBeenCalledTimes(1))
    expect(container.querySelector('[data-testid="keeper-fusion-runs"]')).toBeNull()

    await act(async () => {
      resolveRecords([
        run({ runId: 'delayed-mine', keeper: 'polisher', status: 'running' }),
        run({ runId: 'other-keeper', keeper: 'rondo' }),
      ])
      await refresh
    })
    const row = container.querySelector('[data-run-id="delayed-mine"]')
    expect(row).not.toBeNull()
    expect(row?.textContent).toContain('진행 중')
    expect(container.textContent).not.toContain('other-keeper')
    if (!row) throw new Error('delayed registry result was not rendered')
    fireEvent.click(row)
    expect(navigate).toHaveBeenCalledWith('fusion', { run_id: 'delayed-mine' })

    unmount()
    await act(async () => {
      fusionRuns.value = [run({ runId: 'after-unmount', keeper: 'polisher' })]
    })
    expect(container.childElementCount).toBe(0)
  })

  it('keeps the current keeper identity when an earlier mount request finishes late', async () => {
    let finishEarlier: () => void = () => {
      throw new Error('earlier registry fixture was not initialized')
    }
    const pending = new Promise<void>(resolve => { finishEarlier = resolve })
    const refresh = pending.then(() => {
      fusionRuns.value = [
        run({ runId: 'earlier-keeper-run', keeper: 'polisher' }),
        run({ runId: 'current-keeper-run', keeper: 'rondo' }),
      ]
    })
    vi.mocked(refreshFusionRuns).mockImplementationOnce(() => refresh)
    const { rerender } = render(html`<${KeeperFusionRuns} keeperName="polisher" />`, { container })
    await waitFor(() => expect(refreshFusionRuns).toHaveBeenCalledTimes(1))
    rerender(html`<${KeeperFusionRuns} keeperName="rondo" />`)
    await waitFor(() => expect(refreshFusionRuns).toHaveBeenCalledTimes(2))
    await act(async () => { finishEarlier(); await refresh })
    expect(container.querySelectorAll('[data-run-id]').length).toBe(1)
    expect(container.querySelector('[data-run-id="current-keeper-run"]')).not.toBeNull()
    expect(container.querySelector('[data-run-id="earlier-keeper-run"]')).toBeNull()
  })
})
