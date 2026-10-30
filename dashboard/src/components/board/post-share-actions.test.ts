import { h } from 'preact'
import '@testing-library/jest-dom/vitest'
import { afterEach, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { PostShareActions } from './post-share-actions'
import { showToast } from '../common/toast'
import type { BoardPost } from '../../types'

vi.mock('../../store', () => ({ keepers: { value: [] } }))
vi.mock('../common/toast', () => ({ showToast: vi.fn() }))

afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
  vi.unstubAllGlobals()
})

it('submits context inference through the API and displays the accepted Keeper', async () => {
  const post: BoardPost = {
    id: 'post-context',
    author: 'requested-keeper',
    author_identity: {
      kind: 'keeper', id: 'requested-keeper', key: 'keeper:requested-keeper',
      display_name: 'Requested Keeper', raw: 'requested-keeper',
    },
    title: 'Context inference',
    body: 'Use the operation accepted by the server.',
    tags: [],
    votes: 0,
    comment_count: 0,
    created_at: '2026-09-20T00:00:00Z',
    updated_at: '2026-09-20T00:00:00Z',
  }
  const fetchMock = vi.fn().mockResolvedValue(new Response(JSON.stringify({
    ok: true,
    operation_id: 'kmsg-context',
    keeper_name: 'accepted-keeper',
    post_id: post.id,
    state: 'queued',
    target_source: 'explicit_target',
  }), { status: 202, headers: { 'Content-Type': 'application/json' } }))
  vi.stubGlobal('fetch', fetchMock)

  render(h(PostShareActions, { post }))
  fireEvent.click(screen.getByTestId('bd-context-infer-post-context'))

  await waitFor(() => {
    expect(showToast).toHaveBeenCalledWith('맥락 추론을 accepted-keeper에게 요청했습니다', 'success')
  })
  const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
  expect(url).toBe('/api/v1/board/context-inference')
  expect(JSON.parse(String(init.body))).toEqual({
    post_id: post.id,
    target_keeper: 'requested-keeper',
  })
  expect(screen.getByTestId('bd-context-infer-post-context')).not.toBeDisabled()
})
