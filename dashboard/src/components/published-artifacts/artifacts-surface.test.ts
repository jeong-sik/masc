import { html } from 'htm/preact'
import { render, fireEvent, cleanup, waitFor, within, act } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { get, post, currentStoredTokenRevision } from '../../api/core'
import { route, navigate } from '../../router'
import { ArtifactsSurface } from './artifacts-surface'
import { copyToClipboard } from '../common/copyable-code'

const authOwner = vi.hoisted(() => ({ change: undefined as ((epoch: number) => void) | undefined }))

vi.mock('../../router', async () => {
  const { signal } = await import('@preact/signals')
  const route = signal({ tab: 'workspace', params: {} as Record<string, string>, postId: null })
  return { route, navigate: vi.fn((tab: string, params: Record<string, string>) => { route.value = { tab, params, postId: null } }) }
})
vi.mock('../../api/core', () => ({
  get: vi.fn(), post: vi.fn(), currentStoredTokenRevision: vi.fn(() => 0),
  ApiRequestError: class extends Error { status = 404 },
}))
vi.mock('../../api/token-revision', async () => {
  const { signal } = await import('@preact/signals')
  const revision = signal(0)
  authOwner.change = epoch => { revision.value = epoch }
  return { storedTokenRevision: revision }
})
vi.mock('../common/markdown', () => ({ Markdown: ({ text }: { text: string }) => html`<div data-markdown>${text}</div>` }))
vi.mock('../common/copyable-code', () => ({ copyToClipboard: vi.fn() }))

const firstId = `artifact-${'a'.repeat(32)}`
const secondId = `artifact-${'b'.repeat(32)}`
const first = { id: firstId, revision: 2, title: '주간 조사 보고서', summary: '표와 근거를 정리했습니다.',
  format: 'markdown', author: 'researcher', created_at: '2026-10-19T01:00:00Z', task_id: 'task-42', goal_id: null,
  body: { sha256: 'a'.repeat(64) },
  url: `/dashboard/#/workspace?section=artifacts&artifact=${firstId}` }
const second = { ...first, id: secondId, title: '동작하는 차트', summary: 'HTML 결과물', author: 'designer', format: 'html' }
const old = { ...first, revision: 1, title: '조사 초안' }
const document = { artifact: first, content: '# 보고서\r\n한글과 😀', revisions: [first, old] }

beforeEach(() => {
  vi.clearAllMocks()
  vi.mocked(post).mockReset()
  vi.mocked(currentStoredTokenRevision).mockReturnValue(0)
  authOwner.change!(0)
  vi.mocked(copyToClipboard).mockResolvedValue(true)
  route.value = { tab: 'workspace', params: { section: 'artifacts' }, postId: null }
  vi.mocked(get).mockImplementation(async path => {
    if (path === '/api/v1/published-artifact-checks') return { checks: [], diagnostics: [] }
    if (path === '/api/v1/published-artifacts') return { artifacts: [first, second], diagnostics: [] }
    if (path.includes('?revision=1')) return { ...document, artifact: old, content: '# 이전 원본' }
    if (path.includes(secondId)) return { artifact: second, content: '<button onclick="this.textContent=2">1</button>', revisions: [second] }
    return document
  })
})
afterEach(cleanup)

describe('artifact library user flow', () => {
  it('confirms only an explicit exact-version action and shares the returned CAS identity when unchecking', async () => {
    const fallback = vi.mocked(get).getMockImplementation()!
    const prior = { id: firstId, revision: 1, body_sha256: first.body.sha256, checked: true,
      change_id: `check-${'b'.repeat(32)}`, changed_by: 'previous-human', changed_at: '2026-10-19T01:00:00Z' }
    let checks = [prior]
    vi.mocked(get).mockImplementation(async (path, options) => path === '/api/v1/published-artifact-checks'
      ? { checks, diagnostics: [] } : path === '/api/v1/published-artifacts'
        ? { artifacts: [{ ...first, created_at: new Date().toISOString() }], diagnostics: [] } : fallback(path, options))
    vi.mocked(post).mockImplementation(async (path, body) => {
      expect(path).toBe('/api/v1/published-artifact-checks')
      const payload = body as { checked: boolean; expected_change_id: string | null }
      const check = { ...prior, revision: 2, checked: payload.checked,
        change_id: `check-${(payload.checked ? 'c' : 'd').repeat(32)}`, changed_by: 'shared-human' }
      checks = [prior, check]
      return { check }
    })
    route.value = { tab: 'workspace', params: { section: 'artifacts', artifact: firstId }, postId: null }
    const view = render(html`<${ArtifactsSurface} />`)
    const reader = within(await view.findByRole('dialog'))
    const unchecked = await reader.findByRole('button', { name: '○ 미확인' })
    expect(await view.findByText('오늘 미확인 1개')).toBeTruthy()
    expect(vi.mocked(post)).not.toHaveBeenCalled()
    fireEvent.click(unchecked)
    expect(await reader.findByRole('button', { name: '✓ 확인함' })).toBeTruthy()
    expect(await view.findByText('오늘 미확인 0개')).toBeTruthy()
    expect(vi.mocked(post)).toHaveBeenLastCalledWith('/api/v1/published-artifact-checks', {
      id: firstId, revision: 2, body_sha256: first.body.sha256, checked: true, expected_change_id: null,
    })
    fireEvent.click(reader.getByRole('button', { name: '✓ 확인함' }))
    expect(await reader.findByRole('button', { name: '○ 미확인' })).toBeTruthy()
    expect(await view.findByText('오늘 미확인 1개')).toBeTruthy()
    expect(vi.mocked(post)).toHaveBeenLastCalledWith('/api/v1/published-artifact-checks', {
      id: firstId, revision: 2, body_sha256: first.body.sha256, checked: false, expected_change_id: `check-${'c'.repeat(32)}`,
    })
    expect(checks.find(check => check.revision === 1)?.checked).toBe(true)
  })

  it('keeps corrupt confirmation inventory unknown and refuses unchecked counts or writes', async () => {
    const fallback = vi.mocked(get).getMockImplementation()!
    vi.mocked(get).mockImplementation(async (path, options) => path === '/api/v1/published-artifact-checks'
      ? { checks: [], diagnostics: [{ file: 'damaged-check.json', error: 'invalid JSON' }] } : fallback(path, options))
    const view = render(html`<${ArtifactsSurface} />`)
    expect(await view.findByText(/damaged-check.json/)).toBeTruthy()
    const controls = view.getAllByRole('button', { name: '확인 상태 알 수 없음' }) as HTMLButtonElement[]
    expect(controls.every(button => button.disabled)).toBe(true)
    expect(view.getByText('오늘 미확인 조회 필요')).toBeTruthy()
    expect((view.getByRole('button', { name: '미확인만' }) as HTMLButtonElement).disabled).toBe(true)
    expect(vi.mocked(post)).not.toHaveBeenCalled()
  })

  it('ignores a late confirmation completion after the authentication owner changes', async () => {
    let finish: ((value: unknown) => void) | undefined
    vi.mocked(post).mockImplementation(() => new Promise(resolve => { finish = resolve }))
    route.value = { tab: 'workspace', params: { section: 'artifacts', artifact: firstId }, postId: null }
    const view = render(html`<${ArtifactsSurface} />`)
    const reader = within(await view.findByRole('dialog'))
    fireEvent.click(await reader.findByRole('button', { name: '○ 미확인' }))
    await waitFor(() => expect(finish).toBeDefined())
    vi.mocked(currentStoredTokenRevision).mockReturnValue(1)
    authOwner.change!(1)
    // Authentication replacement retires the old dialog as well as its writer.
    await waitFor(() => expect(within(view.getByRole('dialog')).getByRole('button', { name: '○ 미확인' })).toBeTruthy())
    const replacement = within(view.getByRole('dialog'))
    const before = vi.mocked(get).mock.calls.filter(([path]) => path === '/api/v1/published-artifact-checks').length
    await act(async () => {
      finish?.({ check: { id: firstId, revision: 2, body_sha256: first.body.sha256, checked: true,
        change_id: `check-${'e'.repeat(32)}`, changed_by: 'old-auth', changed_at: '2026-10-19T01:00:00Z' } })
    })
    expect(replacement.queryByText(/저장했습니다/)).toBeNull()
    expect(within(view.getByRole('dialog')).queryByRole('button', { name: '✓ 확인함' })).toBeNull()
    expect(vi.mocked(get).mock.calls.filter(([path]) => path === '/api/v1/published-artifact-checks').length).toBe(before)
  })

  it('rereads a conflicting shared confirmation without retrying the mutation', async () => {
    const fallback = vi.mocked(get).getMockImplementation()!
    const check = { id: firstId, revision: 2, body_sha256: first.body.sha256, checked: true,
      change_id: `check-${'f'.repeat(32)}`, changed_by: 'another-client', changed_at: '2026-10-19T01:00:00Z' }
    let changed = false
    vi.mocked(get).mockImplementation(async (path, options) => path === '/api/v1/published-artifact-checks'
      ? { checks: changed ? [check] : [], diagnostics: [] } : fallback(path, options))
    vi.mocked(post).mockImplementation(async () => {
      changed = true
      throw new Error('confirmation conflict')
    })
    route.value = { tab: 'workspace', params: { section: 'artifacts', artifact: firstId }, postId: null }
    const view = render(html`<${ArtifactsSurface} />`)
    const reader = within(await view.findByRole('dialog'))
    fireEvent.click(await reader.findByRole('button', { name: '○ 미확인' }))
    await waitFor(() => expect(within(view.getByRole('dialog')).getByRole('button', { name: '✓ 확인함' })).toBeTruthy())
    expect(within(view.getByRole('dialog')).getByText(/another-client/)).toBeTruthy()
    expect(vi.mocked(post)).toHaveBeenCalledTimes(1)
  })

  it('lists, searches and opens a stored report, preserving source and revision links', async () => {
    const view = render(html`<${ArtifactsSurface} />`)
    fireEvent.click(await view.findByRole('button', { name: /주간 조사 보고서/ }))
    expect(await view.findByRole('heading', { name: first.title })).toBeTruthy()
    fireEvent.click(view.getByText('보고서 정보'))
    expect(view.getByRole('link', { name: 'task-42' }).getAttribute('href')).toContain('task=task-42')
    fireEvent.click(view.getByRole('button', { name: '원본', exact: true }))
    expect(view.getByLabelText('문서 원본').textContent).toBe(document.content)
    fireEvent.change(view.getByLabelText('문서 버전'), { target: { value: '1' } })
    expect(navigate).toHaveBeenLastCalledWith('workspace', { section: 'artifacts', artifact: firstId, revision: '1' })
    expect(await view.findByRole('heading', { name: '조사 초안' })).toBeTruthy()
    fireEvent.click(view.getByRole('button', { name: '원본', exact: true }))
    expect(view.getByLabelText('문서 원본').textContent).toBe('# 이전 원본')
    fireEvent.click(view.getByRole('button', { name: '목록으로' }))
    expect(navigate).toHaveBeenLastCalledWith('workspace', { section: 'artifacts' })
    expect(view.queryByRole('dialog')).toBeNull()
    fireEvent.input(view.getByRole('searchbox'), { target: { value: 'designer' } })
    expect(view.queryByRole('button', { name: /주간 조사 보고서/ })).toBeNull()
    expect(view.getByRole('button', { name: /동작하는 차트/ })).toBeTruthy()
  })

  it('reopens a direct version link without needing the catalog selection', async () => {
    route.value = { tab: 'workspace', params: { section: 'artifacts', artifact: firstId, revision: '1' }, postId: null }
    const view = render(html`<${ArtifactsSurface} />`)
    expect(await view.findByRole('heading', { name: '조사 초안' })).toBeTruthy()
    expect((view.getByLabelText('문서 버전') as HTMLSelectElement).value).toBe('1')
    fireEvent(view.getByRole('dialog'), new Event('cancel', { cancelable: true }))
    expect(navigate).toHaveBeenLastCalledWith('workspace', { section: 'artifacts' })
    expect(view.queryByRole('dialog')).toBeNull()
  })

  it('opens HTML in an opaque sandbox with a restrictive resource policy', async () => {
    route.value = { tab: 'workspace', params: { section: 'artifacts', artifact: secondId }, postId: null }
    const view = render(html`<${ArtifactsSurface} />`)
    const frame = await view.findByTitle(second.title)
    expect(frame.getAttribute('sandbox')).toBe('allow-scripts')
    expect(frame.getAttribute('srcdoc')).toContain("connect-src 'none'")
    expect(frame.getAttribute('srcdoc')).toContain('<button onclick=')
    expect(frame.getAttribute('referrerpolicy')).toBe('no-referrer')
  })

  it('reads only an explicitly previewed HTML revision and keeps its preview inert', async () => {
    const view = render(html`<${ArtifactsSurface} />`)
    fireEvent.click(await view.findByRole('button', { name: 'HTML 미리보기' }))
    const frame = await view.findByTitle(`${second.title} 빠른 미리보기`)
    expect(vi.mocked(get).mock.calls.some(([path]) => path === `/api/v1/published-artifacts/${secondId}?revision=2`)).toBe(true)
    expect(vi.mocked(get).mock.calls.some(([path]) => path.includes(firstId))).toBe(false)
    expect(frame.getAttribute('sandbox')).toBe('')
    expect(frame.getAttribute('srcdoc')).toContain("script-src 'none'")
    expect(frame.getAttribute('srcdoc')).toContain("connect-src 'none'")
    expect(frame.getAttribute('srcdoc')).toContain('<button onclick=')
    fireEvent.click(view.getByRole('button', { name: '미리보기 접기' }))
    expect(view.queryByTitle(`${second.title} 빠른 미리보기`)).toBeNull()
  })

  it('retires a collapsed preview request and refuses its late body', async () => {
    let finish: ((value: unknown) => void) | undefined
    vi.mocked(get).mockImplementation(async path => path === '/api/v1/published-artifact-checks'
      ? { checks: [], diagnostics: [] } : path === '/api/v1/published-artifacts'
        ? { artifacts: [first, second], diagnostics: [] }
        : new Promise(resolve => { finish = resolve }))
    const view = render(html`<${ArtifactsSurface} />`)
    fireEvent.click(await view.findByRole('button', { name: 'HTML 미리보기' }))
    await waitFor(() => expect(finish).toBeDefined())
    const options = vi.mocked(get).mock.calls.find(([path]) => path.includes(secondId))?.[1]
    fireEvent.click(view.getByRole('button', { name: '미리보기 접기' }))
    expect(options?.signal?.aborted).toBe(true)
    finish?.({ artifact: second, content: '<h1>late</h1>', revisions: [second] })
    await waitFor(() => expect(view.queryByTitle(`${second.title} 빠른 미리보기`)).toBeNull())
  })

  it('shows copy success inside the reader and copies the selected version link', async () => {
    route.value = { tab: 'workspace', params: { section: 'artifacts', artifact: firstId, revision: '1' }, postId: null }
    const view = render(html`<${ArtifactsSurface} />`)
    const dialog = within(await view.findByRole('dialog'))
    fireEvent.click(dialog.getByRole('button', { name: '링크 복사' }))
    await waitFor(() => expect(dialog.getByRole('status').textContent).toBe('문서 링크를 복사했습니다.'))
    expect(vi.mocked(copyToClipboard).mock.calls[0]?.[0]).toContain(`artifact=${firstId}&revision=1`)
    expect(vi.mocked(copyToClipboard).mock.calls[0]?.[1]).toBe(view.getByRole('dialog'))
  })

  it('shows clipboard failure inside the reader', async () => {
    vi.mocked(copyToClipboard).mockResolvedValue(false)
    route.value = { tab: 'workspace', params: { section: 'artifacts', artifact: firstId }, postId: null }
    const view = render(html`<${ArtifactsSurface} />`)
    const dialog = within(await view.findByRole('dialog'))
    fireEvent.click(dialog.getByRole('button', { name: '링크 복사' }))
    await waitFor(() => expect(dialog.getByRole('status').textContent).toBe('링크를 복사하지 못했습니다.'))
  })

  it('keeps loading, empty and inaccessible catalogs distinct', async () => {
    let resolve: ((value: unknown) => void) | undefined
    vi.mocked(get).mockImplementationOnce(() => new Promise(r => { resolve = r }))
    const view = render(html`<${ArtifactsSurface} />`)
    expect(view.getByRole('status').textContent).toContain('목록을 불러오고')
    resolve?.({ artifacts: [], diagnostics: [] })
    expect(await view.findByText(/아직 게시된 아티팩트가 없습니다/)).toBeTruthy()
    vi.mocked(get).mockRejectedValueOnce(new Error('permission denied'))
    fireEvent.click(view.getByRole('button', { name: '새로고침' }))
    expect((await view.findByRole('alert')).textContent).toContain('permission denied')
  })

  it('does not display a stale selection when an earlier fetch resolves late', async () => {
    let resolve: ((value: unknown) => void) | undefined
    vi.mocked(get).mockImplementation(async path => {
      if (path === '/api/v1/published-artifact-checks') return { checks: [], diagnostics: [] }
      if (path === '/api/v1/published-artifacts') return { artifacts: [first, second], diagnostics: [] }
      if (path.includes(firstId)) return new Promise(r => { resolve = r })
      return { artifact: second, content: '<h1>second</h1>', revisions: [second] }
    })
    const view = render(html`<${ArtifactsSurface} />`)
    fireEvent.click(await view.findByRole('button', { name: /주간 조사 보고서/ }))
    await waitFor(() => expect(resolve).toBeDefined())
    fireEvent.click(view.getByRole('button', { name: /동작하는 차트/ }))
    expect(await view.findByRole('heading', { name: second.title })).toBeTruthy()
    resolve?.(document)
    await waitFor(() => expect(view.queryByRole('heading', { name: first.title })).toBeNull())
  })

  it('rejects a server response for a different artifact and shows diagnostics', async () => {
    route.value = { tab: 'workspace', params: { section: 'artifacts', artifact: secondId }, postId: null }
    vi.mocked(get).mockImplementation(async path => path === '/api/v1/published-artifact-checks'
      ? { checks: [], diagnostics: [] } : path === '/api/v1/published-artifacts'
        ? { artifacts: [first], diagnostics: [{ id: 'unreadable', error: 'invalid metadata' }] } : document)
    const view = render(html`<${ArtifactsSurface} />`)
    expect(await view.findByText(/요청한 문서와 저장된 문서의 식별자가 다릅니다/)).toBeTruthy()
    expect(view.getByText(/일부 문서를 읽지 못했습니다/).textContent).toContain('invalid metadata')
  })
})
