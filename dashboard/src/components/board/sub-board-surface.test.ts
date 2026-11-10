import { h } from 'preact'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import '@testing-library/jest-dom'
import { SubBoardSurface } from './sub-board-surface'
import { createSubBoard, deleteSubBoard, fetchSubBoards } from '../../api/board'
import { showToast } from '../common/toast'
import { requestConfirm } from '../common/confirm-dialog'

vi.mock('../../api/board', () => ({
  fetchSubBoards: vi.fn(),
  createSubBoard: vi.fn(),
  deleteSubBoard: vi.fn(),
}))

vi.mock('../common/toast', () => ({
  showToast: vi.fn(),
}))

vi.mock('../common/confirm-dialog', () => ({ requestConfirm: vi.fn() }))

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
    vi.mocked(requestConfirm).mockResolvedValue(true)
  })

  afterEach(() => {
    cleanup()
    vi.clearAllMocks()
  })

  it('renders fetched sub-boards with access and membership state', async () => {
    const { container } = render(h(SubBoardSurface, null))

    expect(await screen.findByText('Operations')).toBeTruthy()
    expect(screen.getByText('/ops')).toBeTruthy()
    expect(screen.getAllByText('Members only').length).toBeGreaterThan(0)
    expect(screen.getByText('2 members')).toBeTruthy()
    expect(screen.getByText('3 posts')).toBeTruthy()
    expect(screen.getByRole('button', { name: '서브보드 열기: Operations' }))
      .toHaveClass('v2-mobile-operator-target')
    expect(container.querySelector('.v2-workspace-surface')).not.toBeNull()
    expect(container.querySelector('.v2-workspace-panel')).not.toBeNull()
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

  it.each([
    { persistence: 'decision_pending', applied: false, deleted: false, detail: 'decision recording is pending' },
    { persistence: 'pending', applied: true, deleted: true, detail: 'source persistence is pending' },
  ] as const)('keeps $persistence visible without reporting success or repeating deletion', async result => {
    vi.mocked(deleteSubBoard).mockResolvedValue(result)
    render(h(SubBoardSurface, null))
    await screen.findByText('Operations')
    if (result.applied) fetchSubBoardsMock.mockResolvedValue([])
    fireEvent.click(screen.getByRole('button', { name: 'Delete sub-board' }))
    await waitFor(() => expect(deleteSubBoard).toHaveBeenCalledTimes(1))
    await waitFor(() => expect(showToast).toHaveBeenCalledWith(expect.any(String), 'warning'))
    expect(showToast).not.toHaveBeenCalledWith('Sub-board deleted', 'success')
    await waitFor(() => expect(fetchSubBoardsMock).toHaveBeenCalledTimes(2))
    const status = screen.getByRole('status', { name: 'Deletion progress for /ops' })
    expect(status).toHaveTextContent('/ops:')
    expect(status).toHaveTextContent('pending')
    if (result.applied) {
      expect(screen.queryByText('Operations')).toBeNull()
      expect(screen.queryByRole('button', { name: 'Delete sub-board' })).toBeNull()
    } else {
      const button = screen.getByRole('button', { name: 'Delete sub-board' })
      expect(button).toBeDisabled()
      fireEvent.click(button)
    }
    expect(deleteSubBoard).toHaveBeenCalledTimes(1)
    expect(requestConfirm).toHaveBeenCalledTimes(1)
  })

  it('reports success only after durable removal', async () => {
    vi.mocked(deleteSubBoard).mockResolvedValue({ persistence: 'durable', applied: true, deleted: true })
    render(h(SubBoardSurface, null))
    await screen.findByText('Operations')
    fetchSubBoardsMock.mockResolvedValue([])
    fireEvent.click(screen.getByRole('button', { name: 'Delete sub-board' }))
    await waitFor(() => expect(showToast).toHaveBeenCalledWith('Sub-board deleted', 'success'))
    await waitFor(() => expect(screen.queryByText('Operations')).toBeNull())
    expect(deleteSubBoard).toHaveBeenCalledTimes(1)
  })

})
