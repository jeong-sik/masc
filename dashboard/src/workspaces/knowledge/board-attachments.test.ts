// @vitest-environment jsdom

import { cleanup, fireEvent, render, waitFor } from '@testing-library/preact'
import { html } from 'htm/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { AttachmentRef } from '../../api/attachments'
import { authSession, bumpSessionEpoch } from '../../core/auth'
import { resourceCache } from '../../core/resource-cache'
import { BoardTab } from './board-tab'
import { decodeBoardComment, decodeBoardPost } from './types'

const PNG_BYTES = Uint8Array.from(
  atob('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lXcAAAAASUVORK5CYII='),
  (c) => c.charCodeAt(0),
)
const SHA_POST = 'a'.repeat(64)
const ATT_POST: AttachmentRef = {
  id: `att_${SHA_POST}`,
  attachment_id: `att_${SHA_POST}`,
  sha256: SHA_POST,
  url: `/api/v1/attachments/att_${SHA_POST}`,
  mime_type: 'image/png',
  kind: 'image',
  bytes: 3072,
  width: 960,
  height: 540,
  filename: 'board-diagram.png',
  origin: 'user_upload',
}

afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
  resourceCache.clearAll()
})

describe('Board attachments decode, upload-first submit, and inline gallery rendering', () => {
  it('decodes post & comment attachments and drops unsafe external URLs', () => {
    const post = decodeBoardPost({
      id: 'post-att-1',
      title: '디자인 시안',
      body: '이미지 첨부합니다.',
      author: 'operator',
      attachments: [
        ATT_POST,
        { url: 'https://evil.example/a.png', mime_type: 'image/png' },
      ],
    })
    expect(post?.attachments).toHaveLength(1)
    expect(post?.attachments[0]?.attachment_id).toBe(ATT_POST.attachment_id)

    const comment = decodeBoardComment({
      id: 'c-1',
      post_id: 'post-att-1',
      author: 'keeper-a',
      content: '확인했습니다',
      attachments: [ATT_POST],
    })
    expect(comment?.attachments).toHaveLength(1)
  })

  it('uploads attachment in Board composer, submits attachment_ids + attachments, and renders inline gallery in post detail', async () => {
    vi.stubGlobal('IntersectionObserver', undefined)
    authSession.value = {
      kind: 'single_user_local',
      mode: 'single_user',
      role: 'admin',
      tokenPresent: true,
      canTokenAdmin: true,
      authMethods: { google: false, github: false, dev_token: false },
      workspaceId: 'default',
    }
    bumpSessionEpoch()

    let submittedPostBody: Record<string, unknown> | null = null
    const existingPost = {
      id: 'post-existing',
      title: '스크린샷 보고',
      body: '아래 이미지를 참고하세요.',
      author: 'keeper-a',
      hearth: 'design',
      post_kind: 'direct',
      is_signal: true,
      votes: 2,
      comment_count: 1,
      created_at: '2026-11-27T01:00:00Z',
      updated_at: '2026-11-27T01:00:00Z',
      attachments: [ATT_POST],
    }

    const fetchMock = vi.fn<typeof fetch>(async (input, init) => {
      const url = new URL(String(input), window.location.origin)
      if (url.pathname === '/api/v1/attachments' && init?.method === 'POST') {
        return new Response(JSON.stringify({ ok: true, data: ATT_POST }), {
          status: 201,
          headers: { 'Content-Type': 'application/json' },
        })
      }
      if (url.pathname.startsWith('/api/v1/attachments/')) {
        return new Response(PNG_BYTES, { status: 200, headers: { 'Content-Type': 'image/png' } })
      }
      if (url.pathname === '/api/v1/tools/masc_board_post' && init?.method === 'POST') {
        submittedPostBody = JSON.parse(String(init.body)) as Record<string, unknown>
        return new Response(JSON.stringify({ ok: true, id: 'post-new' }), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        })
      }
      if (url.pathname === '/api/v1/board/hearths') {
        return new Response(JSON.stringify({ hearths: [{ name: 'design', count: 1 }] }), {
          headers: { 'Content-Type': 'application/json' },
        })
      }
      if (url.pathname === '/api/v1/board/sub-boards') {
        return new Response(JSON.stringify({ sub_boards: [] }), {
          headers: { 'Content-Type': 'application/json' },
        })
      }
      if (url.pathname === '/api/v1/board/post-existing') {
        return new Response(JSON.stringify({
          post: existingPost,
          comments: [],
          comment_page: { offset: 0, returned: 0, total: 0, next_offset: null },
        }), { headers: { 'Content-Type': 'application/json' } })
      }
      if (url.pathname === '/api/v1/board') {
        return new Response(JSON.stringify({ posts: [existingPost] }), {
          headers: { 'Content-Type': 'application/json' },
        })
      }
      return new Response(JSON.stringify({}), { headers: { 'Content-Type': 'application/json' } })
    })
    vi.stubGlobal('fetch', fetchMock)

    const view = render(html`
      <${BoardTab}
        subroute="board"
        entityId="post-existing"
        onNavigate=${vi.fn()}
        onInspect=${vi.fn()}
      />
    `)

    // Post detail renders inline AttachmentGallery for post.attachments
    await waitFor(() => {
      expect(view.container.querySelector(`[data-attachment-id="${ATT_POST.attachment_id}"]`)).not.toBeNull()
    })

    // Open Create Post form, attach an image via paste, and submit
    fireEvent.click(view.getByRole('button', { name: '+ 새 글' }))
    const titleInput = view.getByPlaceholderText('제목') as HTMLInputElement
    fireEvent.input(titleInput, { target: { value: '첨부 테스트 글' } })

    const composers = view.getAllByTestId('attachment-composer')
    const createComposer = composers[0]!
    const file = new File([PNG_BYTES], 'board-diagram.png', { type: 'image/png' })
    fireEvent.paste(createComposer, {
      clipboardData: {
        items: [{ kind: 'file', getAsFile: () => file }],
        files: [file],
      },
    })

    await waitFor(() => {
      const chip = createComposer.querySelector('[data-testid="attachment-chip"]')
      expect(chip?.getAttribute('data-status')).toBe('ready')
    })

    fireEvent.click(view.getByRole('button', { name: '게시' }))

    await waitFor(() => {
      expect(submittedPostBody).not.toBeNull()
    })
    expect(submittedPostBody!.attachment_ids).toEqual([ATT_POST.attachment_id])
    expect(submittedPostBody!.attachments).toEqual([
      {
        attachment_id: ATT_POST.attachment_id,
        id: ATT_POST.id,
        url: ATT_POST.url,
        mime_type: 'image/png',
        kind: 'image',
        bytes: 3072,
        width: 960,
        height: 540,
        filename: 'board-diagram.png',
      },
    ])
    expect(JSON.stringify(submittedPostBody)).not.toContain('"data":')
  })
})
