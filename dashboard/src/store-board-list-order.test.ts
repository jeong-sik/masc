import { beforeEach, describe, expect, it, vi } from 'vitest'

const apiMocks = vi.hoisted(() => ({
  fetchDashboardMemory: vi.fn(),
}))

vi.mock('./api/dashboard', () => ({
  fetchDashboardMemory: apiMocks.fetchDashboardMemory,
}))

vi.mock('./api/dashboard-execution', () => ({
  fetchDashboardMemory: apiMocks.fetchDashboardMemory,
}))

vi.mock('./api/dashboard-hot', () => ({
  fetchDashboardShell: vi.fn(),
}))

vi.mock('./sse', () => ({
  journal: {
    log: vi.fn(),
  },
}))

const toastMocks = vi.hoisted(() => ({
  showToast: vi.fn(),
}))

vi.mock('./components/common/toast', () => ({
  showToast: toastMocks.showToast,
}))

import {
  boardHasMore,
  boardHearthFilter,
  boardListReadFailed,
  boardLoading,
  boardLoadingMore,
  boardOffset,
  boardPosts,
  boardSearchText,
  boardSortMode,
  boardTotal,
  loadMoreBoardPosts,
  refreshBoard,
} from './store'
import type { BoardPost } from './types'

interface ListAnswer {
  posts: BoardPost[]
  has_more: boolean
  total: number
}

interface PendingListRead {
  hearth: string | undefined
  search: string | undefined
  offset: number
  answer: (data: ListAnswer) => void
  fail: (error: Error) => void
}

function post(id: string): BoardPost {
  return {
    id,
    author: 'keeper',
    title: id,
    body: id,
    meta: null,
    tags: [],
    votes: 0,
    vote_balance: 0,
    comment_count: 0,
    created_at: '2026-11-18T00:00:00Z',
    updated_at: '2026-11-18T00:00:00Z',
    post_kind: 'direct',
    hearth: null,
    visibility: 'public',
    expires_at: null,
    hearth_count: 0,
  }
}

/** Every list read stays open until the test answers it, in the order the test picks. */
function holdListReads(): PendingListRead[] {
  const pending: PendingListRead[] = []
  apiMocks.fetchDashboardMemory.mockImplementation(
    (_sort: string, options: { hearth?: string; search?: string; offset: number }) =>
      new Promise<ListAnswer>((resolve, reject) => {
        pending.push({ hearth: options.hearth, search: options.search, offset: options.offset, answer: resolve, fail: reject })
      }),
  )
  return pending
}

async function readsStarted(pending: PendingListRead[], count: number): Promise<void> {
  await vi.waitFor(() => expect(pending).toHaveLength(count))
}

function pendingRead(pending: PendingListRead[], hearth: string, offset: number): PendingListRead {
  const found = pending.find(read => read.hearth === hearth && read.offset === offset)
  if (!found) throw new Error(`no pending list read for ${hearth} at ${offset}`)
  return found
}

/** Puts the first page of one sub-board on screen, through the same read the app uses. */
async function showSubBoard(
  pending: PendingListRead[],
  hearth: string,
  answer: ListAnswer,
): Promise<void> {
  boardHearthFilter.value = hearth
  const started = pending.length
  const read = refreshBoard()
  await readsStarted(pending, started + 1)
  pending[started]!.answer(answer)
  await read
}

function shownIds(): string[] {
  return boardPosts.value.map(row => row.id)
}

beforeEach(() => {
  vi.clearAllMocks()
  boardPosts.value = []
  boardOffset.value = 0
  boardHasMore.value = true
  boardTotal.value = null
  boardLoading.value = false
  boardLoadingMore.value = false
  boardListReadFailed.value = false
  boardSortMode.value = 'recent'
  boardHearthFilter.value = ''
  boardSearchText.value = ''
})

// #52956: the operator changes the sub-board while the previous list is still loading.
describe('board list reads after the sub-board changes', () => {
  it('keeps the current sub-board when the previous one answers later', async () => {
    const pending = holdListReads()
    boardHearthFilter.value = 'hearth-a'
    const readA = refreshBoard()
    await readsStarted(pending, 1)
    boardHearthFilter.value = 'hearth-b'
    const readB = refreshBoard()
    await readsStarted(pending, 2)

    pendingRead(pending, 'hearth-b', 0).answer({ posts: [post('b1')], has_more: false, total: 1 })
    await readB
    pendingRead(pending, 'hearth-a', 0).answer({ posts: [post('a1'), post('a2')], has_more: true, total: 2 })
    await readA

    expect(shownIds()).toEqual(['b1'])
    expect(boardTotal.value).toBe(1)
    expect(boardHasMore.value).toBe(false)
    expect(boardOffset.value).toBe(1)
    expect(boardLoading.value).toBe(false)
  })

  it('stays loading until the current sub-board answers', async () => {
    const pending = holdListReads()
    boardHearthFilter.value = 'hearth-a'
    const readA = refreshBoard()
    await readsStarted(pending, 1)
    boardHearthFilter.value = 'hearth-b'
    const readB = refreshBoard()
    await readsStarted(pending, 2)

    pendingRead(pending, 'hearth-a', 0).answer({ posts: [post('a1')], has_more: false, total: 1 })
    await readA
    expect(shownIds()).toEqual([])
    expect(boardLoading.value).toBe(true)

    pendingRead(pending, 'hearth-b', 0).answer({ posts: [post('b1')], has_more: false, total: 1 })
    await readB
    expect(shownIds()).toEqual(['b1'])
    expect(boardLoading.value).toBe(false)
  })

  it('does not append a next page that was requested for the previous sub-board', async () => {
    const pending = holdListReads()
    await showSubBoard(pending, 'hearth-a', { posts: [post('a1')], has_more: true, total: 2 })
    const nextPageOfA = loadMoreBoardPosts()
    await readsStarted(pending, 2)

    boardHearthFilter.value = 'hearth-b'
    const readB = refreshBoard()
    await readsStarted(pending, 3)
    pendingRead(pending, 'hearth-b', 0).answer({ posts: [post('b1')], has_more: true, total: 5 })
    await readB
    // The page of A has nothing left to continue, so the next-page control is free again.
    expect(boardLoadingMore.value).toBe(false)

    pendingRead(pending, 'hearth-a', 1).answer({ posts: [post('a2')], has_more: false, total: 2 })
    await nextPageOfA

    expect(shownIds()).toEqual(['b1'])
    expect(boardTotal.value).toBe(5)
    expect(boardHasMore.value).toBe(true)
    expect(boardOffset.value).toBe(1)
    expect(boardLoadingMore.value).toBe(false)
  })

  it('lets the new sub-board load its next page while the old page is still open', async () => {
    const pending = holdListReads()
    await showSubBoard(pending, 'hearth-a', { posts: [post('a1')], has_more: true, total: 2 })
    const nextPageOfA = loadMoreBoardPosts()
    await readsStarted(pending, 2)

    await showSubBoard(pending, 'hearth-b', { posts: [post('b1')], has_more: true, total: 2 })
    const nextPageOfB = loadMoreBoardPosts()
    await readsStarted(pending, 4)
    pendingRead(pending, 'hearth-a', 1).answer({ posts: [post('a2')], has_more: false, total: 2 })
    await nextPageOfA
    expect(shownIds()).toEqual(['b1'])
    expect(boardLoadingMore.value).toBe(true)

    pendingRead(pending, 'hearth-b', 1).answer({ posts: [post('b2')], has_more: false, total: 2 })
    await nextPageOfB
    expect(shownIds()).toEqual(['b1', 'b2'])
    expect(boardLoadingMore.value).toBe(false)
  })

  it('shows the answer for the sub-board the operator came back to, although another sub-board was read later', async () => {
    const pending = holdListReads()
    boardHearthFilter.value = 'hearth-a'
    const firstReadOfA = refreshBoard()
    await readsStarted(pending, 1)
    await showSubBoard(pending, 'hearth-b', { posts: [post('b1')], has_more: false, total: 1 })
    boardHearthFilter.value = 'hearth-a'
    const secondReadOfA = refreshBoard()
    await readsStarted(pending, 3)

    pending[0]!.answer({ posts: [post('a1')], has_more: false, total: 1 })
    await firstReadOfA
    // The read of B started later, but it answers another list: B's posts
    // would stay under the name of A until the second read of A answers.
    expect(shownIds()).toEqual(['a1'])
    expect(boardLoading.value).toBe(true)

    pending[2]!.answer({ posts: [post('a1'), post('a2')], has_more: false, total: 2 })
    await secondReadOfA
    expect(shownIds()).toEqual(['a1', 'a2'])
    expect(boardLoading.value).toBe(false)
  })

  it('does not continue the list on screen once the operator has asked for another', async () => {
    const pending = holdListReads()
    await showSubBoard(pending, 'hearth-a', { posts: [post('a1')], has_more: true, total: 2 })

    // The sub-board changed and its read has not started yet.
    boardHearthFilter.value = 'hearth-b'
    await loadMoreBoardPosts()

    expect(pending).toHaveLength(1)
    expect(shownIds()).toEqual(['a1'])
    expect(boardLoadingMore.value).toBe(false)
  })
})

// #52957: the search text is part of the list a read answers.
describe('board list reads after the search text changes', () => {
  it('asks for the search text and keeps the current text when the replaced one answers later', async () => {
    const pending = holdListReads()
    boardSearchText.value = 'old needle'
    const oldRead = refreshBoard()
    await readsStarted(pending, 1)
    boardSearchText.value = 'new needle'
    const newRead = refreshBoard()
    await readsStarted(pending, 2)
    expect(pending.map(read => read.search)).toEqual(['old needle', 'new needle'])

    pending[0]!.answer({ posts: [post('old-1')], has_more: false, total: 1 })
    await oldRead
    expect(shownIds()).toEqual([])
    expect(boardLoading.value).toBe(true)

    pending[1]!.answer({ posts: [post('new-1')], has_more: false, total: 1 })
    await newRead
    expect(shownIds()).toEqual(['new-1'])
    expect(boardLoading.value).toBe(false)
  })

  it('asks for no search text when nothing is searched', async () => {
    const pending = holdListReads()
    const read = refreshBoard()
    await readsStarted(pending, 1)
    expect(pending[0]!.search).toBeUndefined()
    pending[0]!.answer({ posts: [post('a1')], has_more: false, total: 1 })
    await read
  })

  it('continues a searched list with the same text, and drops the page once the text changes', async () => {
    const pending = holdListReads()
    boardSearchText.value = 'needle'
    const firstPage = refreshBoard()
    await readsStarted(pending, 1)
    pending[0]!.answer({ posts: [post('n1')], has_more: true, total: 2 })
    await firstPage

    const nextPage = loadMoreBoardPosts()
    await readsStarted(pending, 2)
    expect(pending[1]!.search).toBe('needle')
    expect(pending[1]!.offset).toBe(1)
    boardSearchText.value = 'another'
    pending[1]!.answer({ posts: [post('n2')], has_more: false, total: 2 })
    await nextPage

    expect(shownIds()).toEqual(['n1'])
  })
})

// A Board event starts another read of the list that is already loading.
describe('board list reads of the same list that overlap', () => {
  it('shows each answer as it arrives', async () => {
    const pending = holdListReads()
    boardHearthFilter.value = 'hearth-a'
    const first = refreshBoard()
    await readsStarted(pending, 1)
    const second = refreshBoard()
    await readsStarted(pending, 2)

    pending[0]!.answer({ posts: [post('a1')], has_more: false, total: 1 })
    await first
    expect(shownIds()).toEqual(['a1'])
    expect(boardLoading.value).toBe(true)

    pending[1]!.answer({ posts: [post('a2'), post('a1')], has_more: false, total: 2 })
    await second
    expect(shownIds()).toEqual(['a2', 'a1'])
    expect(boardLoading.value).toBe(false)
  })

  it('does not let the read that started earlier replace a later answer', async () => {
    const pending = holdListReads()
    boardHearthFilter.value = 'hearth-a'
    const first = refreshBoard()
    await readsStarted(pending, 1)
    const second = refreshBoard()
    await readsStarted(pending, 2)

    pending[1]!.answer({ posts: [post('a2'), post('a1')], has_more: false, total: 2 })
    await second
    pending[0]!.answer({ posts: [post('a1')], has_more: false, total: 1 })
    await first

    expect(shownIds()).toEqual(['a2', 'a1'])
    expect(boardTotal.value).toBe(2)
  })

  it('appends a next page that answers before the refresh does', async () => {
    const pending = holdListReads()
    await showSubBoard(pending, 'hearth-a', { posts: [post('a1')], has_more: true, total: 2 })
    const nextPage = loadMoreBoardPosts()
    await readsStarted(pending, 2)
    const refresh = refreshBoard()
    await readsStarted(pending, 3)

    pendingRead(pending, 'hearth-a', 1).answer({ posts: [post('a2')], has_more: false, total: 2 })
    await nextPage
    expect(shownIds()).toEqual(['a1', 'a2'])

    pending[2]!.answer({ posts: [post('a1')], has_more: true, total: 2 })
    await refresh
    expect(shownIds()).toEqual(['a1'])
    expect(boardOffset.value).toBe(1)
  })

  it('drops a next page of the list a refresh has replaced', async () => {
    const pending = holdListReads()
    await showSubBoard(pending, 'hearth-a', { posts: [post('a1'), post('a2')], has_more: true, total: 4 })
    const nextPage = loadMoreBoardPosts()
    await readsStarted(pending, 2)
    const refresh = refreshBoard()
    await readsStarted(pending, 3)

    // The refreshed first page starts with a post that was not there before.
    pending[2]!.answer({ posts: [post('a0'), post('a1')], has_more: true, total: 5 })
    await refresh
    expect(boardLoadingMore.value).toBe(false)
    pendingRead(pending, 'hearth-a', 2).answer({ posts: [post('a3'), post('a4')], has_more: false, total: 4 })
    await nextPage

    // Appending the old page would leave a2 out between a1 and a3.
    expect(shownIds()).toEqual(['a0', 'a1'])
    expect(boardOffset.value).toBe(2)
    expect(boardHasMore.value).toBe(true)
  })
})

describe('board list reads that fail', () => {
  const quietly = async (run: () => Promise<void>): Promise<void> => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
    try {
      await run()
    } finally {
      warn.mockRestore()
    }
  }

  it('reports a failed read only for the list the operator is on', () => quietly(async () => {
    const pending = holdListReads()
    boardHearthFilter.value = 'hearth-a'
    const readA = refreshBoard()
    await readsStarted(pending, 1)
    boardHearthFilter.value = 'hearth-b'
    const readB = refreshBoard()
    await readsStarted(pending, 2)

    pendingRead(pending, 'hearth-a', 0).fail(new Error('fixture: read of the previous sub-board failed'))
    await readA
    expect(toastMocks.showToast).not.toHaveBeenCalled()
    expect(boardLoading.value).toBe(true)

    pendingRead(pending, 'hearth-b', 0).fail(new Error('fixture: read of the current sub-board failed'))
    await readB
    expect(toastMocks.showToast).toHaveBeenCalledExactlyOnceWith(expect.any(String), 'error')
    expect(boardLoading.value).toBe(false)
  }))

  it('takes the previous sub-board off the screen when the current one cannot be read', () => quietly(async () => {
    const pending = holdListReads()
    await showSubBoard(pending, 'hearth-a', { posts: [post('a1')], has_more: true, total: 3 })

    boardHearthFilter.value = 'hearth-b'
    const readB = refreshBoard()
    await readsStarted(pending, 2)
    pendingRead(pending, 'hearth-b', 0).fail(new Error('fixture: read of the current sub-board failed'))
    await readB

    // Posts of A under the name of B would read as posts of B.
    expect(shownIds()).toEqual([])
    expect(boardTotal.value).toBeNull()
    expect(toastMocks.showToast).toHaveBeenCalledExactlyOnceWith(expect.any(String), 'error')

    // And there is no list of B to continue, so no page of B is appended to anything.
    await loadMoreBoardPosts()
    expect(pending).toHaveLength(2)
  }))

  it('says the read failed while nothing on screen answers the current sub-board', () => quietly(async () => {
    const pending = holdListReads()
    await showSubBoard(pending, 'hearth-a', { posts: [post('a1')], has_more: false, total: 1 })
    expect(boardListReadFailed.value).toBe(false)

    boardHearthFilter.value = 'hearth-b'
    const readB = refreshBoard()
    await readsStarted(pending, 2)
    pendingRead(pending, 'hearth-b', 0).fail(new Error('fixture: read of the current sub-board failed'))
    await readB
    // The empty list alone would read as a sub-board that has no posts.
    expect(shownIds()).toEqual([])
    expect(boardListReadFailed.value).toBe(true)

    const failedRetry = refreshBoard()
    await readsStarted(pending, 3)
    pending[2]!.fail(new Error('fixture: the retry failed'))
    await failedRetry
    expect(boardListReadFailed.value).toBe(true)

    const retry = refreshBoard()
    await readsStarted(pending, 4)
    pending[3]!.answer({ posts: [post('b1')], has_more: false, total: 1 })
    await retry
    expect(shownIds()).toEqual(['b1'])
    expect(boardListReadFailed.value).toBe(false)
  }))

  it('keeps the list on screen when a refresh of that same list fails', () => quietly(async () => {
    const pending = holdListReads()
    await showSubBoard(pending, 'hearth-a', { posts: [post('a1')], has_more: true, total: 3 })

    const refresh = refreshBoard()
    await readsStarted(pending, 2)
    pending[1]!.fail(new Error('fixture: refresh failed'))
    await refresh

    expect(shownIds()).toEqual(['a1'])
    expect(boardHasMore.value).toBe(true)
    // The list on screen still answers this sub-board; only its refresh failed.
    expect(boardListReadFailed.value).toBe(false)
    expect(toastMocks.showToast).toHaveBeenCalledExactlyOnceWith(expect.any(String), 'error')
  }))

  it('says nothing about an earlier read once a later read of the same list has answered', () => quietly(async () => {
    const pending = holdListReads()
    boardHearthFilter.value = 'hearth-a'
    const first = refreshBoard()
    await readsStarted(pending, 1)
    const second = refreshBoard()
    await readsStarted(pending, 2)

    pending[1]!.answer({ posts: [post('a1')], has_more: false, total: 1 })
    await second
    pending[0]!.fail(new Error('fixture: the earlier read failed'))
    await first

    expect(shownIds()).toEqual(['a1'])
    expect(toastMocks.showToast).not.toHaveBeenCalled()
  }))

  it('says nothing about a next page of a list that is no longer on screen', () => quietly(async () => {
    const pending = holdListReads()
    await showSubBoard(pending, 'hearth-a', { posts: [post('a1')], has_more: true, total: 2 })
    const nextPageOfA = loadMoreBoardPosts()
    await readsStarted(pending, 2)
    await showSubBoard(pending, 'hearth-b', { posts: [post('b1')], has_more: false, total: 1 })

    pendingRead(pending, 'hearth-a', 1).fail(new Error('fixture: next page of the previous sub-board failed'))
    await nextPageOfA

    expect(shownIds()).toEqual(['b1'])
    expect(toastMocks.showToast).not.toHaveBeenCalled()
  }))
})
