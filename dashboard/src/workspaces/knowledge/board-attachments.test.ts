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

  it('uploads attachment in Board post & comment composers, submits ONLY attachment_ids (no conflicting attachments field), and renders inline gallery in post detail', async () => {
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
    let submittedCommentBody: Record<string, unknown> | null = null
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
      if (url.pathname === '/api/v1/tools/masc_board_comment' && init?.method === 'POST') {
        submittedCommentBody = JSON.parse(String(init.body)) as Record<string, unknown>
        return new Response(JSON.stringify({ ok: true, id: 'comment-new' }), {
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

    // Open Create Post form, attach an image via paste
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

    // Blank body + ready attachment MUST remain disabled (server requires non-empty content)
    const postSubmitBtn = view.getByRole('button', { name: '게시' }) as HTMLButtonElement
    expect(postSubmitBtn.disabled).toBe(true)

    // Fill body text and submit post
    const bodyTextarea = createComposer.querySelector('textarea') as HTMLTextAreaElement
    expect(bodyTextarea.placeholder).toContain('필수')
    fireEvent.input(bodyTextarea, { target: { value: '첨부 본문입니다.' } })
    await waitFor(() => {
      expect(postSubmitBtn.disabled).toBe(false)
    })

    fireEvent.click(postSubmitBtn)

    await waitFor(() => {
      expect(submittedPostBody).not.toBeNull()
    })
    expect(submittedPostBody!.attachment_ids).toEqual([ATT_POST.attachment_id])
    expect(submittedPostBody).not.toHaveProperty('attachments')
    expect(JSON.stringify(submittedPostBody)).not.toContain('"data":')

    // Wait for Create Post form to close & busy to clear before exercising Reply form
    await waitFor(() => {
      expect(view.getAllByTestId('attachment-composer')).toHaveLength(1)
      expect((view.getByRole('button', { name: /댓글 파일 첨부/ }) as HTMLButtonElement).disabled).toBe(false)
    })

    // Reply form: blank body + ready attachment stays disabled; non-empty body sends ONLY attachment_ids
    const replyComposer = view.getByTestId('attachment-composer')
    const replyFile = new File([PNG_BYTES], 'reply-shot.png', { type: 'image/png' })
    fireEvent.paste(replyComposer, {
      clipboardData: {
        items: [{ kind: 'file', getAsFile: () => replyFile }],
        files: [replyFile],
      },
    })
    await waitFor(() => {
      expect(replyComposer.querySelector('[data-testid="attachment-chip"]')?.getAttribute('data-status')).toBe('ready')
    })
    const replySubmitBtn = view.getByRole('button', { name: '댓글 등록' }) as HTMLButtonElement
    expect(replySubmitBtn.disabled).toBe(true)

    const replyTextarea = replyComposer.querySelector('textarea') as HTMLTextAreaElement
    expect(replyTextarea.placeholder).toContain('필수')
    fireEvent.input(replyTextarea, { target: { value: '댓글 첨부 확인' } })
    await waitFor(() => {
      expect(replySubmitBtn.disabled).toBe(false)
    })
    fireEvent.click(replySubmitBtn)

    await waitFor(() => {
      expect(submittedCommentBody).not.toBeNull()
    })
    expect(submittedCommentBody!.attachment_ids).toEqual([ATT_POST.attachment_id])
    expect(submittedCommentBody).not.toHaveProperty('attachments')
  })

  it('blocks Board post & comment submit when an attachment failed to upload and cleans up aborted uploads on closing new-post form', async () => {
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

    let postSubmitCalls = 0
    let commentSubmitCalls = 0
    let uploadMode: 'fail' | 'hang' = 'fail'
    let abortSeen = false

    const existingPost = {
      id: 'post-existing',
      title: '기존 게시글',
      body: '본문',
      author: 'keeper-a',
      hearth: 'design',
      post_kind: 'direct',
      is_signal: true,
      votes: 1,
      comment_count: 0,
      created_at: '2026-11-27T01:00:00Z',
      updated_at: '2026-11-27T01:00:00Z',
      attachments: [],
    }

    const fetchMock = vi.fn<typeof fetch>(async (input, init) => {
      const url = new URL(String(input), window.location.origin)
      if (url.pathname === '/api/v1/attachments' && init?.method === 'POST') {
        if (uploadMode === 'hang') {
          return new Promise<Response>((_resolve, reject) => {
            init.signal?.addEventListener('abort', () => {
              abortSeen = true
              reject(new DOMException('Aborted', 'AbortError'))
            })
          })
        }
        return new Response(JSON.stringify({ ok: false, error: 'upload rejected' }), {
          status: 500,
          headers: { 'Content-Type': 'application/json' },
        })
      }
      if (url.pathname === '/api/v1/tools/masc_board_post' && init?.method === 'POST') {
        postSubmitCalls += 1
        return new Response(JSON.stringify({ ok: true, id: 'post-new' }), {
          headers: { 'Content-Type': 'application/json' },
        })
      }
      if (url.pathname === '/api/v1/tools/masc_board_comment' && init?.method === 'POST') {
        commentSubmitCalls += 1
        return new Response(JSON.stringify({ ok: true, id: 'comment-new' }), {
          headers: { 'Content-Type': 'application/json' },
        })
      }
      if (url.pathname === '/api/v1/board/hearths') {
        return new Response(JSON.stringify({ hearths: [] }), { headers: { 'Content-Type': 'application/json' } })
      }
      if (url.pathname === '/api/v1/board/sub-boards') {
        return new Response(JSON.stringify({ sub_boards: [] }), { headers: { 'Content-Type': 'application/json' } })
      }
      if (url.pathname === '/api/v1/board/post-existing') {
        return new Response(JSON.stringify({
          post: existingPost,
          comments: [],
          comment_page: { offset: 0, returned: 0, total: 0, next_offset: null },
        }), { headers: { 'Content-Type': 'application/json' } })
      }
      if (url.pathname === '/api/v1/board') {
        return new Response(JSON.stringify({ posts: [existingPost] }), { headers: { 'Content-Type': 'application/json' } })
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

    await view.findByRole('button', { name: '댓글 등록' })

    // 1. Failed upload blocks Board New Post submit & preserves failed chip
    fireEvent.click(view.getByRole('button', { name: '+ 새 글' }))
    const titleInput = view.getByPlaceholderText('제목') as HTMLInputElement
    fireEvent.input(titleInput, { target: { value: '실패 첨부 글' } })
    const [createComposer, replyComposer] = view.getAllByTestId('attachment-composer') as [HTMLElement, HTMLElement]
    const bodyTextarea = createComposer.querySelector('textarea') as HTMLTextAreaElement
    fireEvent.input(bodyTextarea, { target: { value: '본문 있음' } })

    const badFile = new File([PNG_BYTES], 'bad.png', { type: 'image/png' })
    fireEvent.paste(createComposer, {
      clipboardData: { items: [{ kind: 'file', getAsFile: () => badFile }], files: [badFile] },
    })

    await waitFor(() => {
      expect(createComposer.querySelector('[data-testid="attachment-chip"]')?.getAttribute('data-status')).toBe('error')
    })
    const postSubmitBtn = view.getByRole('button', { name: '게시' }) as HTMLButtonElement
    expect(postSubmitBtn.disabled).toBe(true)
    fireEvent.submit(postSubmitBtn.closest('form')!)
    await waitFor(() => {
      expect(view.container.textContent).toContain('업로드에 실패한 첨부 파일을 재시도하거나 제거한 뒤 게시하세요.')
    })
    expect(postSubmitCalls).toBe(0)
    expect(createComposer.querySelector('[data-testid="attachment-chip"]')?.getAttribute('data-status')).toBe('error')

    // Remove the failed chip so we can test collapsing mid-upload next
    fireEvent.click(view.getByRole('button', { name: 'bad.png 첨부 제거' }))
    await waitFor(() => {
      expect(createComposer.querySelector('[data-testid="attachment-chip"]')).toBeNull()
    })

    // 2. Failed upload blocks Board Comment submit & preserves failed chip
    const replyTextarea = replyComposer.querySelector('textarea') as HTMLTextAreaElement
    fireEvent.input(replyTextarea, { target: { value: '댓글 본문 있음' } })
    const badReplyFile = new File([PNG_BYTES], 'bad-reply.png', { type: 'image/png' })
    fireEvent.paste(replyComposer, {
      clipboardData: { items: [{ kind: 'file', getAsFile: () => badReplyFile }], files: [badReplyFile] },
    })
    await waitFor(() => {
      expect(replyComposer.querySelector('[data-testid="attachment-chip"]')?.getAttribute('data-status')).toBe('error')
    })
    const replySubmitBtn = view.getByRole('button', { name: '댓글 등록' }) as HTMLButtonElement
    expect(replySubmitBtn.disabled).toBe(true)
    fireEvent.submit(replySubmitBtn.closest('form')!)
    await waitFor(() => {
      expect(view.container.textContent).toContain('업로드에 실패한 첨부 파일을 재시도하거나 제거한 뒤 등록하세요.')
    })
    expect(commentSubmitCalls).toBe(0)
    expect(replyComposer.querySelector('[data-testid="attachment-chip"]')?.getAttribute('data-status')).toBe('error')

    // 3. Closing New Post form via header toggle while upload is in-flight cleans up uploading state
    uploadMode = 'hang'
    const slowFile = new File([PNG_BYTES], 'slow.png', { type: 'image/png' })
    fireEvent.paste(createComposer, {
      clipboardData: { items: [{ kind: 'file', getAsFile: () => slowFile }], files: [slowFile] },
    })
    await waitFor(() => {
      expect(createComposer.querySelector('[data-testid="attachment-chip"]')?.getAttribute('data-status')).toBe('uploading')
    })
    expect(postSubmitBtn.disabled).toBe(true)

    // Collapse via header '닫기' button, then reopen '+ 새 글'
    fireEvent.click(view.getByRole('button', { name: '닫기' }))
    await waitFor(() => {
      expect(abortSeen).toBe(true)
    })
    fireEvent.click(view.getByRole('button', { name: '+ 새 글' }))
    const reopenedComposer = view.getAllByTestId('attachment-composer')[0]!
    expect(reopenedComposer.querySelector('[data-testid="attachment-chip"]')).toBeNull()
    expect((view.getByRole('button', { name: '게시' }) as HTMLButtonElement).disabled).toBe(false)
  })
})
