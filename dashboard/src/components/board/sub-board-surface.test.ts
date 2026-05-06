import { h } from 'preact'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import '@testing-library/jest-dom'
import { SubBoardSurface } from './sub-board-surface'
import { createSubBoard, fetchSubBoards } from '../../api/board'

vi.mock('../../api/board', () => ({
  fetchSubBoards: vi.fn(),
  createSubBoard: vi.fn(),
}))

vi.mock('../common/toast', () => ({
  showToast: vi.fn(),
}))

const fetchSubBoardsMock = vi.mocked(fetchSubBoards)
const createSubBoardMock = vi.mocked(createSubBoard)

describe('SubBoardSurface', () => {
  beforeEach(() => {
    fetchSubBoardsMock.mockResolvedValue([
      {
        id: 'sb-1',
        slug: 'ops',
        name: 'Operations',
        description: 'Runtime operator lane',
        owner: 'keeper-owner',
        members: ['keeper-owner', 'keeper-a'],
        access: 'members_only',
        created_at: '2026-05-06T10:00:00.000Z',
        post_count: 3,
      },
    ])
    createSubBoardMock.mockResolvedValue({})
  })

  afterEach(() => {
    cleanup()
    vi.clearAllMocks()
  })

  it('renders fetched sub-boards with access and membership state', async () => {
    render(h(SubBoardSurface, null))

    expect(await screen.findByText('Operations')).toBeTruthy()
    expect(screen.getByText('/ops')).toBeTruthy()
    expect(screen.getAllByText('Members only').length).toBeGreaterThan(0)
    expect(screen.getByText('2 members')).toBeTruthy()
    expect(screen.getByText('3 posts')).toBeTruthy()
  })

  it('creates a sub-board with generated slug and trimmed members', async () => {
    fetchSubBoardsMock
      .mockResolvedValueOnce([])
      .mockResolvedValueOnce([
        {
          id: 'sb-2',
          slug: 'review-lane',
          name: 'Review Lane',
          description: 'PR reviews',
          owner: 'dashboard',
          members: ['keeper-a', 'keeper-b'],
          access: 'owner_only',
          created_at: '2026-05-06T10:00:00.000Z',
          post_count: 0,
        },
      ])

    render(h(SubBoardSurface, null))

    await waitFor(() => expect(fetchSubBoardsMock).toHaveBeenCalledTimes(1))
    fireEvent.input(screen.getByTestId('sub-board-name'), { target: { value: 'Review Lane' } })
    fireEvent.input(screen.getByLabelText('Sub-board description'), { target: { value: 'PR reviews' } })
    fireEvent.change(screen.getByTestId('sub-board-access'), { target: { value: 'owner_only' } })
    fireEvent.input(screen.getByTestId('sub-board-members'), { target: { value: ' keeper-a, , keeper-b ' } })
    fireEvent.click(screen.getByTestId('sub-board-create'))

    await waitFor(() => expect(createSubBoardMock).toHaveBeenCalledWith(
      'review-lane',
      'Review Lane',
      'PR reviews',
      'owner_only',
      ['keeper-a', 'keeper-b'],
    ))
    expect(await screen.findByText('Review Lane')).toBeTruthy()
    expect(screen.getByText('/review-lane')).toBeTruthy()
  })
})
