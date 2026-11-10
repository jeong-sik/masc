import { html } from 'htm/preact'
import { render } from 'preact'
import './styles.ts'

const fixtureCase = new URLSearchParams(location.search).get('case')
const ordering = fixtureCase === 'ordering'
const known = fixtureCase === 'known' || ordering
const calls: { method: string; path: string; query: string; body?: unknown }[] = []
const failures: string[] = []
const deliveries: { kind: 'write' | 'batch'; payload: unknown }[] = []
const control = {
  readAvailable: known, count: ordering ? 0 : 1, reacted: !ordering,
  holdBatches: false, pendingBatchCount: 0, pendingWriteCount: 0,
}
let pendingWrite: (() => void) | null = null
const pendingBatches: (() => void)[] = []
const catalog = ['👍', '🔥']
const summaries = () => [{ emoji: '👍', count: control.count, reacted: control.reacted, recent_user_ids: ['fixture-reactor'] }]
// The cached list deliberately contains known-empty data; the viewer's actual
// batch read must still own authority when that newer read fails.
const post = () => ({ id: 'p-reaction-source', author: 'writer', title: '리액션 원본 확인',
  body: '조회가 실패하면 이전 수치는 남기고, 다시 확인한 뒤 조작합니다.',
  post_kind: 'human', votes_up: 0, votes_down: 0, reply_count: 0,
  created_at: 1794283200, updated_at: 1794283200,
  reactions: [], supported_reaction_emojis: catalog })
const dashboardPost = () => ({ ...post(), post_kind: 'direct', tags: [], votes: 0,
  comment_count: 0, created_at: '2026-11-10T04:00:00Z', updated_at: '2026-11-10T04:00:00Z' })
const wirePosts = () => ordering
  ? [post(), { ...post(), id: 'p-other-source', title: '다른 대화', body: '별도의 대화를 표시합니다.' }]
  : [post()]
const dashboardPosts = () => ordering
  ? [dashboardPost(), { ...dashboardPost(), id: 'p-other-source', title: '다른 대화', body: '별도의 대화를 표시합니다.' }]
  : [dashboardPost()]
const response = (payload: unknown, status = 200) => new Response(JSON.stringify(payload), {
  status, headers: { 'content-type': 'application/json' },
})
Object.assign(control, {
  releaseWrite: () => {
    if (!pendingWrite) throw new Error('No pending fixture write')
    const release = pendingWrite
    pendingWrite = null
    release()
  },
  releaseBatches: () => {
    control.holdBatches = false
    for (const release of pendingBatches.splice(0)) release()
    control.pendingBatchCount = 0
  },
})
Object.assign(window, { fixtureCalls: calls, fixtureFailures: failures, fixtureControl: control, fixtureDeliveries: deliveries })
window.addEventListener('error', event => failures.push(event.message))
window.addEventListener('unhandledrejection', event => failures.push(String(event.reason)))
window.fetch = async (input, init) => {
  const url = new URL(typeof input === 'string' ? input : input instanceof Request ? input.url : String(input), location.href)
  const method = init?.method ?? 'GET'
  const body = typeof init?.body === 'string' ? JSON.parse(init.body) : undefined
  calls.push({ method, path: url.pathname, query: url.search, ...(body ? { body } : {}) })
  let payload: unknown
  let status = 200
  if (url.pathname === '/api/v1/board') payload = { posts: wirePosts() }
  else if (url.pathname === '/api/v1/dashboard/board') payload = { posts: dashboardPosts(), has_more: false, total: wirePosts().length }
  else if (url.pathname === '/api/v1/board/hearths') payload = { hearths: [] }
  else if (url.pathname === '/api/v1/board/flairs') payload = { flairs: [] }
  else if (url.pathname === '/api/v1/board/sub-boards') payload = { sub_boards: [] }
  else if (url.pathname === '/api/v1/board/reactions' && method === 'POST') {
    if (ordering) {
      control.pendingWriteCount = 1
      return new Promise<Response>(resolve => {
        pendingWrite = () => {
          control.count = 1
          control.reacted = true
          control.pendingWriteCount = 0
          const payload = {
            target_type: 'post', target_id: body.target_id, user_id: 'fixture-reactor',
            emoji: body.emoji, reacted: true, summary: summaries(),
          }
          deliveries.push({ kind: 'write', payload })
          resolve(response(payload))
        }
      })
    }
    status = 503
    control.readAvailable = false
    payload = { error: 'Synthetic write outcome unavailable' }
  }
  else if (url.pathname === '/api/v1/board/reactions/batch' || url.pathname === '/api/v1/board/reactions') {
    if (!control.readAvailable) { status = 503; payload = { error: 'Synthetic reaction source unavailable' } }
    else payload = url.pathname.endsWith('/batch')
      ? { targets: (url.searchParams.get('target_ids') ?? '').split(',').map(target_id => ({ target_id, reactions: summaries() })), supported_reaction_emojis: catalog }
      : { reactions: summaries(), supported_reaction_emojis: catalog }
    if (url.pathname.endsWith('/batch') && control.holdBatches) {
      const capturedPayload = payload
      control.pendingBatchCount += 1
      return new Promise<Response>(resolve => {
        pendingBatches.push(() => {
          deliveries.push({ kind: 'batch', payload: capturedPayload })
          resolve(response(capturedPayload, status))
        })
      })
    }
  }
  else { status = 500; payload = { error: `Unexpected fixture request: ${method} ${url.pathname}` }; failures.push((payload as { error: string }).error) }
  return response(payload, status)
}
const api = await import('@masc-dashboard/api/board')
const store = await import('@masc-dashboard/store')
const { route } = await import('@masc-dashboard/router')
const { BoardSurface } = await import('@masc-dashboard/components/board/board-surface')
const feed = await api.fetchBoard()
store.boardPosts.value = feed.posts
store.boardLoading.value = false
store.boardHasMore.value = false
store.boardExcludeSystem.value = false
store.boardExcludeAutomation.value = false
store.boardHiddenCategories.value = new Set()
route.value = { tab: 'board', params: {} }
render(html`<main style="margin:24px;max-width:1100px">
  <p>실제 컴포넌트 · 가상 HTTP · ${ordering ? '저장 뒤 도착하는 이전 배치' : known ? '확인된 수치에서 저장 실패와 재조회' : '원본 조회 실패'}</p>
  <section id="feed"><${BoardSurface} /></section>
</main>`, document.getElementById('fixture')!)
document.documentElement.dataset.fixtureReady = 'true'
