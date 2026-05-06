import { h } from 'preact'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import '@testing-library/jest-dom'
import { BoardKarmaPanel } from './board-karma-panel'
import { fetchBoardKarmaLedger } from '../../api/board'

vi.mock('../../api/board', () => ({
  fetchBoardKarmaLedger: vi.fn(),
}))

vi.mock('../../router', () => ({
  navigate: vi.fn(),
}))

const fetchKarmaMock = vi.mocked(fetchBoardKarmaLedger)

describe('BoardKarmaPanel', () => {
  beforeEach(() => {
    fetchKarmaMock.mockResolvedValue({
      count: 2,
      scoring_rule: 'upvote=+1',
      totals: [
        { agent: 'alice', karma: 3 },
        { agent: 'bob', karma: 1 },
      ],
      events: [
        {
          recipient: 'alice',
          voter: 'bob',
          target_kind: 'post',
          target_id: 'post-1',
          delta: 1,
          ts: 1_779_000_000,
          ts_iso: '2026-05-17T06:40:00.000Z',
        },
      ],
    })
  })

  afterEach(() => {
    cleanup()
    vi.clearAllMocks()
  })

  it('renders karma totals and ledger events', async () => {
    render(h(BoardKarmaPanel, null))

    expect(await screen.findByRole('heading', { name: 'Karma ledger' })).toBeInTheDocument()
    expect(screen.getAllByText('alice').length).toBeGreaterThan(0)
    expect(screen.getByText('3')).toBeInTheDocument()
    expect(screen.getByText('post:post-1')).toBeInTheDocument()
    expect(screen.getByText('upvote=+1')).toBeInTheDocument()
    expect(fetchKarmaMock).toHaveBeenCalledWith({ agent: undefined, limit: 50 })
  })

  it('applies agent and limit filters', async () => {
    render(h(BoardKarmaPanel, null))

    await waitFor(() => expect(fetchKarmaMock).toHaveBeenCalledTimes(1))
    fireEvent.input(screen.getByTestId('karma-agent-filter'), { target: { value: ' alice ' } })
    fireEvent.change(screen.getByTestId('karma-event-limit'), { target: { value: '25' } })
    fireEvent.submit(screen.getByTestId('karma-filter-form'))

    await waitFor(() => expect(fetchKarmaMock).toHaveBeenLastCalledWith({
      agent: 'alice',
      limit: 25,
    }))
  })

  it('renders an empty state when the ledger has no rows', async () => {
    fetchKarmaMock.mockResolvedValueOnce({
      count: 0,
      scoring_rule: '',
      totals: [],
      events: [],
    })

    render(h(BoardKarmaPanel, null))

    expect(await screen.findByText('No karma totals.')).toBeInTheDocument()
    expect(screen.getByText('No karma events.')).toBeInTheDocument()
  })
})
