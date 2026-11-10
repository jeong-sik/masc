import { html } from 'htm/preact'
import { render } from 'preact'
import './styles.ts'

const known = new URLSearchParams(location.search).get('case') === 'known'
const calls: { method: string; path: string; query: string; body?: unknown }[] = []
const failures: string[] = []
const control = { readAvailable: known, count: 1, reacted: true }
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
Object.assign(window, { fixtureCalls: calls, fixtureFailures: failures, fixtureControl: control })
window.addEventListener('error', event => failures.push(event.message))
window.addEventListener('unhandledrejection', event => failures.push(String(event.reason)))
window.fetch = async (input, init) => {
  const url = new URL(typeof input === 'string' ? input : input instanceof Request ? input.url : String(input), location.href)
  const method = init?.method ?? 'GET'
  const body = typeof init?.body === 'string' ? JSON.parse(init.body) : undefined
  calls.push({ method, path: url.pathname, query: url.search, ...(body ? { body } : {}) })
  let payload: unknown
  let status = 200
  if (url.pathname === '/api/v1/board') payload = { posts: [post()] }
  else if (url.pathname === '/api/v1/dashboard/board') payload = { posts: [dashboardPost()], has_more: false, total: 1 }
  else if (url.pathname === '/api/v1/board/hearths') payload = { hearths: [] }
  else if (url.pathname === '/api/v1/board/flairs') payload = { flairs: [] }
  else if (url.pathname === '/api/v1/board/sub-boards') payload = { sub_boards: [] }
  else if (url.pathname === '/api/v1/board/reactions' && method === 'POST') {
    status = 503
    control.readAvailable = false
    payload = { error: 'Synthetic write outcome unavailable' }
  }
  else if (url.pathname === '/api/v1/board/reactions/batch' || url.pathname === '/api/v1/board/reactions') {
    if (!control.readAvailable) { status = 503; payload = { error: 'Synthetic reaction source unavailable' } }
    else payload = url.pathname.endsWith('/batch')
      ? { targets: [{ target_id: 'p-reaction-source', reactions: summaries() }], supported_reaction_emojis: catalog }
      : { reactions: summaries(), supported_reaction_emojis: catalog }
  }
  else { status = 500; payload = { error: `Unexpected fixture request: ${method} ${url.pathname}` }; failures.push((payload as { error: string }).error) }
  return new Response(JSON.stringify(payload), { status, headers: { 'content-type': 'application/json' } })
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
  <p>실제 컴포넌트 · 가상 HTTP · ${known ? '확인된 수치에서 저장 실패와 재조회' : '원본 조회 실패'}</p>
  <section id="feed"><${BoardSurface} /></section>
</main>`, document.getElementById('fixture')!)
document.documentElement.dataset.fixtureReady = 'true'
