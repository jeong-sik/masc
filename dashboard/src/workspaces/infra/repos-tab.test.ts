import { html } from 'htm/preact'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  authSession,
  resetAuthStateForTests,
  resetObserverStateForTests,
  resourceCache,
} from '../../core'
import { resetShellStateForTests, shellToasts } from '../../shell/shell-state'
import { InfraWorkspace } from './index'
import { REPOS_KEY } from './repos-reads'

const NOW_SEC = Math.floor(Date.now() / 1000)
const DAY_SEC = 86_400

const repoRow = (id: string, over: Record<string, unknown> = {}) => ({
  id, name: id, url: `/srv/${id}`, local_path: `repos/${id}`, resolved_local_path: `/workspace/${id}`,
  default_branch: 'main', status: 'active', auto_sync: true, sync_interval: 300, updated_at: NOW_SEC - 120,
  ...over,
})

/** `alpha` was left in `cloning` a week ago: far past its five-minute interval. */
const REPOS = {
  repositories: [repoRow('beta'), repoRow('alpha', { status: 'cloning', updated_at: NOW_SEC - 7 * DAY_SEC })],
}

const pull = (number: number, over: Record<string, unknown> = {}) => ({
  repo_slug: 'acme/alpha',
  number,
  draft: false,
  checks: 'passing',
  review: 'waiting',
  mergeable: 'mergeable',
  author: 'someone',
  keeper: null,
  title: `pull ${number}`,
  head_oid: 'abc',
  head_review: 'not_reviewed_on_head',
  reviews: { state: 'read', truncated: false, latest: [] },
  ...over,
})

const PULLS = {
  reader: { state: 'ready', keeper: 'pr-updater' },
  repositories_error: null,
  keepers: { state: 'listed' },
  repositories: [
    {
      repository_id: 'alpha', url: 'u', slug: 'acme/alpha',
      pulls: {
        state: 'read', observed_at: NOW_SEC - 60, undecodable: 0,
        pulls: [pull(11), pull(12, { mergeable: 'conflicting', title: 'conflicting change' }), pull(13, { checks: 'failing' })],
      },
    },
    { repository_id: 'beta', url: 'u', slug: null, pulls: { state: 'not_github' } },
  ],
}

const change = (path: string, flags: Record<string, boolean>) => ({
  path, staged: false, unstaged: false, untracked: false, conflicted: false, ...flags,
})

const GIT: Record<string, unknown> = {
  alpha: {
    branch: { head: 'main', upstream: { name: 'origin/main', ahead: 0, behind: 2246 } },
    changes: [change('lib/a.ml', { unstaged: true }), change('notes.txt', { untracked: true })],
    total: 2,
  },
  beta: { branch: { head: 'topic', upstream: null }, changes: [], total: 0 },
}

const NO_ACTIVITY = (repoId: string) => ({
  ok: true,
  data: { repo_id: repoId, window_hours: 24, incomplete: 0, unattributed: 0, changes: [] },
})

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })
}

type Route = (url: URL, method: string) => Response | Promise<Response> | undefined

/** Answers the four reads of the tab; `first` may override or hold any of them. */
function stubServer(first: Route = () => undefined): string[] {
  const seen: string[] = []
  globalThis.fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(String(input), 'http://dashboard.test')
    const method = init?.method ?? 'GET'
    seen.push(`${method} ${url.pathname}${url.search}`)
    const override = await first(url, method)
    if (override) return override
    const repoId = url.searchParams.get('repo_id') ?? ''
    if (url.pathname === '/api/v1/repositories') return jsonResponse(REPOS)
    if (url.pathname === '/api/v1/repositories/pulls') return jsonResponse(PULLS)
    if (url.pathname === '/api/v1/git/status') return jsonResponse(GIT[repoId])
    if (url.pathname === '/api/v1/ide/repository-activity') return jsonResponse(NO_ACTIVITY(repoId))
    return jsonResponse({ error: `unexpected ${method} ${url.pathname}` }, 500)
  }) as typeof fetch
  return seen
}

describe('workspaces/infra repos tab', () => {
  let container: HTMLDivElement
  let originalFetch: typeof globalThis.fetch

  const mount = () => render(
    html`<${InfraWorkspace} subroute="repos" onNavigate=${vi.fn()} onInspect=${vi.fn()} />`,
    container,
  )
  const buttonNamed = (name: string) => Array.from(container.querySelectorAll('button'))
    .find((button) => button.textContent?.trim() === name) as HTMLButtonElement | undefined
  const pullNumbers = () => Array.from(container.querySelectorAll('.rp-pulls tbody tr td:first-child'))
    .map((cell) => cell.textContent?.trim())
  const repoLine = (name: string) => Array.from(container.querySelectorAll('.rp-repos tbody tr'))
    .find((tr) => tr.textContent?.includes(name))
  const shownRepo = () => container.querySelector('.rp-detail h2')?.textContent
  const detailNotices = () => Array.from(container.querySelectorAll('.rp-detail .rp-notice'))
    .map((notice) => notice.textContent?.replace(/\s+/g, ' ').trim())
  const toasts = () => shellToasts.value.map((toast) => `${toast.tone}: ${toast.message}`)
  const conflictChip = () => Array.from(container.querySelectorAll<HTMLButtonElement>('.rp-chip-btn'))
    .find((button) => button.textContent?.includes('충돌'))!
  /** Every read of the selected repository has answered, well or badly. */
  const settled = () => vi.waitFor(() => {
    expect(container.querySelector('.rp-facts')?.getAttribute('aria-busy')).toBe('false')
    expect(container.textContent).not.toContain('불러오는 중…')
    expect(container.textContent).not.toContain('확인 중…')
  })

  beforeEach(() => {
    originalFetch = globalThis.fetch
    resetAuthStateForTests()
    // The repository routes are single_user only, and sync, register and the
    // Keeper write record are admin only.
    authSession.value = {
      kind: 'single_user_local',
      mode: 'single_user',
      tokenPresent: true,
      role: 'admin',
      canTokenAdmin: true,
      authMethods: { google: false, github: false, dev_token: false },
      workspaceId: 'default',
    }
    resetObserverStateForTests()
    resetShellStateForTests()
    resourceCache.clearAll()
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    resourceCache.clearAll()
    globalThis.fetch = originalFetch
    vi.useRealTimers()
    vi.restoreAllMocks()
  })

  it('shows the clone, its distance from the remote, and the open pull requests of the first repository', async () => {
    const seen = stubServer()
    mount()
    await settled()

    const detail = container.querySelector('.rp-detail')?.textContent ?? ''
    expect(detail).toContain('2,246커밋 뒤')
    expect(detail).toContain('origin/main')
    expect(detail).toContain('2파일')
    expect(detail).toContain('수정 1 · 새 파일 1')
    expect(detail).toContain('열린 PR 3')
    expect(detail).toContain('conflicting change')
    // Only the selected repository pays for a git subprocess.
    expect(seen.filter((line) => line.includes('/api/v1/git/status'))).toEqual(['GET /api/v1/git/status?repo_id=alpha'])
  })

  it('keeps the dot between the address and the clone path inside the path', async () => {
    stubServer()
    mount()
    await settled()
    const line = () => container.querySelector('.rp-head-sub')!
    const parts = () => Array.from(line().children).map((part) => part.className)
    // alpha has an address on GitHub: the dot is the first thing in its path.
    await vi.waitFor(() => { expect(parts()).toEqual(['rp-link', 'rp-path']) })
    expect(line().querySelector('.rp-path')?.firstElementChild?.className).toBe('rp-path-sep')
    expect(line().textContent?.replace(/\s+/g, '')).toBe('acme/alpha·/workspace/alpha')

    // beta has none: its path starts the line, with no dot before it.
    buttonNamed('beta')!.click()
    await settled()
    expect(parts()).toEqual(['rp-path'])
    expect(line().querySelector('.rp-path-sep')).toBeNull()
    expect(line().textContent?.replace(/\s+/g, '')).toBe('/workspace/beta')
  })

  it('opens both tables with their order written in the header', async () => {
    stubServer()
    mount()
    await settled()

    const sorted = (scope: string) => {
      const header = container.querySelector(`${scope} th[aria-sort]`)
      return `${header?.textContent?.replace(/\s+/g, ' ').trim()} ${header?.getAttribute('aria-sort')}`
    }
    expect(sorted('.rp-repos')).toBe('저장소▲ ascending')
    expect(sorted('.rp-pulls')).toBe('번호▼ descending')
    expect(pullNumbers()).toEqual(['#13', '#12', '#11'])
  })

  it('says a sync that never finished will not restart by itself', async () => {
    stubServer()
    mount()
    await settled()

    const row = repoLine('alpha')
    expect(row?.textContent).toContain('7일 전 시작')
    expect(row?.querySelector('.rp-chip')?.getAttribute('data-tone')).toBe('warn')
    const notice = container.querySelector('.rp-detail .rp-notice[data-tone="warn"]')?.textContent?.replace(/\s+/g, ' ') ?? ''
    expect(notice).toContain('5분마다 동기화하는 저장소인데 7일째 가져오는 중입니다.')
    expect(notice).toContain('동기화를 누르면 다시 가져옵니다.')
  })

  it('keeps a sync that left the working tree alone beside the repository, and shows the clone it left behind', async () => {
    let release: (response: Response) => void = () => undefined
    let synced = false
    const seen = stubServer((url, method) => {
      if (method === 'POST' && url.pathname === '/api/v1/repositories/alpha/sync') {
        return new Promise<Response>((resolve) => { release = resolve })
      }
      if (!synced) return undefined
      if (url.pathname === '/api/v1/repositories') {
        return jsonResponse({ repositories: [repoRow('beta'), repoRow('alpha', { updated_at: NOW_SEC })] })
      }
      if (url.pathname === '/api/v1/git/status' && url.searchParams.get('repo_id') === 'alpha') {
        return jsonResponse({
          branch: { head: 'main', upstream: { name: 'origin/main', ahead: 0, behind: 0 } },
          changes: [change('lib/a.ml', { unstaged: true })],
          total: 1,
        })
      }
      return undefined
    })
    mount()
    await settled()

    const beforeSync = detailNotices()
    // The button reserves the width of its longer label (`infra.css`).
    expect(buttonNamed('동기화')!.getAttribute('data-wide-label')).toBe('가져오는 중…')
    buttonNamed('동기화')!.click()
    await vi.waitFor(() => {
      expect(buttonNamed('가져오는 중…')?.disabled).toBe(true)
    })
    // The button says the sync is in flight. Nothing below it moves.
    expect(detailNotices()).toEqual(beforeSync)

    synced = true
    release(jsonResponse({
      id: 'alpha', status: 'active', branches: [],
      advance: { state: 'skipped_dirty', staged: 0, unstaged: 1, conflicted: 0 },
    }))
    await vi.waitFor(() => {
      expect(buttonNamed('동기화')?.disabled).toBe(false)
    })

    const result = container.querySelector('.rp-detail .rp-notice[data-tone="warn"]')
    expect(result?.querySelector('[role="status"]')?.textContent)
      .toBe('원격은 가져왔습니다. 커밋 안 된 변경(수정 1)이 있어 작업 트리는 그대로 두었습니다.')
    expect(result?.textContent).toContain('방금 동기화')
    expect(toasts()).toEqual([])
    // The status the sync left behind arrives with the result, so the notice
    // about the stalled sync is already gone.
    expect(container.querySelector('.rp-detail')?.textContent).not.toContain('째 가져오는 중입니다')
    // The clone is read again, once, and the screen shows that answer.
    await vi.waitFor(() => {
      expect(container.querySelector('.rp-facts')?.textContent).toContain('같음')
    })
    await settled()
    expect(seen.filter((line) => line === 'GET /api/v1/git/status?repo_id=alpha')).toHaveLength(2)
  })

  it('says a sync that did what was asked in a toast, and takes away what the one before left', async () => {
    const answers = [
      { state: 'skipped_dirty', staged: 0, unstaged: 1, conflicted: 0 },
      { state: 'advanced', behind: 3 },
    ]
    stubServer((url, method) => (
      method === 'POST' && url.pathname === '/api/v1/repositories/beta/sync'
        ? jsonResponse({ id: 'beta', status: 'active', branches: [], advance: answers.shift() })
        : undefined
    ))
    mount()
    await settled()
    buttonNamed('beta')!.click()
    await settled()
    expect(detailNotices()).toEqual([])

    buttonNamed('동기화')!.click()
    await vi.waitFor(() => {
      expect(detailNotices()).toHaveLength(1)
    })
    expect(toasts()).toEqual([])

    buttonNamed('동기화')!.click()
    await vi.waitFor(() => {
      expect(toasts()).toEqual(['success: beta 동기화 완료. 원격의 새 커밋 3개를 작업 트리에 반영했습니다.'])
    })
    expect(detailNotices()).toEqual([])
  })

  it('keeps a sync that failed beside the repository as an alert', async () => {
    stubServer((url, method) => (
      method === 'POST' && url.pathname === '/api/v1/repositories/beta/sync'
        ? jsonResponse({ error: 'fetch refused' }, 502)
        : undefined
    ))
    mount()
    await settled()
    buttonNamed('beta')!.click()
    await settled()

    buttonNamed('동기화')!.click()
    await vi.waitFor(() => {
      expect(container.querySelector('.rp-detail .rp-notice[data-tone="bad"] [role="alert"]')?.textContent)
        .toBe('동기화 실패: fetch refused')
    })
    expect(toasts()).toEqual([])
  })

  it('says a registered repository in a toast and shows it', async () => {
    let registered = false
    stubServer((url, method) => {
      if (url.pathname === '/api/v1/repositories' && method === 'POST') {
        registered = true
        return jsonResponse({ id: 'gamma' })
      }
      if (url.pathname === '/api/v1/repositories' && registered) {
        return jsonResponse({ repositories: [...REPOS.repositories, repoRow('gamma')] })
      }
      if (url.pathname === '/api/v1/git/status' && url.searchParams.get('repo_id') === 'gamma') {
        return jsonResponse(GIT.beta)
      }
      return undefined
    })
    mount()
    await settled()

    buttonNamed('저장소 추가')!.click()
    await vi.waitFor(() => {
      expect(container.querySelector('.rp-form')).not.toBeNull()
    })
    const [name, address] = Array.from(container.querySelectorAll<HTMLInputElement>('.rp-form input'))
    const type = (input: HTMLInputElement, value: string) => act(() => {
      input.value = value
      input.dispatchEvent(new Event('input', { bubbles: true }))
    })
    await type(name!, 'gamma')
    await type(address!, '/srv/gamma')
    container.querySelector('.rp-form')!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))

    await vi.waitFor(() => {
      expect(shownRepo()).toBe('gamma')
    })
    expect(toasts()).toEqual(["success: 저장소 'gamma' 등록 완료."])
    expect(container.querySelector('.rp-form')).toBeNull()
  })

  it('keeps pull requests readable when the git call fails, and retries on request', async () => {
    let failGit = true
    stubServer((url) => (failGit && url.pathname === '/api/v1/git/status'
      ? jsonResponse({ error: 'git exited 128' }, 500)
      : undefined))
    mount()
    await settled()

    expect(container.querySelector('.rp-facts')?.textContent).toContain('조회 실패')
    expect(container.querySelector('.rp-facts')?.textContent).toContain('git exited 128')
    expect(pullNumbers()).toEqual(['#13', '#12', '#11'])

    failGit = false
    buttonNamed('다시 시도')!.click()
    await vi.waitFor(() => {
      expect(container.querySelector('.rp-facts')?.textContent).toContain('2,246커밋 뒤')
    })
  })

  it('says there is no local clone when the server finds none at the repository path', async () => {
    stubServer((url) => (url.pathname === '/api/v1/git/status'
      ? jsonResponse({ error: 'No Git repository at this workspace root' }, 404)
      : undefined))
    mount()
    await settled()

    const facts = container.querySelector('.rp-facts')?.textContent ?? ''
    expect(facts).toContain('로컬 클론 없음')
    expect(facts).toContain('No Git repository at this workspace root')
    expect(pullNumbers()).toEqual(['#13', '#12', '#11'])
  })

  it('narrows the pull request table with a count chip and releases it on a second press', async () => {
    stubServer()
    mount()
    await settled()

    expect(conflictChip().textContent?.trim()).toBe('충돌 1')
    conflictChip().click()
    await vi.waitFor(() => {
      expect(pullNumbers()).toEqual(['#12'])
    })
    expect(conflictChip().getAttribute('aria-pressed')).toBe('true')

    conflictChip().click()
    await vi.waitFor(() => {
      expect(pullNumbers()).toEqual(['#13', '#12', '#11'])
    })
  })

  it('starts the pull request filter over when another repository is selected', async () => {
    stubServer()
    mount()
    await settled()

    conflictChip().click()
    await vi.waitFor(() => {
      expect(pullNumbers()).toEqual(['#12'])
    })
    buttonNamed('beta')!.click()
    await vi.waitFor(() => {
      expect(shownRepo()).toBe('beta')
    })
    buttonNamed('alpha')!.click()
    await vi.waitFor(() => {
      expect(pullNumbers()).toEqual(['#13', '#12', '#11'])
    })
  })

  it('counts pull requests it could not read beside the ones it could', async () => {
    const [alphaPulls, betaPulls] = PULLS.repositories
    stubServer((url) => (url.pathname === '/api/v1/repositories/pulls'
      ? jsonResponse({
          ...PULLS,
          repositories: [{ ...alphaPulls, pulls: { ...alphaPulls!.pulls, undecodable: 2 } }, betaPulls],
        })
      : undefined))
    mount()
    await settled()

    expect(repoLine('alpha')?.textContent).toContain('읽지 못함 2')
    expect(container.querySelector('.rp-detail')?.textContent).toContain('PR 2건은 응답을 읽지 못해 표에 없습니다.')
  })

  it('reads again an answer that an event outdated while it was in flight', async () => {
    let pullReads = 0
    let releaseSecond: (() => void) | null = null
    stubServer((url) => {
      if (url.pathname !== '/api/v1/repositories/pulls') return undefined
      pullReads += 1
      if (pullReads !== 2) return undefined
      return new Promise<Response>((resolve) => { releaseSecond = () => resolve(jsonResponse(PULLS)) })
    })
    mount()
    await settled()
    expect(pullReads).toBe(1)

    resourceCache.invalidateTopic('repositories')
    await vi.waitFor(() => { expect(releaseSecond).not.toBeNull() })
    // The second read is still out when the next event arrives.
    resourceCache.invalidateTopic('repositories')
    releaseSecond!()

    await vi.waitFor(() => { expect(pullReads).toBe(3) })
    // The third answer is current, so nothing asks a fourth time.
    await settled()
    expect(pullReads).toBe(3)
  })

  it('keeps the repository on screen when one that sorts ahead of it appears', async () => {
    let rows = REPOS.repositories
    stubServer((url) => (url.pathname === '/api/v1/repositories' ? jsonResponse({ repositories: rows }) : undefined))
    mount()
    await settled()
    expect(shownRepo()).toBe('alpha')

    rows = [...rows, repoRow('aardvark')]
    buttonNamed('새로고침')!.click()
    await vi.waitFor(() => {
      expect(repoLine('aardvark')).toBeDefined()
    })
    expect(shownRepo()).toBe('alpha')
  })

  it('follows a clone in progress and stops when it ends', async () => {
    vi.useFakeTimers({ toFake: ['setInterval', 'clearInterval'] })
    let gammaStatus = 'cloning'
    const seen = stubServer((url) => (url.pathname === '/api/v1/repositories'
      ? jsonResponse({
          repositories: [...REPOS.repositories, repoRow('gamma', { status: gammaStatus, updated_at: NOW_SEC - 10 })],
        })
      : undefined))
    const listReads = () => seen.filter((line) => line === 'GET /api/v1/repositories').length
    // A poll that finds the previous read still out joins it, so each step
    // waits for the list to have answered.
    const listAnswered = (reads: number) => vi.waitFor(() => {
      expect(listReads()).toBe(reads)
      expect(resourceCache.peek(REPOS_KEY)).toMatchObject({ kind: 'value', stale: false })
    })
    // The poll timer is set and cleared by an effect, a moment after the
    // render that calls for it. `act` is over when the effects of what it
    // rendered have run: the clock is moved after it.
    await act(() => { mount() })
    await act(async () => { await listAnswered(1) })
    await settled()
    expect(repoLine('gamma')?.textContent).toContain('가져오는 중')

    vi.advanceTimersByTime(5_000)
    await listAnswered(2)

    gammaStatus = 'active'
    await act(async () => {
      vi.advanceTimersByTime(5_000)
      await listAnswered(3)
    })
    expect(repoLine('gamma')?.textContent).not.toContain('가져오는 중')
    vi.advanceTimersByTime(30_000)
    await settled()
    expect(listReads()).toBe(3)
  })

  it('reads the clone of another repository only when it is selected', async () => {
    const seen = stubServer()
    mount()
    await settled()

    buttonNamed('beta')!.click()
    await vi.waitFor(() => {
      expect(shownRepo()).toBe('beta')
    })
    await settled()

    expect(seen).toContain('GET /api/v1/git/status?repo_id=beta')
    const detail = container.querySelector('.rp-detail')?.textContent ?? ''
    expect(detail).toContain('topic')
    expect(detail).toContain('추적 브랜치 없음')
    expect(detail).toContain('깨끗함')
    expect(detail).toContain('GitHub 저장소가 아니어서 PR을 읽지 않습니다.')
  })
})
