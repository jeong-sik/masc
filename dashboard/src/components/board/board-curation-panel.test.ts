import { h } from 'preact'
import { cleanup, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import '@testing-library/jest-dom'
import { BoardCurationPanel } from './board-curation-panel'
import { fetchBoardCuration } from '../../api/board'

vi.mock('../../api/board', () => ({
  fetchBoardCuration: vi.fn(),
}))

vi.mock('../../router', () => ({
  navigate: vi.fn(),
}))

const fetchBoardCurationMock = vi.mocked(fetchBoardCuration)

describe('BoardCurationPanel', () => {
  beforeEach(() => {
    fetchBoardCurationMock.mockResolvedValue({
      id: 'cu-1',
      generated_at: '2026-05-06T10:00:00.000Z',
      submitted_by: 'keeper-curator',
      model: 'gpt-5',
      summary: 'Two active incidents need review.',
      ordering: ['post-a', 'post-b'],
      highlights: ['post-a'],
      tag_suggestions: [
        { post_id: 'post-a', tags: ['incident', 'ops'], rationale: 'Incident thread' },
      ],
      answer_matches: [
        {
          question_post_id: 'post-question',
          answer_post_id: 'post-answer',
          score: 0.86,
          rationale: 'Same stack trace',
        },
      ],
      health_score: 0.74,
      health_components: [
        { name: 'answer_rate', score: 0.8, weight: 0.25, rationale: 'Most questions have replies' },
      ],
      rationale: 'Prioritize incidents before planning threads.',
      provenance: { run_id: 'curation-run-1' },
    })
  })

  afterEach(() => {
    cleanup()
    vi.clearAllMocks()
  })

  it('renders the latest curation snapshot details', async () => {
    render(h(BoardCurationPanel, null))

    expect(await screen.findByText('Two active incidents need review.')).toBeTruthy()
    expect(screen.getByText(/keeper-curator/)).toBeTruthy()
    expect(screen.getByText('74%')).toBeTruthy()
    expect(screen.getAllByText('post-a').length).toBeGreaterThan(0)
    expect(screen.getByText('incident')).toBeTruthy()
    expect(screen.getByText('post-question')).toBeTruthy()
    expect(screen.getByText('answer_rate')).toBeTruthy()
  })

  it('renders an empty state when no curation snapshot exists', async () => {
    fetchBoardCurationMock.mockResolvedValue(null)

    render(h(BoardCurationPanel, null))

    await waitFor(() => expect(fetchBoardCurationMock).toHaveBeenCalledTimes(1))
    expect(await screen.findByText('No curation snapshot yet.')).toBeTruthy()
  })

  it('renders the fetch error instead of the empty state when loading fails', async () => {
    fetchBoardCurationMock.mockRejectedValue(new Error('network unavailable'))

    render(h(BoardCurationPanel, null))

    expect(await screen.findByRole('alert')).toHaveTextContent('network unavailable')
    expect(screen.queryByText('No curation snapshot yet.')).toBeNull()
  })
})
