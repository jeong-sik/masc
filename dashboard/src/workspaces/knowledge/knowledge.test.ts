import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

vi.mock('uplot', () => {
  class MockUPlot {
    width = 480
    constructor(_opts: unknown, _data: unknown, mount?: HTMLElement) {
      if (mount) {
        const el = document.createElement('div')
        el.className = 'uplot-mock'
        mount.appendChild(el)
      }
    }
    setData(): void {}
    setSize(): void {}
    destroy(): void {}
    static sync(key: string) {
      return { key }
    }
  }
  return { default: MockUPlot }
})
import { authSession, resetAuthStateForTests } from '../../core/auth'
import * as observer from '../../core/observer'
import { resetObserverStateForTests } from '../../core/observer'
import { resourceCache } from '../../core/resource-cache'
import { resetTimeWindowForTests, setTimeWindow } from '../../core/time-window'
import { resolveRoute } from '../../routes/router'
import {
  KnowledgeWorkspace,
  buildMemoryFlowSeries,
  buildMemoryRecoveryPayload,
  buildWorldMemoryDiffUrl,
  decodeWorldMemory,
  foldSuccessionChains,
  isSignalBoardPost,
  partitionReactions,
  type BoardPostItem,
} from './index'

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  })
}

async function flushUi(rounds = 6): Promise<void> {
  for (let i = 0; i < rounds; i++) {
    await new Promise((r) => setTimeout(r, 0))
  }
}

function setMultiAccountSessionForTest(): void {
  authSession.value = {
    kind: 'multi_account_signed_in',
    mode: 'multi_account',
    accountId: 'acc-1',
    email: 'operator@example.com',
    displayName: 'Operator',
    role: 'admin',
    csrfToken: 'csrf-tok-1',
    authMethods: { google: true, github: false, dev_token: false },
    workspaceId: 'default',
  }
}

describe('workspaces/knowledge', () => {
  let container: HTMLDivElement
  const origFetch = globalThis.fetch

  beforeEach(() => {
    resetAuthStateForTests()
    resetObserverStateForTests()
    resetTimeWindowForTests('24h')
    resourceCache.clearAll()
    vi.spyOn(HTMLElement.prototype, 'clientHeight', 'get').mockReturnValue(480)
    vi.spyOn(HTMLElement.prototype, 'clientWidth', 'get').mockReturnValue(600)
    vi.spyOn(HTMLElement.prototype, 'offsetHeight', 'get').mockReturnValue(480)
    vi.spyOn(HTMLElement.prototype, 'offsetWidth', 'get').mockReturnValue(600)
    vi.spyOn(HTMLElement.prototype, 'getBoundingClientRect').mockReturnValue({
      width: 600,
      height: 480,
      top: 0,
      left: 0,
      bottom: 480,
      right: 600,
      x: 0,
      y: 0,
      toJSON() {
        return {}
      },
    } as DOMRect)
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    globalThis.fetch = origFetch
    vi.restoreAllMocks()
    resourceCache.clearAll()
    resetTimeWindowForTests('24h')
    resetAuthStateForTests()
    resetObserverStateForTests()
  })

  it('Board enforces Signal-only default, folds Succession Chains, collapses zero-count emojis behind [+☺], and bounds DOM < 1,200 on 250 posts', async () => {
    // Classifier & folding unit assertions
    expect(isSignalBoardPost({ postKind: 'system', hearth: 'general', title: 'Boot', body: '' })).toBe(false)
    expect(isSignalBoardPost({ postKind: 'direct', hearth: 'verification', title: 'Verify: t1', body: '' })).toBe(false)
    expect(isSignalBoardPost({ postKind: 'direct', hearth: 'engineering', title: 'Proposal A+', body: 'Design' })).toBe(true)

    const p1: BoardPostItem = {
      id: 'p-old', title: 'Old Spec', body: 'v1', author: 'sangsu', hearth: 'arch', postKind: 'direct',
      visibility: 'internal', pinned: false, votes: 2, currentVote: null, commentCount: 0,
      createdAt: '2026-11-23T00:00:00Z', updatedAt: '2026-11-23T00:00:00Z', tags: [],
      reactions: [], supportedReactionEmojis: ['👍', '🔥', '👀'],
      closed: { closedBy: 'sangsu', closedAt: '2026-11-24T00:00:00Z', successorId: 'p-new', summary: 'Superseded by v2' },
      isSignal: true,
    }
    const p2: BoardPostItem = {
      ...p1, id: 'p-new', title: 'New Spec', body: 'v2', closed: null,
      reactions: [
        { emoji: '👍', count: 3, reacted: true },
        { emoji: '🔥', count: 0, reacted: false },
        { emoji: '👀', count: 0, reacted: false },
      ],
    }
    const folded = foldSuccessionChains([p1, p2])
    expect(folded).toHaveLength(1)
    expect(folded[0]!.head.id).toBe('p-new')
    expect(folded[0]!.predecessors.map((x) => x.id)).toEqual(['p-old'])

    const parts = partitionReactions(p2.reactions, p2.supportedReactionEmojis)
    expect(parts.active.map((r) => r.emoji)).toEqual(['👍'])
    expect(parts.collapsedZero).toEqual(['🔥', '👀'])

    // Render 250 posts to verify VirtualList DOM bound & zero-count emoji collapse
    const rawPosts = Array.from({ length: 250 }, (_, i) => ({
      id: `post-${i}`,
      title: i === 0 ? 'Signal Head Post' : `Post #${i}`,
      body: `Body for post ${i}`,
      author: 'code-reviewer-sister',
      hearth: 'engineering',
      post_kind: i === 1 ? 'system' : 'direct',
      votes_up: 4,
      votes_down: 0,
      comment_count: 0,
      created_at: '2026-11-24T05:00:00Z',
      reactions: [
        { emoji: '👍', count: 4, reacted: false },
        { emoji: '🔥', count: 0, reacted: false },
        { emoji: '🎉', count: 0, reacted: false },
        { emoji: '👀', count: 0, reacted: false },
      ],
      supported_reaction_emojis: ['👍', '🔥', '🎉', '👀'],
    }))

    const manyHearths = [
      { name: 'engineering', count: 250 },
      ...Array.from({ length: 12 }, (_, idx) => ({ name: `topic-${idx + 1}`, count: 20 - idx })),
    ]
    const reactCalls: unknown[] = []
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      if (url.startsWith('/api/v1/board/hearths')) return jsonResponse({ hearths: manyHearths })
      if (url.startsWith('/api/v1/board/sub-boards')) return jsonResponse({ sub_boards: [] })
      if (url === '/api/v1/board/reactions' && init?.method === 'POST') {
        reactCalls.push(JSON.parse(String(init.body)))
        return jsonResponse({ target_type: 'post', target_id: 'post-0', user_id: 'op', emoji: '🔥', reacted: true, summary: [] })
      }
      if (url.startsWith('/api/v1/board/post-0')) {
        return jsonResponse({ post: rawPosts[0], comments: [], comment_page: { offset: 0, total: 0 } })
      }
      if (url.startsWith('/api/v1/board')) return jsonResponse({ posts: rawPosts })
      return jsonResponse({})
    }) as typeof fetch

    render(
      html`<${KnowledgeWorkspace} subroute="board" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`,
      container,
    )
    await flushUi()

    // DOM bound < 1,200 nodes even with 250 posts!
    const totalDomNodes = container.querySelectorAll('*').length
    expect(totalDomNodes).toBeLessThan(1200)

    // No redundant in-page L1 sub-tab bar; hearth strip caps to top 6 + select dropdown
    expect(container.querySelector('.kn-subbar')).toBeNull()
    expect(container.querySelectorAll('.kn-hearth-strip .kn-chip')).toHaveLength(7) // '전체 Hearth' + top 6
    expect(container.querySelector('select.kn-hearth-select')).not.toBeNull()

    // Zero-count emojis are collapsed behind [+☺] trigger (only 👍 is inline!)
    const reactionBar = container.querySelector('.kn-reactions')!
    expect(reactionBar.textContent).toContain('👍')
    expect(reactionBar.textContent).toContain('+☺')
    expect(reactionBar.textContent).not.toContain('🔥')
    expect(reactionBar.textContent).not.toContain('🎉')

    // Clicking [+☺] reveals collapsed emojis and sends reaction POST
    const triggerBtn = reactionBar.querySelector('button[aria-label="반응 추가"]') as HTMLButtonElement
    triggerBtn.click()
    await flushUi(2)
    expect(container.querySelector('.kn-react-picker')!.textContent).toContain('🔥')

    const fireBtn = [...container.querySelectorAll('.kn-react-picker button')].find((b) =>
      b.textContent?.trim() === '🔥',
    ) as HTMLButtonElement
    fireBtn.click()
    await flushUi()
    expect(reactCalls).toEqual([{ target_type: 'post', target_id: 'post-0', emoji: '🔥' }])
  })

  it('opens a legacy Board deep link even when the post is outside the current feed', async () => {
    const post = { id: 'archived-1', title: 'Archived post title', body: 'Direct lookup', author: 'librarian' }
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url.startsWith('/api/v1/board?')) {
        return jsonResponse({ posts: [{ ...post, id: 'feed-1', title: 'Recent feed post' }] })
      }
      if (url.startsWith('/api/v1/board/archived-1?')) {
        return jsonResponse({ post, comments: [] })
      }
      return jsonResponse({})
    }) as typeof fetch

    const route = resolveRoute('#board?post=archived-1')
    render(html`<${KnowledgeWorkspace} subroute=${route.subroute} entityId=${route.entityId} onNavigate=${vi.fn()} onInspect=${vi.fn()} />`, container)
    await flushUi()

    expect(container.querySelector('h2.kn-heading')?.textContent).toBe('Archived post title')
  })

  it('Board resets reply draft and parent reply target when switching posts and supports Cmd+Enter reply submit', async () => {
    const commentPosts: unknown[] = []
    const detailReads: string[] = []
    let settleReply!: (response: Response) => void
    const pendingReply = new Promise<Response>((resolve) => { settleReply = resolve })
    const postA = { id: 'post-a', title: 'Post A', body: 'Body A', author: 'sangsu', hearth: 'arch', post_kind: 'direct', votes_up: 1, votes_down: 0, comment_count: 1, created_at: '2026-11-24T05:00:00Z' }
    const postB = { id: 'post-b', title: 'Post B', body: 'Body B', author: 'dreamer', hearth: 'arch', post_kind: 'direct', votes_up: 1, votes_down: 0, comment_count: 0, created_at: '2026-11-24T05:01:00Z' }

    globalThis.fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      if (url === '/api/v1/tools/masc_board_comment' && init?.method === 'POST') {
        commentPosts.push(JSON.parse(String(init.body)))
        return pendingReply
      }
      if (url.startsWith('/api/v1/board/hearths')) return jsonResponse({ hearths: [] })
      if (url.startsWith('/api/v1/board/sub-boards')) return jsonResponse({ sub_boards: [] })
      if (url.startsWith('/api/v1/board/post-a')) {
        return jsonResponse({
          post: postA,
          comments: [{ id: 'cmt-a1', post_id: 'post-a', author: 'sangsu', content: 'First comment', created_at: '2026-11-24T05:05:00Z', votes: 0 }],
        })
      }
      if (url.startsWith('/api/v1/board/post-b')) {
        return jsonResponse({ post: postB, comments: [] })
      }
      if (url.startsWith('/api/v1/board')) return jsonResponse({ posts: [postA, postB] })
      return jsonResponse({})
    }) as typeof fetch

    render(html`<${KnowledgeWorkspace} subroute="board" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`, container)
    await flushUi()

    // Click 답글 on Post A's comment and type a draft
    const replyTargetBtn = [...container.querySelectorAll('button')].find((b) => b.textContent?.trim() === '답글') as HTMLButtonElement
    replyTargetBtn.click()
    await flushUi(2)
    expect(container.textContent).toContain('cmt-a1')

    const textarea = container.querySelector('textarea.kn-textarea--reply') as HTMLTextAreaElement
    textarea.value = 'Draft for post A'
    textarea.dispatchEvent(new Event('input', { bubbles: true }))
    await flushUi(2)

    // Switch to Post B -> replyParentId and replyText MUST reset cleanly
    const postBBtn = [...container.querySelectorAll('button.kn-board-row')].find((b) => b.textContent?.includes('Post B')) as HTMLButtonElement
    postBBtn.click()
    await flushUi()

    expect(container.textContent).not.toContain('cmt-a1')
    const textareaAfter = container.querySelector('textarea.kn-textarea--reply') as HTMLTextAreaElement
    expect(textareaAfter.value).toBe('')

    // Submit reply on Post B with Cmd+Enter (and verify IME composing Cmd+Enter is ignored)
    textareaAfter.value = 'Reply on Post B'
    textareaAfter.dispatchEvent(new Event('input', { bubbles: true }))
    await flushUi(2)
    textareaAfter.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', metaKey: true, isComposing: true, bubbles: true }))
    await flushUi(2)
    expect(commentPosts).toHaveLength(0)

    textareaAfter.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', metaKey: true, bubbles: true }))
    await flushUi()
    expect(commentPosts).toEqual([{ post_id: 'post-b', author: 'operator', content: 'Reply on Post B' }])

    const postARow = [...container.querySelectorAll<HTMLButtonElement>('button.kn-board-row')].find((btn) => btn.textContent?.includes('Post A'))!
    postARow.click()
    await flushUi()
    const newDraft = container.querySelector<HTMLTextAreaElement>('textarea.kn-textarea--reply')!
    newDraft.value = 'Keep this new draft'
    newDraft.dispatchEvent(new Event('input', { bubbles: true }))
    await flushUi()
    const readsBeforeReceipt = detailReads.length
    settleReply(jsonResponse({ ok: true, message: JSON.stringify({ id: 'c-b', post_id: 'post-b' }) }, 201))
    await flushUi()
    expect(newDraft.value).toBe('Keep this new draft')
    expect(detailReads).toHaveLength(readsBeforeReceipt)
  })

  it('Board routes to GET /api/v1/dashboard/board in multi_account_signed_in mode with 0 calls to single-user /api/v1/board*', async () => {
    setMultiAccountSessionForTest()
    const fetchedUrls: string[] = []
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      fetchedUrls.push(url)
      if (url.startsWith('/api/v1/dashboard/board')) {
        return jsonResponse({
          posts: [
            {
              id: 'ma-post-1',
              title: 'Multi-Account Design Sync',
              body: 'Read-only bridge payload',
              author: 'sangsu',
              hearth: 'architecture',
              post_kind: 'direct',
              votes_up: 3,
              votes_down: 0,
              comment_count: 1,
              created_at: '2026-11-24T05:00:00Z',
            },
          ],
        })
      }
      return jsonResponse({ error: 'unexpected route' }, 404)
    }) as typeof fetch

    render(
      html`<${KnowledgeWorkspace} subroute="board" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`,
      container,
    )
    await flushUi()

    expect(fetchedUrls.some((u) => u.startsWith('/api/v1/dashboard/board'))).toBe(true)
    // Zero 404 calls to unmounted single-user routes
    expect(fetchedUrls.some((u) => u.startsWith('/api/v1/board'))).toBe(false)
    expect(container.textContent).toContain('Multi-Account Design Sync')
    expect(container.textContent).toContain('#architecture')
    expect(container.textContent).toContain('/api/v1/dashboard/board')
  })

  it('shows Wiki lint and revision-log failures and recovers on retry', async () => {
    let lintAttempts = 0
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      const envelope = { schema_version: 1, instance_id: 'inst-1', generated_at_unix: 1 }
      if (url.startsWith('/api/v1/wiki/lint')) {
        if (++lintAttempts === 1) return jsonResponse({ error: 'lint denied' }, 403)
        return jsonResponse({ ...envelope, data: { counts: {}, duplicate_title_candidates: [], findings: [] } })
      }
      if (url.startsWith('/api/v1/wiki/log?')) {
        return jsonResponse({ error: 'journal unavailable' }, 404)
      }
      return jsonResponse({
        ...envelope,
        data: {
          pages_total: 0, pages_readable: 0, pages_unreadable: 0,
          pages: [], unreadable_pages: [], tags: [], sources: {},
          lint: { total_findings: 0, counts: {}, log_hole_suppressed: false, orphans: [], duplicate_title_candidates: [], findings: [] },
        },
      })
    }) as typeof fetch

    render(html`<${KnowledgeWorkspace} subroute="wiki" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`, container)
    await flushUi()
    const button = (label: string) => [...container.querySelectorAll('button')].find((b) => b.textContent?.trim().startsWith(label))!
    button('Lint').click()
    await flushUi()
    expect(container.querySelector('[role="alert"]')?.textContent).toContain('lint denied')
    expect(container.textContent).not.toContain('Lint 보고서 불러오는 중…')

    button('다시 검사').click()
    await flushUi()
    expect(container.querySelector('[role="alert"]')).toBeNull()
    expect(container.textContent).toContain('Lint 경고가 없습니다')

    button('Log').click()
    await flushUi()
    expect(container.querySelector('[role="alert"]')?.textContent).toContain('journal unavailable')
    expect(container.textContent).not.toContain('로그 불러오는 중…')
  })

  it('Wiki aborts stale detail fetch on rapid selection switch so an earlier slow response never overwrites current selection', async () => {
    let resolveSlowA!: (resp: Response) => void
    const abortedSignals: string[] = []

    const makePageEnvelope = (slug: string, title: string, body: string) => ({
      schema_version: 1,
      instance_id: 'inst-1',
      generated_at_unix: 1732430000,
      data: {
        page: slug,
        slug,
        file: `${slug}.md`,
        frontmatter: {
          title,
          summary: `${slug} summary`,
          source: 'observation',
          author: 'librarian',
          created: '2026-11-20T00:00:00Z',
          updated: '2026-11-24T05:00:00Z',
          revision: 1,
          tags: [],
        },
        sha256: `sha-${slug}`,
        body_markdown: body,
        outgoing_links: [],
        backlinks: [],
        sources: { references: [], hearsay: [] },
        lint_findings: [],
      },
    })

    globalThis.fetch = vi.fn((input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      if (url.startsWith('/api/v1/wiki?')) {
        return Promise.resolve(jsonResponse({
          schema_version: 1,
          instance_id: 'inst-1',
          generated_at_unix: 1732430000,
          data: {
            pages_total: 2,
            pages_readable: 2,
            pages_unreadable: 0,
            pages: [
              {
                slug: 'page-a', file: 'page-a.md', title: 'Page A', summary: '', source: 'observation',
                author: 'librarian', created: '2026-11-20T00:00:00Z', updated: '2026-11-24T05:00:00Z',
                revision: 1, tags: [], backlink_count: 0, outgoing_link_count: 0, sources_count: 0, hearsay_count: 0, sha256: 'sha-a',
              },
              {
                slug: 'page-b', file: 'page-b.md', title: 'Page B', summary: '', source: 'observation',
                author: 'librarian', created: '2026-11-20T00:00:00Z', updated: '2026-11-24T05:01:00Z',
                revision: 1, tags: [], backlink_count: 0, outgoing_link_count: 0, sources_count: 0, hearsay_count: 0, sha256: 'sha-b',
              },
            ],
            unreadable_pages: [],
            tags: [],
            sources: { observation: 2 },
            lint: { total_findings: 0, counts: {}, log_hole_suppressed: false, orphans: [], duplicate_title_candidates: [], findings: [] },
          },
        }))
      }
      if (url === '/api/v1/wiki/page-a') {
        init?.signal?.addEventListener('abort', () => abortedSignals.push('page-a'))
        return new Promise<Response>((resolve) => {
          resolveSlowA = resolve
        })
      }
      if (url === '/api/v1/wiki/page-b') {
        return Promise.resolve(jsonResponse(makePageEnvelope('page-b', 'Page B', 'Fresh Body B')))
      }
      return Promise.resolve(jsonResponse({}))
    }) as typeof fetch

    render(
      html`<${KnowledgeWorkspace} subroute="wiki" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`,
      container,
    )
    await flushUi(4)

    // Switch immediately to Page B while Page A request is still pending
    const pageBBtn = [...container.querySelectorAll('button.kn-row-btn')].find((b) =>
      b.textContent?.includes('Page B'),
    ) as HTMLButtonElement
    expect(pageBBtn).toBeDefined()
    pageBBtn.click()
    await flushUi(4)

    expect(abortedSignals).toContain('page-a')
    expect(container.textContent).toContain('Fresh Body B')

    // Late resolution of Page A must NOT overwrite Page B
    resolveSlowA(jsonResponse(makePageEnvelope('page-a', 'Page A', 'STALE BODY A')))
    await flushUi(4)
    expect(container.textContent).toContain('Fresh Body B')
    expect(container.textContent).not.toContain('STALE BODY A')
  })

  it('Librarian Wiki recovers from PUT 409 conflict_cas with reload-and-diff', async () => {
    const putBodies: unknown[] = []
    let putCount = 0
    let pageVersion = 1

    const makePage = (rev: number, sha: string, body: string) => ({
      schema_version: 1,
      instance_id: 'inst-1',
      generated_at_unix: 1732430000,
      data: {
        page: 'arch-notes',
        slug: 'arch-notes',
        file: 'arch-notes.md',
        frontmatter: {
          title: 'Architecture Notes',
          summary: 'Core invariants',
          source: 'observation',
          author: 'librarian',
          created: '2026-11-20T00:00:00Z',
          updated: '2026-11-24T05:00:00Z',
          revision: rev,
          tags: ['core'],
        },
        sha256: sha,
        body_markdown: body,
        outgoing_links: [],
        backlinks: [],
        sources: { references: [], hearsay: [] },
        lint_findings: [],
      },
    })

    globalThis.fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      if (url.startsWith('/api/v1/wiki/arch-notes') && init?.method === 'PUT') {
        putCount += 1
        putBodies.push(JSON.parse(String(init.body)))
        if (putCount === 1) {
          pageVersion = 2
          return jsonResponse({ error: { code: 'conflict_cas', message: 'expected_sha256 mismatch' } }, 409)
        }
        return jsonResponse({
          schema_version: 1,
          instance_id: 'inst-1',
          generated_at_unix: 1732430010,
          data: { action: 'updated', slug: 'arch-notes', revision: 3, sha256: 'sha-v3', warnings: [] },
        })
      }
      if (url.startsWith('/api/v1/wiki/arch-notes')) {
        return pageVersion === 1
          ? jsonResponse(makePage(1, 'sha-v1', 'Line 1\nOriginal Line 2'))
          : jsonResponse(makePage(2, 'sha-v2', 'Line 1\nServer Updated Line 2'))
      }
      if (url.startsWith('/api/v1/wiki?')) {
        return jsonResponse({
          schema_version: 1,
          instance_id: 'inst-1',
          generated_at_unix: 1732430000,
          data: {
            pages_total: 1,
            pages_readable: 1,
            pages_unreadable: 0,
            pages: [
              {
                slug: 'arch-notes', file: 'arch-notes.md', title: 'Architecture Notes',
                summary: 'Core invariants', source: 'observation', author: 'librarian',
                created: '2026-11-20T00:00:00Z', updated: '2026-11-24T05:00:00Z',
                revision: 1, tags: ['core'], backlink_count: 0, outgoing_link_count: 0,
                sources_count: 1, hearsay_count: 0, sha256: 'sha-v1',
              },
            ],
            unreadable_pages: [],
            tags: [{ tag: 'core', count: 1 }],
            sources: { observation: 1 },
            lint: { total_findings: 0, counts: {}, log_hole_suppressed: false, orphans: [], duplicate_title_candidates: [], findings: [] },
          },
        })
      }
      return jsonResponse({})
    }) as typeof fetch

    render(
      html`<${KnowledgeWorkspace} subroute="wiki" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`,
      container,
    )
    await flushUi()

    // Enter CAS Editor
    const editBtn = [...container.querySelectorAll('button')].find((b) =>
      b.textContent?.includes('CAS 편집'),
    ) as HTMLButtonElement
    editBtn.click()
    await flushUi(2)

    const textarea = container.querySelector('textarea[aria-label="Markdown 본문 편집기"]') as HTMLTextAreaElement
    textarea.value = 'Line 1\nMy Local Line 2'
    textarea.dispatchEvent(new Event('input', { bubbles: true }))
    await flushUi(2)

    // First PUT sends expected_sha256: 'sha-v1', expected_revision: 1 -> server responds 409 conflict_cas
    const saveBtn = [...container.querySelectorAll('button')].find((b) =>
      b.textContent?.includes('CAS 저장 (PUT)'),
    ) as HTMLButtonElement
    saveBtn.click()
    await flushUi()

    expect(putBodies[0]).toMatchObject({
      expected_sha256: 'sha-v1',
      expected_revision: 1,
      body: 'Line 1\nMy Local Line 2',
    })

    // Conflict recovery UI shows diff between server v2 and local draft
    expect(container.textContent).toContain('409 conflict_cas')
    expect(container.querySelector('.kn-diff-box')!.textContent).toContain('Server Updated Line 2')
    expect(container.querySelector('.kn-diff-box')!.textContent).toContain('My Local Line 2')

    // Click "Rebase & Retry" -> sends new expected_sha256: 'sha-v2', expected_revision: 2
    const rebaseBtn = [...container.querySelectorAll('button')].find((b) =>
      b.textContent?.includes('Rebase & Retry'),
    ) as HTMLButtonElement
    rebaseBtn.click()
    await flushUi()

    expect(putBodies[1]).toMatchObject({
      expected_sha256: 'sha-v2',
      expected_revision: 2,
      body: 'Line 1\nMy Local Line 2',
    })
  })

  it('Lean Artifacts renders HTML inside strict sandbox="" iframe with SHA-256 display', async () => {
    const sha = 'a'.repeat(64)
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url === '/api/v1/published-artifacts') {
        return jsonResponse({
          artifacts: [
            {
              id: 'artifact-0123456789abcdef0123456789abcdef',
              revision: 2,
              title: 'Benchmark Report',
              summary: 'Latency chart',
              format: 'html',
              author: 'sangsu',
              created_at: '2026-11-24T05:00:00Z',
              body: { _blob: { sha256: sha, bytes: 1024 } },
              task_id: null,
              goal_id: null,
            },
          ],
          diagnostics: [],
        })
      }
      if (url.startsWith('/api/v1/published-artifacts/artifact-')) {
        return jsonResponse({
          artifact: {
            id: 'artifact-0123456789abcdef0123456789abcdef',
            revision: 2,
            title: 'Benchmark Report',
            summary: 'Latency chart',
            format: 'html',
            author: 'sangsu',
            created_at: '2026-11-24T05:00:00Z',
            body: { _blob: { sha256: sha, bytes: 1024 } },
            task_id: null,
            goal_id: null,
          },
          content: '<h1>Report</h1><script>alert(1)</script>',
          revisions: [],
        })
      }
      return jsonResponse({})
    }) as typeof fetch

    render(
      html`<${KnowledgeWorkspace} subroute="artifacts" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`,
      container,
    )
    await flushUi()

    const iframe = container.querySelector('iframe.kn-artifact-frame') as HTMLIFrameElement
    expect(iframe).not.toBeNull()
    expect(iframe.getAttribute('sandbox')).toBe('')
    const shaEl = container.querySelector('[data-testid="artifact-sha256"]')
    expect(shaEl).not.toBeNull()
    expect(shaEl?.textContent).toContain(sha)
    expect(container.querySelector('[data-testid="artifact-sha-copy"]')).toBeNull()
    // Secondary actions (SHA-256 복사, 메타데이터) folded into ⋯ PopoverMenu
    container.querySelector<HTMLButtonElement>('[data-testid="artifact-detail-actions"]')!.click()
    await flushUi()
    expect(container.querySelector('[data-testid="artifact-action-copy-sha"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="artifact-action-metadata"]')).not.toBeNull()
  })

  it('World Memory handles MVCC & legacy shapes, passes scope=world synced to timeWindow, shows read-only conflicts, and executes Librarian recovery acts', async () => {
    // 1. Legacy shape vs MVCC DB shape decoding
    const legacyDecoded = decodeWorldMemory({
      ledger_state: 'available',
      inventory: { ledger_sha256: 'leg-sha', claims_count: 1, facts_count: 2, conflicts_count: 0, excluded_count: 0 },
      claims: [],
      active_conflicts: [],
      briefing: { status: 'missing', text: null, source_ids_count: 0, error: null, building_pass: null },
      librarian_writers: { writers: 'none_in_process' },
    })
    expect(legacyDecoded.ok).toBe(true)
    if (legacyDecoded.ok) {
      expect(legacyDecoded.value.sourceKind).toBe('legacy_ledger')
      expect(legacyDecoded.value.worldMvcc).toBeNull()
    }

    // 2. Always includes scope=world
    expect(buildWorldMemoryDiffUrl('24h')).toBe('/api/v1/memory/diff?scope=world&window=24h')
    expect(buildWorldMemoryDiffUrl('30d')).toBe('/api/v1/memory/diff?scope=world&window=30d')

    // 3. All 5 Librarian Recovery Act payloads
    expect(buildMemoryRecoveryPayload({ action: 'resume' })).toEqual({ ok: true, value: { action: 'resume' } })
    expect(buildMemoryRecoveryPayload({ action: 'adopt', observed: 'abc123' })).toEqual({ ok: true, value: { action: 'adopt', observed: 'abc123' } })
    expect(buildMemoryRecoveryPayload({ action: 'restart_reading', observed: 'log-1' })).toEqual({ ok: true, value: { action: 'restart_reading', observed: 'log-1' } })
    expect(buildMemoryRecoveryPayload({ action: 'skip_item', turnLog: 'log-1', line: 42, store: 'ordinary', at: 0 })).toEqual({
      ok: true,
      value: { action: 'skip_item', target: { kind: 'head_item', turn_log: 'log-1', line: 42, store: 'ordinary', at: 0 } },
    })
    expect(buildMemoryRecoveryPayload({ action: 'skip_line', offset: 128 })).toEqual({
      ok: true,
      value: { action: 'skip_line', offset: 128 },
    })

    // 4. Memory Flow series builder
    const flow = buildMemoryFlowSeries({
      window: '24h',
      counts: { totalClaimsNow: 12, added: 3, updated: 0, retracted: 1, incompleteBatches: 0, abortedBatches: 0 },
      retrievalHeat: { hot: 2, warm: 3, cold: 1, neverRetrieved: 6, totalEvents: 10 },
      revisions: [
        { rev: 1, batchId: 'b1', factId: 'f1', recordedAt: '2026-11-24T01:00:00Z', op: 'added' },
        { rev: 2, batchId: 'b1', factId: 'f2', recordedAt: '2026-11-24T01:10:00Z', op: 'added' },
        { rev: 3, batchId: 'b2', factId: 'f3', recordedAt: '2026-11-24T03:00:00Z', op: 'retracted' },
      ],
      added: [],
      updated: [],
      retracted: [],
    })
    expect(flow.added).toEqual([2, 0])
    expect(flow.retracted).toEqual([0, -1])
    expect(flow.netTotal[flow.netTotal.length - 1]).toBe(12)

    // 5. Mounted World Memory UI integration: scope=world sync + conflicts read-only + 1-click recovery act
    const fetchedUrls: string[] = []
    const actPosts: { url: string; body: unknown }[] = []
    let failSevenDayRead!: (response: Response) => void
    let worldAvailable = true

    const mvccWorld = {
      schema_version: 1,
      instance_id: 'inst-1',
      generated_at_unix: 1732430000,
      data: {
        source: 'world_memory_db',
        ledger_state: 'available',
        inventory: { ledger_sha256: 'mvcc-sha-1', claims_count: 1, facts_count: 4, conflicts_count: 1, excluded_count: 0 },
        world_mvcc: { digest_revision: 19, digest_sha256: 'dig-1', edges_count: 8, index_count: 4, canonical_count: 3, wiki_count: 2, artifact_count: 1, resource_count: 0 },
        claims: [
          { claim_id: 'c-1', claim: 'main is squash-only', stage: 'canonical', supporting_keepers: ['sangsu'], support_count: 3, has_source_bound: true },
        ],
        active_conflicts: [
          {
            conflict_id: 'cf-1',
            description: 'Competing port numbers',
            member_count: 2,
            competing_claims: [
              { store_kind: 'source_bound', keeper_id: 'sangsu', path: 'docs/a.md', claim_sha256: 'aaa111', resolved: false, claim: 'Port is 8935' },
              { store_kind: 'ordinary', keeper_id: 'dreamer', path: null, claim_sha256: 'bbb222', resolved: false, claim: 'Port is 8080' },
            ],
          },
        ],
        briefing: { status: 'current', text: 'System healthy.', source_ids_count: 1, error: null, building_pass: null },
        recent_batches: { status: 'available', error: null, last_committed_seq: 10, committed_changes_count: 2, incomplete_batches_count: 0, aborted_batches_count: 0, recent_changes: [] },
        librarian_writers: {
          writers: 'running',
          error: 1,
          warn: 0,
          keepers: [
            {
              keeper: 'sangsu',
              row: {
                state: 'stopped',
                stop: 'snapshot_mismatch',
                available_acts: ['resume', 'adopt'],
                snapshot_file: { sha: 'snapsha999', bytes: 2048 },
              },
            },
          ],
        },
      },
    }

    globalThis.fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      fetchedUrls.push(url)
      if (url.startsWith('/api/v1/memory/world')) {
        return worldAvailable ? jsonResponse(mvccWorld) : jsonResponse({ error: 'world unavailable' }, 500)
      }
      if (url.startsWith('/api/v1/memory/diff')) {
        if (url.includes('window=7d')) return new Promise(resolve => { failSevenDayRead = resolve })
        return jsonResponse({
          schema_version: 1,
          instance_id: 'inst-1',
          generated_at_unix: 1732430000,
          data: {
            scope: { kind: 'world' },
            range: { window: url.includes('7d') ? '7d' : '24h', from_rev: 1, to_rev: 3, from_unix: null, to_unix: null },
            counts: { total_claims_now: 1, added: 1, updated: 0, retracted: 0, incomplete_batches: 0, aborted_batches: 0 },
            retrieval_heat: { hot: 1, warm: 0, cold: 0, never_retrieved: 0, total_events: 1, unreadable_event_lines: 0 },
            revisions: [],
            added: [{ fact_id: 'c-1' }],
            updated: [],
            retracted: [],
            unparseable_timestamps: 0,
          },
        })
      }
      if (url === '/api/v1/keepers/sangsu/memory/act' && init?.method === 'POST') {
        actPosts.push({ url, body: JSON.parse(String(init.body)) })
        return jsonResponse({ outcome: 'acted', store: 'open' })
      }
      return jsonResponse({})
    }) as typeof fetch

    render(
      html`<${KnowledgeWorkspace} subroute="memory" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`,
      container,
    )
    await flushUi()

    expect(fetchedUrls).toContain('/api/v1/memory/diff?scope=world&window=24h')
    expect(container.textContent).toContain('MVCC World DB')
    expect(container.textContent).toContain('Source-Bound')

    // Changing global timeWindow automatically re-fetches /api/v1/memory/diff?scope=world&window=7d
    setTimeWindow('7d')
    await flushUi()
    expect(fetchedUrls).toContain('/api/v1/memory/diff?scope=world&window=7d')
    expect(fetchedUrls.filter(url => url === '/api/v1/memory/world')).toHaveLength(1)
    expect(container.textContent).toContain('7d 메모리 Diff 불러오는 중')
    expect(container.textContent).not.toContain('+1 / ~0 / -0')
    expect(container.textContent).toContain('Source-Bound')
    failSevenDayRead(jsonResponse({ error: 'diff unavailable' }, 500))
    await vi.waitFor(() => expect(container.textContent).toContain('7d 메모리 Diff 조회 실패'))
    expect(container.textContent).toContain('Source-Bound')
    setTimeWindow('24h')
    await flushUi()
    expect(container.textContent).toContain('+1 / ~0 / -0')
    expect(container.textContent).not.toContain('7d 메모리 Diff 조회 실패')

    const refresh = [...container.querySelectorAll('button')].find(b => b.textContent?.trim() === '새로고침')!
    worldAvailable = false
    refresh.click()
    await vi.waitFor(() => expect(container.textContent).toContain('World Memory 조회 실패'))
    expect(container.textContent).toContain('+1 / ~0 / -0')
    expect(container.querySelector('[aria-label="Temporal Memory Diff"]')?.textContent).toContain('fact_id')
    worldAvailable = true
    refresh.click()
    await vi.waitFor(() => expect(container.textContent).toContain('Source-Bound'))

    // Active Conflicts tab shows side-by-side claims + honest read-only notice
    const conflictsTab = [...container.querySelectorAll('button[role="tab"]')].find((b) =>
      b.textContent?.includes('Active Conflicts'),
    ) as HTMLButtonElement
    conflictsTab.click()
    await flushUi(2)
    expect(container.textContent).toContain('읽기 전용 충돌 검사기')
    expect(container.textContent).toContain('Port is 8935')
    expect(container.textContent).toContain('Port is 8080')

    // Librarian Writers tab: 1-click resume & adopt fire exact POST /api/v1/keepers/sangsu/memory/act
    const writersTab = [...container.querySelectorAll('button[role="tab"]')].find((b) =>
      b.textContent?.includes('Librarian Writers'),
    ) as HTMLButtonElement
    writersTab.click()
    await flushUi(2)

    const resumeBtn = [...container.querySelectorAll('button')].find((b) => b.textContent?.trim() === 'resume') as HTMLButtonElement
    resumeBtn.click()
    await flushUi()
    expect(actPosts[0]).toEqual({ url: '/api/v1/keepers/sangsu/memory/act', body: { action: 'resume' } })

    const adoptBtn = [...container.querySelectorAll('button')].find((b) => b.textContent?.trim() === 'adopt') as HTMLButtonElement
    adoptBtn.click()
    await flushUi()
    expect(actPosts[1]).toEqual({
      url: '/api/v1/keepers/sangsu/memory/act',
      body: { action: 'adopt', observed: 'snapsha999' },
    })
  })

  it('keeps the submitted reply visible after a paginated refresh and its Board observer echo', async () => {
    const post = { id: 'p-thread', title: 'Paged thread', body: 'Thread body', author: 'keeper', post_kind: 'direct' }
    const comments = Array.from({ length: 40 }, (_, i) => ({
      id: `c-${i + 1}`, post_id: post.id, parent_id: null as string | null,
      author: 'keeper', content: `existing row ${i + 1}`, created_at: '2026-11-25T01:00:00Z',
    }))
    const newest = { ...comments[0]!, id: 'c-new', parent_id: 'c-1', content: 'New nested reply' }
    const reads: URLSearchParams[] = []
    const scrolled: HTMLElement[] = []
    vi.spyOn(HTMLElement.prototype, 'scrollIntoView').mockImplementation(function (this: HTMLElement) {
      scrolled.push(this)
    })
    const listeners = new Set<observer.ObserverListener>()
    vi.spyOn(observer, 'subscribeObserverFrames').mockImplementation((listener) => {
      listeners.add(listener)
      return () => { listeners.delete(listener) }
    })
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = new URL(String(input), 'http://local')
      if (url.pathname === '/api/v1/tools/masc_board_comment') {
        expect(JSON.parse(String(init?.body))).toMatchObject({
          post_id: post.id, content: newest.content, parent_id: newest.parent_id,
        })
        comments.push(newest)
        return jsonResponse({ ok: true, message: JSON.stringify({
          id: newest.id, post_id: post.id, comment_offset: 40, comments_total: 41,
        }) }, 201)
      }
      if (url.pathname === '/api/v1/board') return jsonResponse({ posts: [post] })
      if (url.pathname === `/api/v1/board/${post.id}`) {
        reads.push(url.searchParams)
        const offset = Number(url.searchParams.get('comment_offset'))
        const rows = comments.slice(offset, offset + 40)
        const focused = comments.find((c) => c.id === url.searchParams.get('comment_focus'))
        return jsonResponse({
          post, comments: rows,
          comment_context: focused && !rows.includes(focused) ? [...rows, focused] : rows,
          comment_page: { offset, returned: rows.length, total: comments.length,
            next_offset: offset + rows.length < comments.length ? offset + rows.length : null },
        })
      }
      return jsonResponse({})
    }) as typeof fetch

    render(html`<${KnowledgeWorkspace} subroute="board" entityId=${post.id} onNavigate=${vi.fn()} onInspect=${vi.fn()} />`, container)
    await flushUi()
    expect(container.querySelectorAll('.kn-comment')).toHaveLength(40)
    const replyButton = [...container.querySelectorAll<HTMLButtonElement>('.kn-comment button')].find((button) => button.textContent?.trim() === '답글')
    replyButton!.click()
    await flushUi()
    const textarea = container.querySelector<HTMLTextAreaElement>('textarea.kn-textarea--reply')!
    textarea.value = newest.content
    textarea.dispatchEvent(new Event('input', { bubbles: true }))
    await flushUi()
    textarea.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', metaKey: true, bubbles: true }))
    await flushUi()
    const visibleReply = () => [...container.querySelectorAll('.kn-comment')].filter((row) => row.textContent?.includes(newest.content))
    expect(visibleReply()).toHaveLength(1)
    expect(scrolled).toContain(visibleReply()[0])
    const readCount = reads.length
    for (const listener of listeners) listener({ event: 'board_comment', id: null, data: { post_id: post.id }, raw: '' })
    await vi.waitFor(() => { expect(reads.length).toBeGreaterThan(readCount) }, { timeout: 2000 })
    await flushUi()
    expect(reads.at(-1)?.get('comment_focus')).toBe(newest.id)
    expect(visibleReply()).toHaveLength(1)
    const more = [...container.querySelectorAll<HTMLButtonElement>('button')].find((button) => button.textContent?.includes('댓글 더 불러오기'))
    more!.click()
    await flushUi()
    expect(reads.at(-1)?.get('comment_offset')).toBe('40')
    expect(visibleReply()).toHaveLength(1)
  })

  it('BoardTab renders @audience targets, feed truncation/filtered notice, and comment_page load-more pagination', async () => {
    const requestedUrls: string[] = []
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      requestedUrls.push(url)
      if (url.startsWith('/api/v1/board/hearths')) return jsonResponse({ hearths: [{ name: 'ops', count: 1 }] })
      if (url.startsWith('/api/v1/board/sub-boards')) return jsonResponse({ sub_boards: [] })
      if (url.startsWith('/api/v1/board/post-aud')) {
        if (url.includes('comment_offset=1')) {
          return jsonResponse({
            id: 'post-aud',
            title: 'Audience Thread',
            body: 'Body',
            author: 'sangsu',
            hearth: 'ops',
            post_kind: 'direct',
            audience: { kind: 'targets', targets: ['code-reviewer'] },
            created_at: '2026-11-25T00:00:00Z',
            updated_at: '2026-11-25T01:00:00Z',
            comment_count: 2,
            comments: [
              { id: 'c-2', post_id: 'post-aud', author: 'code-reviewer', content: 'Second page comment', created_at: '2026-11-25T01:00:00Z', audience: { kind: 'targets', targets: ['sangsu'] } },
            ],
            comment_page: { offset: 1, returned: 1, total: 2, next_offset: null },
          })
        }
        expect(url).toContain('comment_offset=0')
        return jsonResponse({
          id: 'post-aud',
          title: 'Audience Thread',
          body: 'Body',
          author: 'sangsu',
          hearth: 'ops',
          post_kind: 'direct',
          audience: { kind: 'targets', targets: ['code-reviewer'] },
          created_at: '2026-11-25T00:00:00Z',
          updated_at: '2026-11-25T01:00:00Z',
          comment_count: 2,
          comments: [
            { id: 'c-1', post_id: 'post-aud', author: 'dreamer', content: 'First page comment', created_at: '2026-11-25T00:30:00Z' },
          ],
          comment_page: { offset: 0, returned: 1, total: 2, next_offset: 1 },
        })
      }
      if (url.startsWith('/api/v1/board?')) {
        expect(url).toContain('signal_only=true')
        return jsonResponse({
          posts: [
            {
              id: 'post-aud',
              title: 'Audience Thread',
              body: 'Body',
              author: 'sangsu',
              hearth: 'ops',
              post_kind: 'direct',
              audience: { kind: 'targets', targets: ['code-reviewer'] },
              created_at: '2026-11-25T00:00:00Z',
              updated_at: '2026-11-25T01:00:00Z',
              comment_count: 2,
            },
          ],
          has_more: true,
          filtered_out_count: 14,
          signal_scan_truncated: true,
        })
      }
      return jsonResponse({})
    }) as typeof fetch

    render(
      html`<${KnowledgeWorkspace} subroute="board" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`,
      container,
    )
    await flushUi(4)

    expect(container.textContent).toContain('@code-reviewer')
    expect(container.textContent).toContain('신호 스캔 상한에 도달')
    expect(container.textContent).toContain('시스템/비신호 글 14건 숨김')
    expect(container.textContent).toContain('First page comment')

    const loadMoreBtn = [...container.querySelectorAll('button')].find((b) =>
      b.textContent?.includes('댓글 더 불러오기 (1 / 2)'),
    ) as HTMLButtonElement | undefined
    expect(loadMoreBtn).toBeDefined()
    loadMoreBtn!.click()
    await flushUi(4)

    expect(requestedUrls.some((u) => u.includes('comment_offset=1'))).toBe(true)
    expect(container.textContent).toContain('Second page comment')
    expect(container.textContent).toContain('@sangsu')
  })

  it('BoardTab preserves loaded comment range 0-79 across SSE refresh and prevents gapped load-more cursor skips', async () => {
    const post = { id: 'p-paged-race', title: 'Race Post', body: 'Body', author: 'keeper', post_kind: 'direct' }
    const allComments = Array.from({ length: 120 }, (_, i) => ({
      id: `cm-${i}`,
      post_id: post.id,
      parent_id: null as string | null,
      author: 'keeper',
      content: `Comment #${i}`,
      created_at: '2026-11-25T01:00:00Z',
    }))
    const listeners = new Set<observer.ObserverListener>()
    vi.spyOn(observer, 'subscribeObserverFrames').mockImplementation((listener) => {
      listeners.add(listener)
      return () => { listeners.delete(listener) }
    })

    // Enforce the real OCaml server contract (Board_types.Limits.max_comment_page_limit = 100):
    // reject comment_limit outside 1..100 with HTTP 400 and slice by the requested limit.
    // Also hold an offset=80 load-more response across an overlapping SSE refresh.
    let holdOffset80 = false
    let releaseOffset80!: () => void
    const requestedOffsets: number[] = []
    const requestedLimits: number[] = []
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = new URL(String(input), 'http://local')
      if (url.pathname === '/api/v1/board/hearths') return jsonResponse({ hearths: [] })
      if (url.pathname === '/api/v1/board/sub-boards') return jsonResponse({ sub_boards: [] })
      if (url.pathname === '/api/v1/board') return jsonResponse({ posts: [post] })
      if (url.pathname === `/api/v1/board/${post.id}`) {
        const offset = Number(url.searchParams.get('comment_offset') ?? '0')
        const limitRaw = url.searchParams.get('comment_limit')
        const limit = limitRaw === null ? 20 : Number(limitRaw)
        if (!Number.isInteger(limit) || limit < 1 || limit > 100) {
          return new Response(
            JSON.stringify({ error: `comment_limit must be between 1 and 100 (got ${limitRaw})` }),
            { status: 400, headers: { 'content-type': 'application/json' } },
          )
        }
        requestedOffsets.push(offset)
        requestedLimits.push(limit)
        const respond = () => {
          const rows = allComments.slice(offset, offset + limit)
          return jsonResponse({
            post,
            comments: rows,
            comment_page: {
              offset,
              returned: rows.length,
              total: allComments.length,
              next_offset: offset + rows.length < allComments.length ? offset + rows.length : null,
            },
          })
        }
        if (offset === 80 && holdOffset80) {
          holdOffset80 = false
          return new Promise<Response>((resolve) => {
            releaseOffset80 = () => resolve(respond())
          })
        }
        return respond()
      }
      return jsonResponse({})
    }) as typeof fetch

    render(
      html`<${KnowledgeWorkspace} subroute="board" entityId=${post.id} onNavigate=${vi.fn()} onInspect=${vi.fn()} />`,
      container,
    )
    await flushUi(6)
    expect(container.textContent).toContain('댓글 더 불러오기 (40 / 120)')

    // Load page 2 (40..79) -> now 80 comments loaded
    const moreBtn1 = [...container.querySelectorAll<HTMLButtonElement>('button')].find((b) =>
      b.textContent?.includes('댓글 더 불러오기 (40 / 120)'),
    )!
    moreBtn1.click()
    await flushUi(6)
    expect(container.textContent).toContain('댓글 더 불러오기 (80 / 120)')

    // Start loading page 3 (80..119) AND fire an overlapping board_comment SSE refresh
    holdOffset80 = true
    const moreBtn2 = [...container.querySelectorAll<HTMLButtonElement>('button')].find((b) =>
      b.textContent?.includes('댓글 더 불러오기 (80 / 120)'),
    )!
    moreBtn2.click()
    await flushUi(2)
    expect(requestedOffsets).toContain(80)

    for (const listener of listeners) {
      listener({ event: 'board_comment', id: null, data: { post_id: post.id }, raw: '' })
    }
    // Wait for the 450ms SSE debounce + multi-page refresh (0..39 + 40..79) to complete
    await vi.waitFor(
      () => {
        expect(container.textContent).toContain('댓글 더 불러오기 (80 / 120)')
      },
      { timeout: 2500 },
    )
    // Now release the stale overlapping offset=80 response (it was aborted / stale seq):
    // loaded range MUST stay contiguous at 80 / 120 (never drop 40-79 or jump to 120 with a gap!).
    releaseOffset80()
    await flushUi(6)
    expect(container.textContent).toContain('댓글 더 불러오기 (80 / 120)')
    expect(container.textContent).toContain('Comment #79')
    expect(requestedLimits.length).toBeGreaterThan(0)
    expect(requestedLimits.every((l) => l >= 1 && l <= 100)).toBe(true)
  })

  it('BoardTab preserves >400 loaded comments across SSE refresh within server comment_limit <= 100 and retains existing comments on continuation failure', async () => {
    const post = { id: 'p-deep-thread', title: 'Deep Thread', body: 'Body', author: 'keeper', post_kind: 'direct' }
    const allComments = Array.from({ length: 480 }, (_, i) => ({
      id: `deep-${i}`,
      post_id: post.id,
      parent_id: null as string | null,
      author: 'keeper',
      content: `DeepComment #${i}`,
      created_at: '2026-11-25T01:00:00Z',
    }))
    const listeners = new Set<observer.ObserverListener>()
    vi.spyOn(observer, 'subscribeObserverFrames').mockImplementation((listener) => {
      listeners.add(listener)
      return () => { listeners.delete(listener) }
    })

    let failOffset40 = false
    const requestedLimits: number[] = []
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = new URL(String(input), 'http://local')
      if (url.pathname === '/api/v1/board/hearths') return jsonResponse({ hearths: [] })
      if (url.pathname === '/api/v1/board/sub-boards') return jsonResponse({ sub_boards: [] })
      if (url.pathname === '/api/v1/board') return jsonResponse({ posts: [post] })
      if (url.pathname === `/api/v1/board/${post.id}`) {
        const offset = Number(url.searchParams.get('comment_offset') ?? '0')
        const limitRaw = url.searchParams.get('comment_limit')
        const limit = limitRaw === null ? 20 : Number(limitRaw)
        if (!Number.isInteger(limit) || limit < 1 || limit > 100) {
          return new Response(
            JSON.stringify({ error: `comment_limit must be between 1 and 100 (got ${limitRaw})` }),
            { status: 400, headers: { 'content-type': 'application/json' } },
          )
        }
        requestedLimits.push(limit)
        if (offset === 40 && failOffset40) {
          return new Response(JSON.stringify({ error: 'temporary 503 on page 2' }), {
            status: 503,
            headers: { 'content-type': 'application/json' },
          })
        }
        const rows = allComments.slice(offset, offset + limit)
        return jsonResponse({
          post,
          comments: rows,
          comment_page: {
            offset,
            returned: rows.length,
            total: allComments.length,
            next_offset: offset + rows.length < allComments.length ? offset + rows.length : null,
          },
        })
      }
      return jsonResponse({})
    }) as typeof fetch

    render(
      html`<${KnowledgeWorkspace} subroute="board" entityId=${post.id} onNavigate=${vi.fn()} onInspect=${vi.fn()} />`,
      container,
    )
    await flushUi(4)

    // Load 10 extra pages (total 440 / 480 comments > server 100 limit and > previous 400 cap!)
    for (let loaded = 40; loaded < 440; loaded += 40) {
      const btn = [...container.querySelectorAll<HTMLButtonElement>('button')].find((b) =>
        b.textContent?.includes(`댓글 더 불러오기 (${loaded} / 480)`),
      )!
      btn.click()
      await flushUi(3)
    }
    expect(container.textContent).toContain('댓글 더 불러오기 (440 / 480)')
    expect(container.textContent).toContain('DeepComment #439')

    // 1. SSE refresh succeeds across all 11 pages with every request comment_limit <= 100 -> preserves all 440 comments & reading window!
    const requestsBeforeRefresh = requestedLimits.length
    for (const listener of listeners) {
      listener({ event: 'board_comment', id: null, data: { post_id: post.id }, raw: '' })
    }
    await vi.waitFor(
      () => {
        expect(requestedLimits.length).toBeGreaterThanOrEqual(requestsBeforeRefresh + 11)
        expect(container.textContent).toContain('댓글 더 불러오기 (440 / 480)')
        expect(container.textContent).toContain('DeepComment #439')
      },
      { timeout: 3000 },
    )
    const refreshLimits = requestedLimits.slice(requestsBeforeRefresh)
    expect(refreshLimits).toHaveLength(11)
    expect(refreshLimits.every((l) => l >= 1 && l <= 100)).toBe(true)

    // 2. SSE refresh encounters 503 on continuation page (offset=40) -> preserves 440 comments & surfaces error alert!
    failOffset40 = true
    for (const listener of listeners) {
      listener({ event: 'board_comment', id: null, data: { post_id: post.id }, raw: '' })
    }
    await vi.waitFor(
      () => {
        expect(container.textContent).toContain('게시글 상세/댓글 조회 실패')
      },
      { timeout: 3000 },
    )
    expect(container.textContent).toContain('댓글 더 불러오기 (440 / 480)')
    expect(container.textContent).toContain('DeepComment #439')
  })

  it('BoardTab recovers missed comments in the open post detail on observer reconnect and resync without board_comment frames', async () => {
    const post = { id: 'p-reconnect', title: 'Reconnect Thread', body: 'Body', author: 'keeper', post_kind: 'direct' }
    const comments = [
      { id: 'rc-1', post_id: post.id, parent_id: null as string | null, author: 'keeper', content: 'Before disconnect #1', created_at: '2026-11-25T01:00:00Z' },
      { id: 'rc-2', post_id: post.id, parent_id: null as string | null, author: 'keeper', content: 'Before disconnect #2', created_at: '2026-11-25T01:01:00Z' },
    ]
    const reconnectListeners = new Set<() => void>()
    const resyncListeners = new Set<(reason: string) => void>()
    vi.spyOn(observer, 'subscribeObserverReconnect').mockImplementation((listener) => {
      reconnectListeners.add(listener)
      return () => { reconnectListeners.delete(listener) }
    })
    vi.spyOn(observer, 'subscribeObserverResync').mockImplementation((listener) => {
      resyncListeners.add(listener)
      return () => { resyncListeners.delete(listener) }
    })

    globalThis.fetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = new URL(String(input), 'http://local')
      if (url.pathname === '/api/v1/board/hearths') return jsonResponse({ hearths: [] })
      if (url.pathname === '/api/v1/board/sub-boards') return jsonResponse({ sub_boards: [] })
      if (url.pathname === '/api/v1/board') return jsonResponse({ posts: [post] })
      if (url.pathname === `/api/v1/board/${post.id}`) {
        const offset = Number(url.searchParams.get('comment_offset') ?? '0')
        const limitRaw = url.searchParams.get('comment_limit')
        const limit = limitRaw === null ? 20 : Number(limitRaw)
        if (!Number.isInteger(limit) || limit < 1 || limit > 100) {
          return new Response(JSON.stringify({ error: 'Limit_out_of_bounds' }), {
            status: 400,
            headers: { 'content-type': 'application/json' },
          })
        }
        const rows = comments.slice(offset, offset + limit)
        return jsonResponse({
          post,
          comments: rows,
          comment_page: {
            offset,
            returned: rows.length,
            total: comments.length,
            next_offset: offset + rows.length < comments.length ? offset + rows.length : null,
          },
        })
      }
      return jsonResponse({})
    }) as typeof fetch

    render(
      html`<${KnowledgeWorkspace} subroute="board" entityId=${post.id} onNavigate=${vi.fn()} onInspect=${vi.fn()} />`,
      container,
    )
    await flushUi(4)
    expect(container.textContent).toContain('Before disconnect #2')
    expect(container.textContent).not.toContain('Added while disconnected')

    // 1. Comment added while disconnected; no board_comment frame arrives, only reconnect
    comments.push({
      id: 'rc-3',
      post_id: post.id,
      parent_id: null,
      author: 'keeper',
      content: 'Added while disconnected',
      created_at: '2026-11-25T01:02:00Z',
    })
    for (const listener of reconnectListeners) listener()
    await vi.waitFor(
      () => {
        expect(container.textContent).toContain('Added while disconnected')
      },
      { timeout: 2000 },
    )

    // 2. Another comment added across a stream gap; only observer_resync_required fires
    comments.push({
      id: 'rc-4',
      post_id: post.id,
      parent_id: null,
      author: 'keeper',
      content: 'Recovered via observer resync',
      created_at: '2026-11-25T01:03:00Z',
    })
    for (const listener of resyncListeners) listener('stream_gap')
    await vi.waitFor(
      () => {
        expect(container.textContent).toContain('Recovered via observer resync')
      },
      { timeout: 2000 },
    )
  })

  it('uses PopoverMenu for Wiki tag filter, collapses Wiki links & Memory diff JSON, and removes duplicate timeWindow chips in Memory tab', async () => {
    globalThis.fetch = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url.startsWith('/api/v1/wiki?')) {
        return jsonResponse({
          schema_version: 1,
          instance_id: 'inst-1',
          generated_at_unix: 1732430000,
          data: {
            pages_total: 1,
            pages_readable: 1,
            pages_unreadable: 0,
            pages: [
              {
                slug: 'design-notes',
                file: 'design-notes.md',
                title: 'Design Notes',
                summary: 'Summary',
                source: 'observation',
                author: 'sangsu',
                created: '2026-11-25T00:00:00Z',
                updated: '2026-11-26T00:00:00Z',
                revision: 1,
                tags: ['ux', 'dashboard'],
                backlink_count: 1,
                outgoing_link_count: 1,
                sources_count: 1,
                hearsay_count: 0,
                sha256: 'sha-design',
              },
            ],
            unreadable_pages: [],
            tags: [{ tag: 'ux', count: 3 }, { tag: 'dashboard', count: 2 }],
            sources: { observation: 1 },
            lint: { total_findings: 0, counts: {}, log_hole_suppressed: false, orphans: [], duplicate_title_candidates: [], findings: [] },
          },
        })
      }
      if (url.startsWith('/api/v1/wiki/design-notes')) {
        return jsonResponse({
          schema_version: 1,
          instance_id: 'inst-1',
          generated_at_unix: 1732430000,
          data: {
            slug: 'design-notes',
            file: 'design-notes.md',
            sha256: 'sha-design',
            frontmatter: {
              title: 'Design Notes',
              summary: 'Summary',
              source: 'observation',
              revision: 1,
              author: 'sangsu',
              created: '2026-11-25T00:00:00Z',
              updated: '2026-11-26T00:00:00Z',
              tags: ['ux'],
              sources: [],
              hearsay: [],
            },
            body_markdown: '# Hello Wiki',
            backlinks: ['overview'],
            outgoing_links: [{ kind: 'page', target: 'architecture', text: 'Architecture', exists: true }],
            lint_findings: [],
          },
        })
      }
      if (url === '/api/v1/memory/world') {
        return jsonResponse({
          schema_version: 1,
          instance_id: 'inst-1',
          generated_at_unix: 1732430000,
          data: {
            source_kind: 'world_memory_db',
            inventory: { ledger_sha256: 'sha-world', claims_count: 1, facts_count: 1, conflicts_count: 0, excluded_count: 0 },
            claims: [],
            active_conflicts: [],
            briefing: { status: 'current', text: 'Briefing', source_ids_count: 1 },
            writers: { mode: 'running', error_count: 0, warn_count: 0, rows: [] },
          },
        })
      }
      if (url.startsWith('/api/v1/memory/diff')) {
        return jsonResponse({
          schema_version: 1,
          instance_id: 'inst-1',
          generated_at_unix: 1732430000,
          data: {
            range: { window: '24h', from_rev: 1, to_rev: 2, from_unix: null, to_unix: null },
            counts: { added: 1, updated: 0, retracted: 0, incomplete_batches: 0, aborted_batches: 0 },
            retrieval_heat: { hot: 1, warm: 0, cold: 0, never_retrieved: 0 },
            added: [{ claim_id: 'c-1', claim: 'Compact UI saves vertical space' }],
            updated: [],
            retracted: [],
            ticks: [],
          },
        })
      }
      return jsonResponse({})
    }) as typeof fetch

    render(html`<${KnowledgeWorkspace} subroute="wiki" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`, container)
    await flushUi(3)

    // Wiki tags are inside a PopoverMenu, and Backlinks/Outgoing links default collapsed
    const tagTrigger = container.querySelector<HTMLButtonElement>('[data-testid="wiki-tag-filter"]')!
    expect(tagTrigger.textContent).toContain('태그 (2)')
    tagTrigger.click()
    await flushUi()
    expect(container.querySelector('[data-testid="wiki-tag-ux"]')?.getAttribute('role')).toBe('menuitemradio')
    const linksDisclosure = container.querySelector<HTMLDetailsElement>('[data-testid="wiki-links-disclosure"]')
    expect(linksDisclosure).not.toBeNull()
    expect(linksDisclosure?.open).toBe(false)
    expect(linksDisclosure?.querySelector('summary')?.textContent).toContain('Backlinks 1 · Outgoing 1')

    // Memory tab removes duplicate timeWindow chips and collapses Temporal Diff raw JSON
    render(null, container)
    resourceCache.clearAll()
    render(html`<${KnowledgeWorkspace} subroute="memory" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`, container)
    await flushUi(3)

    expect(container.querySelector('[aria-label="전역 시간 창 (timeWindow)"]')).toBeNull()
    const diffTab = [...container.querySelectorAll<HTMLButtonElement>('[role="tab"]')]
      .find((b) => b.textContent?.includes('Temporal Diff'))!
    diffTab.click()
    await flushUi()
    const diffEntry = container.querySelector<HTMLDetailsElement>('[data-testid="memory-diff-entry"]')
    expect(diffEntry).not.toBeNull()
    expect(diffEntry?.open).toBe(false)
    expect(diffEntry?.querySelector('summary')?.textContent).toContain('Compact UI saves vertical space')
  })
})
