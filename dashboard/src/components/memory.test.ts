import { h } from 'preact'
import { render, screen } from '@testing-library/preact'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { Memory } from './memory'
import { boardPosts, boardLoading, boardSortMode, boardExcludeSystem, boardExcludeAutomation, boardAuthorFilter } from '../store'
import { route } from '../router'

// Ensure jest-dom matchers are available
import '@testing-library/jest-dom'

// Mock dependencies
vi.mock('../store', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../store')>()
  return {
    ...actual,
    refreshBoard: vi.fn(),
  }
})

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

// memory-state re-exports from store; Vitest needs this mock so the
// component's transitive import resolves to the mocked signals above.
vi.mock('./memory-state', async () => {
  const actual = await vi.importActual<Record<string, unknown>>('./memory-state')
  const store = await vi.importMock<typeof import('../store')>('../store')
  return {
    ...actual,
    ...store,
    votePost: vi.fn(),
    deleteBoardPost: vi.fn(),
    fetchBoardPost: vi.fn(),
    commentPost: vi.fn(),
    createPost: vi.fn(),
  }
})

describe('Memory Component', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    boardPosts.value = []
    boardLoading.value = false
    boardSortMode.value = 'recent'
    boardExcludeSystem.value = true
    boardExcludeAutomation.value = false
    boardAuthorFilter.value = ''
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
  
  it('renders a list of direct posts', () => {
    boardPosts.value = [
      {
        id: 'post-1',
        title: 'Test Post',
        body: 'Hello world',
        author: 'direct-agent',
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        comment_count: 0,
        votes: 0,
        post_kind: 'direct',
      }
    ] as any
    render(h(Memory, null))
    expect(screen.getByText('Test Post')).toBeInTheDocument()
    expect(screen.getByText(/현재 목록은 직접 작성 글만 있어서/)).toBeInTheDocument()
    expect(screen.getByText(/직접 작성 글 \(1\)/)).toBeInTheDocument()
  })

  it('separates automation posts into the autonomy section', () => {
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
    expect(screen.getByText(/자동화 글 \(1\)/)).toBeInTheDocument()
    expect(screen.getByText('Automation Post')).toBeInTheDocument()
  })

  it('hides system posts by default and reports the hidden count', () => {
    boardPosts.value = [
      {
        id: 'post-system',
        title: 'System Post',
        body: 'ops',
        author: 'keeper-alert-bot',
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        comment_count: 0,
        votes: 0,
        post_kind: 'system',
      },
    ] as any
    render(h(Memory, null))
    expect(screen.queryByText('System Post')).not.toBeInTheDocument()
    expect(screen.getByText(/시스템 0/)).toBeInTheDocument()
  })
})
