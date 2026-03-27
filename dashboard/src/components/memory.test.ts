import { h } from 'preact'
import { render, screen } from '@testing-library/preact'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { Memory } from './memory'
import { boardPosts, boardLoading, boardSortMode, boardExcludeSystem, boardExcludeAutomation } from '../store'
import { route } from '../router'

// Ensure jest-dom matchers are available
import '@testing-library/jest-dom'

// Mock dependencies
vi.mock('../store', () => ({
  boardPosts: { value: [] },
  boardLoading: { value: false },
  boardSortMode: { value: 'recent' },
  boardExcludeSystem: { value: false },
  boardExcludeAutomation: { value: false },
  lastBoardRefreshAt: { value: 0 },
  refreshBoard: vi.fn(),
}))

vi.mock('../router', () => ({
  route: { value: { params: {} } },
  navigate: vi.fn(),
  navigateToPost: vi.fn(),
}))

vi.mock('../api', () => ({
  fetchBoardPost: vi.fn(),
  votePost: vi.fn(),
  commentPost: vi.fn(),
  createPost: vi.fn(),
}))

vi.mock('../api/actions', () => ({
  deleteBoardPost: vi.fn(),
}))

describe('Memory Component', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    boardPosts.value = []
    boardLoading.value = false
    boardSortMode.value = 'recent'
    boardExcludeSystem.value = false
    boardExcludeAutomation.value = false
    route.value = { params: {} } as any
  })

  it('renders empty state when there are no posts', () => {
    render(h(Memory, null))
    expect(screen.getByText(/아직 게시글이 없습니다/)).toBeInTheDocument()
  })

  it('renders loading state when loading', () => {
    boardLoading.value = true
    render(h(Memory, null))
    expect(screen.getByText(/메모리 피드 불러오는 중/)).toBeInTheDocument()
  })
  
  it('renders a list of human posts', () => {
    boardPosts.value = [
      {
        id: 'post-1',
        title: 'Test Post',
        body: 'Hello world',
        author: 'human-agent',
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        comment_count: 0,
        votes: 0,
        post_kind: 'human',
      }
    ] as any
    render(h(Memory, null))
    expect(screen.getByText('Test Post')).toBeInTheDocument()
  })

  it('hides automation posts when the automation filter is enabled', () => {
    boardExcludeAutomation.value = true
    boardPosts.value = [
      {
        id: 'post-automation',
        title: 'Automation Post',
        body: 'noise',
        author: 'dm-keeper',
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        comment_count: 0,
        votes: 0,
        post_kind: 'automation',
      },
    ] as any
    render(h(Memory, null))
    expect(screen.queryByText('Automation Post')).not.toBeInTheDocument()
  })
})
