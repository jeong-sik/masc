import { html } from 'htm/preact'
import type { Signal } from '@preact/signals'
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/preact'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { ApiRequestError, clearStoredToken, get, post, setStoredToken } from '../../api/core'
import type { ExecutionWorkspaceAuthority } from '../../store'
import { route } from '../../router'
import { ArtifactsSurface } from './artifacts-surface'

const workspace = vi.hoisted(() => ({ current: null as unknown as Signal<ExecutionWorkspaceAuthority | null> }))
vi.mock('../../store', async () => {
  const { signal } = await import('@preact/signals')
  workspace.current = signal<ExecutionWorkspaceAuthority | null>(null)
  return { executionWorkspaceAuthority: workspace.current }
})
vi.mock('../../router', async () => {
  const { signal } = await import('@preact/signals')
  const route = signal({ tab: 'workspace', params: {} as Record<string, string>, postId: null })
  return { route, navigate: vi.fn((tab, params) => { route.value = { tab, params, postId: null } }) }
})
vi.mock('../../api/core', async original => ({ ...await original<typeof import('../../api/core')>(), get: vi.fn(), post: vi.fn() }))
vi.mock('../common/markdown', () => ({ Markdown: ({ text }: { text: string }) => html`<div>${text}</div>` }))

const id = `artifact-${'a'.repeat(32)}`
const artifact = { id, revision: 2, title: '원래 제목', summary: '원래 요약', format: 'markdown', author: 'keeper-a',
  created_at: '2026-10-25T00:00:00Z', task_id: 'task-1', goal_id: null, url: '/dashboard', body: { _blob: { sha256: 'a'.repeat(64) } } }
const original = { artifact, content: '# 원고\r\n한글 😀', revisions: [artifact] }
const list = '/api/v1/published-artifacts'
function deferred<T = unknown>() {
  let resolve!: (value: T) => void
  const promise = new Promise<T>(ok => { resolve = ok })
  return { promise, resolve }
}
function publication(title: string, revision = 3) {
  return { schema: 'masc.published_artifact.v1', artifact: { ...artifact, title, revision }, revision_url: '/dashboard' }
}
async function edit() {
  route.value = { tab: 'workspace', params: { section: 'artifacts', artifact: id }, postId: null }
  render(html`<${ArtifactsSurface} />`)
  const reader = within(await screen.findByRole('dialog'))
  fireEvent.click(reader.getByRole('button', { name: '문서 편집' }))
  return reader
}

beforeEach(() => {
  vi.mocked(get).mockReset(); vi.mocked(post).mockReset()
  setStoredToken('credential-a')
  workspace.current.value = { epoch: 'fixture', workspaceRoot: '/workspace-a', connectionGeneration: 1 }
  route.value = { tab: 'workspace', params: { section: 'artifacts' }, postId: null }
  vi.mocked(get).mockImplementation(async path => path === list ? { artifacts: [artifact], diagnostics: [] }
    : path === '/api/v1/published-artifact-checks' ? { checks: [], diagnostics: [] } : original)
})
afterEach(() => { cleanup(); clearStoredToken(); vi.restoreAllMocks() })

it('saves the exact edited source against its captured revision, preserving task and goal links, then reads that revision', async () => {
  const reader = await edit()
  const content = '# 수정 원고\r\n한글 😀\n'
  fireEvent.input(reader.getByLabelText('문서 제목'), { target: { value: '수정 제목' } })
  fireEvent.input(reader.getByLabelText('문서 본문'), { target: { value: content } })
  const receipt = publication('수정 제목')
  vi.mocked(post).mockResolvedValue(receipt)
  const fallback = vi.mocked(get).getMockImplementation()!
  vi.mocked(get).mockImplementation((path, options) => path.endsWith('?revision=3')
    ? Promise.resolve({ artifact: receipt.artifact, content, revisions: [receipt.artifact, artifact] })
    : fallback(path, options))
  fireEvent.click(reader.getByRole('button', { name: '새 버전 저장' }))
  await waitFor(() => expect(post).toHaveBeenCalledTimes(1))
  const sent = vi.mocked(post).mock.calls[0]![1]
  expect(sent).toEqual({ id, expected_revision: 2, title: '수정 제목', summary: artifact.summary,
    format: 'markdown', content, task_id: 'task-1', goal_id: null })
  await screen.findByText('저장 내용 확인됨', { exact: false })
  expect(get).toHaveBeenCalledWith(`${list}/${id}?revision=3`, { signal: undefined })
})

it('retains a conflicting draft and compares the newest server version without automatically replacing or resending it', async () => {
  const reader = await edit()
  fireEvent.input(reader.getByLabelText('문서 본문'), { target: { value: '내가 작성한 원고' } })
  vi.mocked(post).mockRejectedValue(new ApiRequestError({ method: 'POST', path: list, status: 409 }))
  fireEvent.click(reader.getByRole('button', { name: '새 버전 저장' }))
  await reader.findByText(/다른 사용자가 먼저 저장했습니다/)
  const fallback = vi.mocked(get).getMockImplementation()!
  vi.mocked(get).mockImplementation((path, options) => path === `${list}/${id}`
    ? Promise.resolve({ ...original, artifact: { ...artifact, revision: 3 }, content: '다른 사람이 작성한 원고' })
    : fallback(path, options))
  fireEvent.click(reader.getByRole('button', { name: '최신 버전과 비교' }))
  await reader.findByText('다른 사람이 작성한 원고')
  expect((reader.getByLabelText('문서 본문') as HTMLTextAreaElement).value).toBe('내가 작성한 원고')
  expect(post).toHaveBeenCalledTimes(1)
})

it('keeps an uncertain write locked and does not repeat a timed-out publication', async () => {
  const reader = await edit()
  vi.mocked(post).mockRejectedValue(new Error('lost response'))
  fireEvent.click(reader.getByRole('button', { name: '새 버전 저장' }))
  await reader.findByText(/자동으로 다시 저장하지 않습니다/)
  expect((reader.getByRole('button', { name: '새 버전 저장' }) as HTMLButtonElement).disabled).toBe(true)
  expect(post).toHaveBeenCalledTimes(1)
})

it('retains the committed identity when readback fails, without claiming the draft was saved correctly', async () => {
  const reader = await edit()
  vi.mocked(post).mockResolvedValue(publication(artifact.title))
  const fallback = vi.mocked(get).getMockImplementation()!
  vi.mocked(get).mockImplementation((path, options) => path.endsWith('?revision=3')
    ? Promise.resolve({ ...original, artifact: { ...artifact, revision: 3 }, content: 'wrong body' }) : fallback(path, options))
  fireEvent.click(reader.getByRole('button', { name: '새 버전 저장' }))
  await reader.findByText(/저장된 문서가 보낸 내용과 다릅니다/)
  expect(reader.getByRole('link', { name: '응답받은 버전 확인' }).getAttribute('href')).toContain('revision=3')
  expect(screen.queryByText('저장 내용 확인됨', { exact: false })).toBeNull()
  expect(post).toHaveBeenCalledTimes(1)
})

it('does not rebase an open draft when automatic document refresh observes a newer revision', async () => {
  const reader = await edit()
  fireEvent.input(reader.getByLabelText('문서 본문'), { target: { value: 'old-base draft' } })
  vi.mocked(get).mockImplementation(async path => path === list ? { artifacts: [{ ...artifact, revision: 9 }], diagnostics: [] }
    : path === '/api/v1/published-artifact-checks' ? { checks: [], diagnostics: [] }
      : { ...original, artifact: { ...artifact, revision: 9 }, content: 'new server content' })
  fireEvent.click(screen.getByRole('button', { name: '새로고침' }))
  await waitFor(() => expect(reader.getByText('markdown · v9')).toBeTruthy())
  expect((reader.getByLabelText('문서 본문') as HTMLTextAreaElement).value).toBe('old-base draft')
  vi.mocked(post).mockRejectedValue(new ApiRequestError({ method: 'POST', path: list, status: 409 }))
  fireEvent.click(reader.getByRole('button', { name: '새 버전 저장' }))
  await waitFor(() => expect(post).toHaveBeenCalledTimes(1))
  expect(vi.mocked(post).mock.calls[0]![1]).toMatchObject({ expected_revision: 2 })
})

it('retains a late committed response under the original workspace without reading with a replacement credential', async () => {
  const reader = await edit()
  const sent = deferred()
  vi.mocked(post).mockReturnValue(sent.promise)
  fireEvent.click(reader.getByRole('button', { name: '새 버전 저장' }))
  await waitFor(() => expect(post).toHaveBeenCalledTimes(1))
  await act(async () => { workspace.current.value = null; setStoredToken('credential-b') })
  const reads = vi.mocked(get).mock.calls.length
  await act(async () => sent.resolve(publication(artifact.title)))
  const result = await screen.findByRole('region', { name: '문서 저장 요청 결과' })
  expect(result.textContent).toContain('/workspace-a')
  expect(result.textContent).toContain(id)
  expect(result.textContent).toContain('이전 접근 상태의 요청 결과')
  expect(get).toHaveBeenCalledTimes(reads)
  expect(post).toHaveBeenCalledTimes(1)
})

it('reads an explicitly selected UTF-8 HTML file without running it or publishing before confirmation', async () => {
  render(html`<${ArtifactsSurface} />`)
  fireEvent.click(screen.getByRole('button', { name: '파일 가져오기' }))
  const content = '\uFEFF<!doctype html>\r\n<script>window.shouldNotRun = true</script><p>한글 😀</p>'
  const file = new File([content], 'report.html', { type: 'text/html' })
  Object.defineProperty(file, 'arrayBuffer', { value: async () => new TextEncoder().encode(content).buffer })
  fireEvent.change(screen.getByLabelText('가져올 문서 파일'), { target: { files: [file] } })
  const body = await screen.findByLabelText('문서 본문') as HTMLTextAreaElement
  expect(body.value).toContain('\uFEFF<!doctype html>')
  expect(body.value).toContain('window.shouldNotRun')
  expect(document.querySelector('script')).toBeNull()
  expect(post).not.toHaveBeenCalled()
  expect((screen.getByLabelText('문서 형식') as HTMLSelectElement).value).toBe('html')
})

it('refuses invalid UTF-8 instead of replacing source bytes silently', async () => {
  render(html`<${ArtifactsSurface} />`)
  fireEvent.click(screen.getByRole('button', { name: '파일 가져오기' }))
  const file = new File([], 'report.md')
  Object.defineProperty(file, 'arrayBuffer', { value: async () => new Uint8Array([0xff, 0xff]).buffer })
  fireEvent.change(screen.getByLabelText('가져올 문서 파일'), { target: { files: [file] } })
  await waitFor(() => expect(screen.getByRole('region', { name: '파일 가져오기' }).textContent).toMatch(/encoded|encoding|UTF-8/i))
  expect(screen.queryByLabelText('문서 본문')).toBeNull()
  expect(post).not.toHaveBeenCalled()
})
