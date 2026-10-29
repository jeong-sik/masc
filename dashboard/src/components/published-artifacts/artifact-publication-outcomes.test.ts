import { html } from 'htm/preact'
import type { Signal } from '@preact/signals'
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/preact'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { ApiRequestError, clearStoredToken, get, getPublic, getWithResponse, post, setStoredToken } from '../../api/core'
import type { ArtifactPublication, ArtifactWorkspace } from '../../api/published-artifacts'
import { artifactPublicationOutcomes } from '../../lib/artifact-publication-outcomes'
import type { ExecutionWorkspaceAuthority } from '../../store'
import { route } from '../../router'
import { ArtifactsSurface } from './artifacts-surface'
import type { ArtifactPublicationOutcome } from './artifact-composer'

const shared = vi.hoisted(() => ({
  workspace: null as unknown as Signal<ExecutionWorkspaceAuthority | null>,
  finish: null as null | ((status: 'checkpointed' | 'refused' | 'unconfirmed') => void),
}))
vi.mock('../../store', async () => {
  const { signal } = await import('@preact/signals')
  shared.workspace = signal<ExecutionWorkspaceAuthority | null>(null)
  return { executionWorkspaceAuthority: shared.workspace }
})
vi.mock('../../router', async () => {
  const { signal } = await import('@preact/signals')
  const route = signal({ tab: 'workspace', params: {} as Record<string, string>, postId: null })
  return { route, navigate: vi.fn((tab, params) => { route.value = { tab, params, postId: null } }) }
})
vi.mock('../../api/core', async original => ({ ...await original<typeof import('../../api/core')>(),
  get: vi.fn(), getPublic: vi.fn(), getWithResponse: vi.fn(), post: vi.fn() }))
vi.mock('../common/markdown', () => ({ Markdown: ({ text }: { text: string }) => html`<div>${text}</div>` }))
vi.mock('./artifact-shared-editor', async () => {
  const { html } = await import('htm/preact')
  return { ArtifactSharedEditor: (props: { capturedWorkspace: ArtifactWorkspace;
    onMutation: (outcome: ArtifactPublicationOutcome) => void; onPublished: (publication: ArtifactPublication, workspace: ArtifactWorkspace) => void }) =>
    html`<div><input aria-label="확인할 공동 원고" /><button type="button" onClick=${() => {
      const common = { kind: 'checkpoint' as const, identity: {}, title: publication.artifact.title, publication, workspace: props.capturedWorkspace }
      props.onMutation({ ...common, status: 'pending' })
      shared.finish = status => props.onMutation({ ...common, status, detail: 'checkpoint unavailable' })
      props.onPublished(publication, props.capturedWorkspace)
    }}>완료된 게시 열기</button></div>` }
})

const id = `artifact-${'a'.repeat(32)}`
const artifact = { id, revision: 2, title: '공유 문서', summary: '', format: 'markdown' as const, author: 'writer',
  created_at: '2026-10-28T00:00:00Z', task_id: null, goal_id: null, url: '/dashboard', body: { _blob: { sha256: 'a'.repeat(64) } } }
const publication: ArtifactPublication = { schema: 'masc.published_artifact.v1', revision_url: '/revision', artifact: { ...artifact, revision: 3 } }
const list = '/api/v1/published-artifacts'
const workspace = { basePath: '/workspace-a', mascRoot: '/runtime-a' }

beforeEach(() => {
  artifactPublicationOutcomes.clear(); shared.finish = null
  vi.mocked(get).mockReset(); vi.mocked(getPublic).mockReset(); vi.mocked(getWithResponse).mockReset(); vi.mocked(post).mockReset()
  setStoredToken('fixture-token')
  shared.workspace.value = { epoch: 'fixture', workspaceRoot: workspace.basePath, connectionGeneration: 1 }
  route.value = { tab: 'workspace', params: { section: 'artifacts', artifact: id }, postId: null }
  vi.mocked(get).mockImplementation(async path => path === '/health?full=1'
    ? { paths: { effective_base_path: workspace.basePath, effective_masc_root: workspace.mascRoot } }
    : path === list ? { artifacts: [artifact], diagnostics: [] }
    : path === '/api/v1/published-artifact-checks' ? { checks: [], diagnostics: [] }
    : { artifact: path.includes('revision=3') ? publication.artifact : artifact, content: 'body',
      revisions: [publication.artifact, artifact], shared: false, share_version: 0 })
  vi.mocked(getWithResponse).mockImplementation(async (path, options) => {
    const url = new URL(path, window.location.origin)
    url.searchParams.delete('expected_base_path'); url.searchParams.delete('expected_masc_root')
    const query = url.searchParams.toString()
    return { data: await get(`${url.pathname}${query ? `?${query}` : ''}`, options),
      headers: new Headers({ 'x-masc-workspace-read': 'matched-v1' }) }
  })
})
afterEach(() => { cleanup(); clearStoredToken(); artifactPublicationOutcomes.clear(); vi.unstubAllGlobals() })

async function publishWithCheckpointPending() {
  render(html`<${ArtifactsSurface} />`)
  const reader = within(await screen.findByRole('dialog'))
  fireEvent.click(await reader.findByRole('button', { name: '공동 편집' }))
  fireEvent.click(await reader.findByRole('button', { name: '완료된 게시 열기' }))
  await waitFor(() => expect(route.value.params.revision).toBe('3'))
  await waitFor(() => expect(within(screen.getByRole('dialog')).getByRole('region', { name: '문서 저장 요청 결과' }).textContent).toContain('갱신 중'))
}

it('shows a later checkpoint refusal inside the new revision reader', async () => {
  await publishWithCheckpointPending()
  await act(() => shared.finish!('refused'))
  const result = within(screen.getByRole('dialog')).getByRole('region', { name: '문서 저장 요청 결과' })
  expect(result.textContent).toContain('갱신 거절됨')
  expect(result.textContent).toContain('/workspace-a (/runtime-a)')
  expect(result.textContent).toContain('checkpoint unavailable')
})

it('shows a completed checkpoint inside the new revision reader', async () => {
  await publishWithCheckpointPending()
  await act(() => shared.finish!('checkpointed'))
  const result = within(screen.getByRole('dialog')).getByRole('region', { name: '문서 저장 요청 결과' })
  expect(result.textContent).toContain('갱신됨')
  expect(result.textContent).toContain('/workspace-a (/runtime-a)')
})

it('retains an unconfirmed checkpoint after the artifact surface unmounts', async () => {
  await publishWithCheckpointPending()
  cleanup()
  await act(() => shared.finish!('unconfirmed'))
  render(html`<${ArtifactsSurface} />`)
  const reader = within(await screen.findByRole('dialog'))
  const result = await reader.findByRole('region', { name: '문서 저장 요청 결과' })
  expect(result.textContent).toContain('갱신 결과 미확인')
  expect(result.textContent).toContain('/workspace-a (/runtime-a)')
  expect(result.textContent).toContain('이전 접근 상태의 요청 결과')
})

it.each(['workspace', 'digest'] as const)('does not open a different publication after a %s change', async change => {
  render(html`<${ArtifactsSurface} />`)
  let reader = within(await screen.findByRole('dialog'))
  fireEvent.click(await reader.findByRole('button', { name: '공동 편집' }))
  const prior = vi.mocked(getWithResponse).getMockImplementation()!
  vi.mocked(getWithResponse).mockImplementation(async (path, options) => {
    const url = new URL(path, window.location.origin)
    if (url.searchParams.get('revision') !== '3') return prior(path, options)
    expect(url.searchParams.get('expected_base_path')).toBe(workspace.basePath)
    expect(url.searchParams.get('expected_masc_root')).toBe(workspace.mascRoot)
    if (change === 'workspace') throw new ApiRequestError({ method: 'GET', path, status: 409, detail: 'workspace changed' })
    return { data: { artifact: { ...publication.artifact, body: { _blob: { sha256: 'b'.repeat(64) } } }, content: 'other body',
      revisions: [publication.artifact], shared: false, share_version: 0 }, headers: new Headers({ 'x-masc-workspace-read': 'matched-v1' }) }
  })
  fireEvent.click(reader.getByRole('button', { name: '완료된 게시 열기' }))
  await screen.findByText(change === 'workspace' ? /게시 당시 작업 공간에서 문서를 열지 못했습니다/ : /게시한 문서의 내용이 달라/)
  expect(screen.queryByText('other body')).toBeNull()
  expect(vi.mocked(get).mock.calls.some(([path]) => path.includes(id) && path.includes('revision=3'))).toBe(false)
  expect(getPublic).not.toHaveBeenCalled()
})

it.each(['unavailable', 'digest'] as const)('keeps an open editor on a pinned refresh %s failure', async failure => {
  await publishWithCheckpointPending()
  const reader = within(screen.getByRole('dialog'))
  fireEvent.click(await reader.findByRole('button', { name: '공동 편집' }))
  const input = reader.getByLabelText('확인할 공동 원고') as HTMLInputElement
  fireEvent.input(input, { target: { value: 'still editing' } })
  const prior = vi.mocked(getWithResponse).getMockImplementation()!
  vi.mocked(getWithResponse).mockImplementation(async (path, options) => {
    const url = new URL(path, window.location.origin)
    if (url.searchParams.get('revision') !== '3') return prior(path, options)
    if (failure === 'unavailable') throw new ApiRequestError({ method: 'GET', path, status: 503, detail: 'temporarily unavailable' })
    return { data: { artifact: { ...publication.artifact, body: { _blob: { sha256: 'b'.repeat(64) } } }, content: 'other body',
      revisions: [publication.artifact], shared: false, share_version: 0 }, headers: new Headers({ 'x-masc-workspace-read': 'matched-v1' }) }
  })
  fireEvent.click(screen.getByRole('button', { name: '새로고침' }))
  expect((await reader.findAllByText(failure === 'unavailable' ? /게시 당시 작업 공간에서 문서를 열지 못했습니다/ : /게시한 문서의 내용이 달라/)).length).toBeGreaterThan(0)
  expect(reader.getByLabelText('확인할 공동 원고')).toBe(input)
  expect(input.value).toBe('still editing')
})

it.each(['workspace', 'credential'] as const)('retains the publication workspace across a %s change', async change => {
  await publishWithCheckpointPending()
  const prior = vi.mocked(getWithResponse).getMockImplementation()!
  vi.mocked(get).mockClear()
  vi.mocked(getWithResponse).mockImplementation(async (path, options) => {
    const url = new URL(path, window.location.origin)
    if (url.searchParams.get('revision') !== '3') return prior(path, options)
    expect(url.searchParams.get('expected_base_path')).toBe(workspace.basePath)
    expect(url.searchParams.get('expected_masc_root')).toBe(workspace.mascRoot)
    throw new ApiRequestError({ method: 'GET', path, status: 409, detail: 'workspace changed' })
  })
  await act(() => {
    if (change === 'credential') clearStoredToken()
    else shared.workspace.value = { epoch: 'replacement', workspaceRoot: workspace.basePath, connectionGeneration: 2 }
  })
  await screen.findByText(/게시 당시 작업 공간의 접근 상태를 확인한 뒤/)
  expect(vi.mocked(get).mock.calls.some(([path]) => path.includes(id) && path.includes('revision=3'))).toBe(false)
  expect(getPublic).not.toHaveBeenCalled()
  if (change === 'credential') {
    vi.mocked(getPublic).mockResolvedValue({ artifact: publication.artifact, content: 'public body', revisions: [publication.artifact], shared: true })
    fireEvent.click(screen.getByRole('button', { name: '현재 접근 상태에서 문서 다시 열기' }))
    await screen.findByText('public body')
    expect(getPublic).toHaveBeenCalledTimes(1)
  }
})
