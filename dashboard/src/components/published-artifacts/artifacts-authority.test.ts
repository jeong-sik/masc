import { html } from 'htm/preact'
import type { Signal } from '@preact/signals'
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/preact'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { ApiRequestError, get, getPublic, post, clearStoredToken, setStoredToken } from '../../api/core'
import { executionWorkspaceAuthority, type ExecutionWorkspaceAuthority } from '../../store'
import { route } from '../../router'
import { ArtifactsSurface } from './artifacts-surface'
import { copyToClipboard } from '../common/copyable-code'
import { retainPendingShare } from '../../lib/artifact-share-recovery'

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
vi.mock('../../api/core', async original => ({ ...await original<typeof import('../../api/core')>(), get: vi.fn(), getPublic: vi.fn(), post: vi.fn() }))
vi.mock('../common/markdown', () => ({ Markdown: ({ text }: { text: string }) => html`<div>${text}</div>` }))
vi.mock('../common/copyable-code', () => ({ copyToClipboard: vi.fn(async () => true) }))

function pending<T = unknown>() {
  let resolve!: (value: T) => void, reject!: (error: Error) => void
  const promise = new Promise<T>((ok, fail) => { resolve = ok; reject = fail })
  return { promise, resolve, reject }
}
const authority = (root = '/workspace-a'): ExecutionWorkspaceAuthority => ({ epoch: 'fixture', workspaceRoot: root, connectionGeneration: 1 })
const firstId = `artifact-${'a'.repeat(32)}`, secondId = `artifact-${'b'.repeat(32)}`
const first = { id: firstId, revision: 2, title: 'Original report', summary: 'report summary', format: 'markdown', author: 'writer',
  created_at: '2026-10-22T01:00:00Z', task_id: null, goal_id: null, url: '/dashboard', body: { _blob: { sha256: 'a'.repeat(64) } } }
const second = { ...first, id: secondId, title: 'HTML report', format: 'html' }
const document = (artifact = first, content = 'original body') => ({ artifact, content, revisions: [artifact], shared: false, share_version: 0 })
const listing = (artifacts = [first, second]) => ({ artifacts, diagnostics: [] })
const select = (id?: string) => { route.value = { tab: 'workspace', params: { section: 'artifacts', ...(id ? { artifact: id } : {}) }, postId: null } }
const checks = '/api/v1/published-artifact-checks'
const list = '/api/v1/published-artifacts'
const reads = () => vi.mocked(get).mock.calls.length
function shareReply(id: string) {
  const payload = vi.mocked(post).mock.calls.at(-1)?.[1] as { operation_id: string; expected_version: number; shared: boolean }
  const snapshot = { version: payload.expected_version + 1, shared: payload.shared }
  return { id, receipt: { operation_id: payload.operation_id, expected_version: payload.expected_version,
    requested: payload.shared, outcome: 'applied', snapshot }, current: snapshot }
}
const checkReceipt = { id: firstId, revision: 2, body_sha256: first.body._blob.sha256, checked: true,
  change_id: `check-${'c'.repeat(32)}`, changed_by: 'original-human', changed_at: '2026-10-22T01:00:00Z' }

beforeEach(() => {
  localStorage.clear()
  window.dispatchEvent(new StorageEvent('storage'))
  expect(executionWorkspaceAuthority).toBe(workspace.current)
  vi.mocked(get).mockReset(); vi.mocked(getPublic).mockReset(); vi.mocked(post).mockReset()
  vi.mocked(copyToClipboard).mockClear()
  setStoredToken('credential-a'); workspace.current.value = authority(); select()
  vi.mocked(get).mockImplementation(async path => path === list ? listing() : path === checks
    ? { checks: [], diagnostics: [] } : document(path.includes(secondId) ? second : first))
  vi.mocked(getPublic).mockRejectedValue(Object.assign(new Error('Unauthorized'), { status: 401 }))
})
afterEach(() => { cleanup(); clearStoredToken(); vi.unstubAllGlobals() })

it('waits without reading or inventing an empty catalog when workspace authority is unknown', async () => {
  workspace.current.value = null
  render(html`<${ArtifactsSurface} />`)
  await act(async () => {})
  expect(get).not.toHaveBeenCalled()
  expect(screen.queryByText(/아직 게시된 아티팩트가 없습니다/)).toBeNull()
})

it('opens a public artifact without forwarding a stored token when workspace authority is initially null', async () => {
  workspace.current.value = null
  setStoredToken('expired-foreign-token')
  vi.mocked(getPublic).mockResolvedValue(document())
  select(firstId)
  render(html`<${ArtifactsSurface} />`)
  const reader = within(await screen.findByRole('dialog'))
  expect(reader.getByRole('heading', { name: 'Original report' })).toBeTruthy()
  expect(reader.getByText('original body')).toBeTruthy()
  expect(reader.getByRole('button', { name: '링크 복사' })).toBeTruthy()
  expect(reader.getByRole('button', { name: '원본 다운로드' })).toBeTruthy()
  expect(reader.queryByRole('button', { name: '외부 공유 켜기' })).toBeNull()
  expect(reader.queryByRole('button', { name: '편집' })).toBeNull()
  expect(reader.queryByRole('button', { name: '목록으로' })).toBeNull()
  expect(reader.getByRole('button', { name: '닫기' })).toBeTruthy()
  expect(reader.queryByRole('button', { name: '○ 미확인' })).toBeNull()
  expect(get).not.toHaveBeenCalled()
  expect(vi.mocked(getPublic).mock.calls.map(([path]) => path)).toEqual([`/api/v1/published-artifacts/${firstId}`])
})

it.each([
  ['unverified', 'button'], ['unverified', 'escape'],
  ['tokenless', 'button'], ['tokenless', 'escape'],
  ['worker', 'button'], ['worker', 'escape'],
] as const)('returns to the workspace from a %s public reader using %s', async (access, action) => {
  if (access === 'unverified') workspace.current.value = null
  else if (access === 'tokenless') clearStoredToken()
  else vi.mocked(get).mockImplementation(async path => {
    throw new ApiRequestError({ method: 'GET', path, status: 403, detail: 'worker cannot administer artifacts' })
  })
  vi.mocked(getPublic).mockResolvedValue({ ...document(first, 'shared body'), shared: true })
  select(firstId)
  render(html`<${ArtifactsSurface} />`)
  const dialog = await screen.findByRole('dialog')
  expect(within(dialog).getByText('외부 공유 열람')).toBeTruthy()
  if (access === 'unverified' || access === 'tokenless') expect(get).not.toHaveBeenCalled()
  if (action === 'button') fireEvent.click(within(dialog).getByRole('button', { name: '닫기' }))
  else {
    const cancel = new Event('cancel', { cancelable: true })
    fireEvent(dialog, cancel)
    expect(cancel.defaultPrevented).toBe(true)
  }
  await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull())
  expect(route.value).toMatchObject({ tab: 'workspace', params: { section: 'artifacts' } })
  expect(route.value.params.artifact).toBeUndefined()
  expect(post).not.toHaveBeenCalled()
})

it.each([401, 403])('opens a shared artifact read-only after the operator read returns %i', async status => {
  vi.mocked(get).mockImplementation(async path => {
    throw new ApiRequestError({ method: 'GET', path, status, detail: 'cannot administer artifacts' })
  })
  vi.mocked(getPublic).mockResolvedValue({ ...document(first, 'shared body'), shared: true })
  select(firstId)
  render(html`<${ArtifactsSurface} />`)
  await waitFor(() => expect(getPublic).toHaveBeenCalledTimes(1), { timeout: 500 })
  const reader = within(await screen.findByRole('dialog'))
  expect(reader.getByText('shared body')).toBeTruthy()
  expect(reader.getByText('외부 공유 열람')).toBeTruthy()
  expect(reader.queryByRole('button', { name: '외부 공유 켜기' })).toBeNull()
  expect(reader.queryByRole('button', { name: '문서 편집' })).toBeNull()
  expect(getPublic).toHaveBeenCalledWith(`/api/v1/published-artifacts/${firstId}`, { signal: expect.any(AbortSignal) })
})

it.each(['tokenless', 'worker'])('renders shared HTML read-only for %s without requesting app data', async access => {
  if (access === 'tokenless') clearStoredToken()
  else vi.mocked(get).mockImplementation(async path => {
    throw new ApiRequestError({ method: 'GET', path, status: 403, detail: 'worker cannot administer artifacts' })
  })
  vi.mocked(getPublic).mockResolvedValue({ ...document(second, '<h1>shared HTML content</h1>'), shared: true })
  select(secondId)
  render(html`<${ArtifactsSurface} />`)
  const reader = within(await screen.findByRole('dialog'))
  const iframe = reader.getByTitle(second.title) as HTMLIFrameElement
  expect(iframe.getAttribute('sandbox')).toBe('allow-scripts')
  expect(iframe.srcdoc).toContain('shared HTML content')
  expect(reader.getByText('외부 공유 열람')).toBeTruthy()
  expect(reader.queryByRole('button', { name: '문서 편집' })).toBeNull()
  expect(vi.mocked(get).mock.calls.some(([path]) => path.startsWith('/api/v1/artifact-app-data/'))).toBe(false)
  if (access === 'tokenless') expect(get).not.toHaveBeenCalled()
})

it('shows the public 401 and never exposes a private artifact after operator denial', async () => {
  vi.mocked(get).mockImplementation(async path => {
    if (path === list) return listing()
    if (path === checks) return { checks: [], diagnostics: [] }
    throw new ApiRequestError({ method: 'GET', path, status: 403, detail: 'worker denied' })
  })
  vi.mocked(getPublic).mockRejectedValue(new ApiRequestError({ method: 'GET', path: `${list}/${firstId}`, status: 401, detail: 'private artifact' }))
  select(firstId)
  render(html`<${ArtifactsSurface} />`)
  expect(await screen.findByText(/private artifact/)).toBeTruthy()
  expect(getPublic).toHaveBeenCalledTimes(1)
  expect(screen.queryByRole('dialog')).toBeNull()
  expect(screen.queryByText('외부 공유 열람')).toBeNull()
})

it.each([404, 500])('does not infer public access from an operator HTTP %i failure', async status => {
  vi.mocked(get).mockImplementation(async path => {
    if (path === list) return listing()
    if (path === checks) return { checks: [], diagnostics: [] }
    throw new ApiRequestError({ method: 'GET', path, status, detail: 'read failed' })
  })
  select(firstId)
  render(html`<${ArtifactsSurface} />`)
  await screen.findByRole('alert')
  expect(getPublic).not.toHaveBeenCalled()
  expect(screen.queryByRole('dialog')).toBeNull()
})

it('does not infer public access from an operator network failure', async () => {
  vi.mocked(get).mockImplementation(async path => {
    if (path === list) return listing()
    if (path === checks) return { checks: [], diagnostics: [] }
    throw new Error('network unavailable')
  })
  select(firstId)
  render(html`<${ArtifactsSurface} />`)
  await screen.findByText('network unavailable')
  expect(getPublic).not.toHaveBeenCalled()
})

it('retires a pending public fallback immediately across a batched A to B to A visit', async () => {
  const delayed = pending()
  const fallback = vi.mocked(get).getMockImplementation()!
  let firstReads = 0
  vi.mocked(get).mockImplementation((path, options) => {
    if (path === `${list}/${firstId}` && ++firstReads === 1) {
      return Promise.reject(new ApiRequestError({ method: 'GET', path, status: 403 }))
    }
    if (path === `${list}/${firstId}`) return Promise.resolve(document(first, 'fresh visit body'))
    return fallback(path, options)
  })
  vi.mocked(getPublic).mockReturnValue(delayed.promise)
  select(firstId)
  render(html`<${ArtifactsSurface} />`)
  await waitFor(() => expect(getPublic).toHaveBeenCalledTimes(1))
  const signal = vi.mocked(getPublic).mock.calls[0]![1]!.signal!
  await act(async () => {
    select(secondId)
    select(firstId)
    delayed.resolve({ ...document(first, 'stale public body'), shared: true })
  })
  expect(signal.aborted).toBe(true)
  const reader = within(await screen.findByRole('dialog'))
  expect(reader.getByText('fresh visit body')).toBeTruthy()
  expect(reader.queryByText('stale public body')).toBeNull()
})

it.each(['workspace', 'tab'] as const)('retires a pending public fallback immediately when %s changes', async changed => {
  const delayed = pending()
  const fallback = vi.mocked(get).getMockImplementation()!
  let firstReads = 0
  vi.mocked(get).mockImplementation((path, options) => path === `${list}/${firstId}` && ++firstReads === 1
    ? Promise.reject(new ApiRequestError({ method: 'GET', path, status: 403 }))
    : fallback(path, options))
  vi.mocked(getPublic).mockReturnValue(delayed.promise)
  select(firstId)
  render(html`<${ArtifactsSurface} />`)
  await waitFor(() => expect(getPublic).toHaveBeenCalledTimes(1))
  const signal = vi.mocked(getPublic).mock.calls[0]![1]!.signal!
  await act(async () => {
    if (changed === 'workspace') workspace.current.value = authority('/workspace-b')
    else route.value = { tab: 'monitoring', params: {}, postId: null }
    delayed.resolve({ ...document(first, 'stale public body'), shared: true })
  })
  expect(signal.aborted).toBe(true)
  expect(screen.queryByText('stale public body')).toBeNull()
  if (changed === 'workspace') expect(within(await screen.findByRole('dialog')).getByText('original body')).toBeTruthy()
})

it.each(['workspace', 'tab'] as const)('retires a tokenless public read when %s changes before it resolves', async changed => {
  const delayed = pending()
  clearStoredToken()
  vi.mocked(getPublic).mockReturnValue(delayed.promise)
  select(firstId)
  render(html`<${ArtifactsSurface} />`)
  await waitFor(() => expect(getPublic).toHaveBeenCalledTimes(1))
  const signal = vi.mocked(getPublic).mock.calls[0]![1]!.signal!
  await act(async () => {
    if (changed === 'workspace') {
      vi.mocked(getPublic).mockResolvedValue({ ...document(first, 'new workspace body'), shared: true })
      workspace.current.value = authority('/workspace-b')
    } else route.value = { tab: 'monitoring', params: {}, postId: null }
    delayed.resolve({ ...document(first, 'stale tokenless body'), shared: true })
  })
  expect(signal.aborted).toBe(true)
  expect(screen.queryByText('stale tokenless body')).toBeNull()
  if (changed === 'workspace') expect(within(await screen.findByRole('dialog')).getByText('new workspace body')).toBeTruthy()
})

it('restarts a tokenless read after a batched A to B to A visit', async () => {
  const delayed = pending()
  clearStoredToken()
  vi.mocked(getPublic).mockReturnValueOnce(delayed.promise)
    .mockResolvedValue({ ...document(first, 'new tokenless visit'), shared: true })
  select(firstId)
  render(html`<${ArtifactsSurface} />`)
  await waitFor(() => expect(getPublic).toHaveBeenCalledTimes(1))
  const signal = vi.mocked(getPublic).mock.calls[0]![1]!.signal!
  await act(async () => {
    select(secondId)
    select(firstId)
    delayed.resolve({ ...document(first, 'stale tokenless body'), shared: true })
  })
  expect(signal.aborted).toBe(true)
  const reader = within(await screen.findByRole('dialog'))
  expect(reader.getByText('new tokenless visit')).toBeTruthy()
  expect(reader.queryByText('stale tokenless body')).toBeNull()
})

it.each(['tokenless', 'worker'] as const)('restarts the %s reader after a batched workspace A to B to A change', async access => {
  const delayed = pending()
  if (access === 'tokenless') clearStoredToken()
  else {
    const fallback = vi.mocked(get).getMockImplementation()!
    let firstReads = 0
    vi.mocked(get).mockImplementation((path, options) => path === `${list}/${firstId}` && ++firstReads === 1
      ? Promise.reject(new ApiRequestError({ method: 'GET', path, status: 403 }))
      : fallback(path, options))
  }
  vi.mocked(getPublic).mockReturnValueOnce(delayed.promise)
    .mockResolvedValue({ ...document(first, 'fresh public read'), shared: true })
  select(firstId)
  render(html`<${ArtifactsSurface} />`)
  await waitFor(() => expect(getPublic).toHaveBeenCalledTimes(1))
  const signal = vi.mocked(getPublic).mock.calls[0]![1]!.signal!
  const originalAuthority = workspace.current.value!
  await act(async () => {
    workspace.current.value = authority('/workspace-b')
    workspace.current.value = originalAuthority
    delayed.resolve({ ...document(first, 'stale public body'), shared: true })
  })
  expect(signal.aborted).toBe(true)
  const reader = within(await screen.findByRole('dialog'))
  expect(reader.getByText(access === 'tokenless' ? 'fresh public read' : 'original body')).toBeTruthy()
  expect(reader.queryByText('stale public body')).toBeNull()
})

it('opens a fresh public observation after workspace authority and credentials are withdrawn', async () => {
  select(firstId)
  render(html`<${ArtifactsSurface} />`)
  await screen.findByRole('dialog')
  vi.mocked(getPublic).mockResolvedValue({ ...document(first, 'public body'), shared: true })
  await act(async () => { setStoredToken('expired-token'); workspace.current.value = null })
  await waitFor(() => expect(getPublic).toHaveBeenCalledTimes(1))
  const reader = within(await screen.findByRole('dialog'))
  expect(await reader.findByText('public body')).toBeTruthy()
  expect(reader.queryByRole('button', { name: '외부 공유 켜기' })).toBeNull()
})

it('keeps a retired draft visible before offering a public reader', async () => {
  vi.mocked(getPublic).mockResolvedValue({ ...document(), shared: true })
  select(firstId)
  render(html`<${ArtifactsSurface} />`)
  fireEvent.click(within(await screen.findByRole('dialog')).getByRole('button', { name: '문서 편집' }))
  await act(async () => { workspace.current.value = null })
  expect(getPublic).not.toHaveBeenCalled()
  expect(screen.getByRole('region', { name: '이전 접근 상태의 원고' })).toBeTruthy()
})

it('keeps a retired draft visible before offering a tokenless public reader with workspace authority', async () => {
  vi.mocked(getPublic).mockResolvedValue({ ...document(), shared: true })
  select(firstId)
  render(html`<${ArtifactsSurface} />`)
  fireEvent.click(within(await screen.findByRole('dialog')).getByRole('button', { name: '문서 편집' }))
  await act(async () => { clearStoredToken() })
  expect(workspace.current.value).not.toBeNull()
  expect(getPublic).not.toHaveBeenCalled()
  expect(screen.queryByRole('dialog')).toBeNull()
  expect(screen.getByRole('region', { name: '이전 접근 상태의 원고' })).toBeTruthy()
})

it('retires a draft even when workspace A to B to A happens before rendering', async () => {
  select(firstId)
  render(html`<${ArtifactsSurface} />`)
  const reader = within(await screen.findByRole('dialog'))
  fireEvent.click(reader.getByRole('button', { name: '문서 편집' }))
  fireEvent.input(reader.getByLabelText('문서 본문'), { target: { value: 'retain this draft' } })
  const originalAuthority = workspace.current.value!
  await act(async () => {
    workspace.current.value = authority('/workspace-b')
    workspace.current.value = originalAuthority
  })
  const recovery = screen.getByRole('region', { name: '이전 접근 상태의 원고' })
  expect(within(recovery).getByText('Original report')).toBeTruthy()
  expect(within(recovery).getByRole('button', { name: '원고 다운로드' })).toBeTruthy()
})

it.each(['workspace', 'worker'] as const)('keeps recovery accessible before opening a new %s reader', async change => {
  const fallback = vi.mocked(get).getMockImplementation()!
  let worker = false
  vi.mocked(get).mockImplementation((path, options) => worker && path === `${list}/${firstId}`
    ? Promise.reject(new ApiRequestError({ method: 'GET', path, status: 403, detail: 'worker denied' }))
    : fallback(path, options))
  vi.mocked(getPublic).mockResolvedValue({ ...document(first, 'public body'), shared: true })
  select(firstId)
  render(html`<${ArtifactsSurface} />`)
  const reader = within(await screen.findByRole('dialog'))
  fireEvent.click(reader.getByRole('button', { name: '문서 편집' }))
  fireEvent.input(reader.getByLabelText('문서 본문'), { target: { value: 'draft to recover' } })
  const selectedReadsBefore = vi.mocked(get).mock.calls.filter(([path]) => path === `${list}/${firstId}`).length
  await act(async () => {
    if (change === 'workspace') workspace.current.value = authority('/workspace-b')
    else { worker = true; setStoredToken('worker-credential') }
  })
  const recovery = within(await screen.findByRole('region', { name: '이전 접근 상태의 원고' }))
  await act(async () => {})
  expect(screen.queryByRole('dialog')).toBeNull()
  expect(recovery.getByRole('button', { name: '원고 다운로드' })).toBeTruthy()
  expect((screen.getByRole('button', { name: '파일 가져오기' }) as HTMLButtonElement).disabled).toBe(true)
  expect(vi.mocked(get).mock.calls.filter(([path]) => path === `${list}/${firstId}`)).toHaveLength(selectedReadsBefore)
  expect(getPublic).not.toHaveBeenCalled()

  const confirm = vi.fn(() => false)
  vi.stubGlobal('confirm', confirm)
  fireEvent.click(recovery.getByRole('button', { name: '원고 폐기' }))
  expect(screen.getByRole('region', { name: '이전 접근 상태의 원고' })).toBeTruthy()
  expect(screen.queryByRole('dialog')).toBeNull()
  confirm.mockReturnValue(true)
  fireEvent.click(recovery.getByRole('button', { name: '원고 폐기' }))
  const replacement = within(await screen.findByRole('dialog'))
  expect(replacement.getByText(change === 'worker' ? 'public body' : 'original body')).toBeTruthy()
  expect((screen.getByRole('button', { name: '파일 가져오기' }) as HTMLButtonElement).disabled).toBe(false)
  if (change === 'worker') expect(getPublic).toHaveBeenCalledTimes(1)
  else expect(getPublic).not.toHaveBeenCalled()
})

it('toggles per-artifact opt-in external sharing from the authenticated reader', async () => {
  let shared = false
  let version = 0
  vi.mocked(get).mockImplementation(async path => path === '/health?full=1'
    ? { paths: { effective_base_path: '/workspace-a', effective_masc_root: '/workspace-a/.masc' } }
    : path === list ? listing() : path === checks ? { checks: [], diagnostics: [] }
      : { ...document(), shared, share_version: version })
  vi.mocked(post).mockImplementation(async (_path, body) => {
    const payload = body as { shared: boolean; operation_id: string; expected_version: number }
    shared = payload.shared
    version++
    const snapshot = { version, shared }
    return { id: firstId, receipt: { operation_id: payload.operation_id, expected_version: payload.expected_version,
      requested: shared, outcome: 'applied', snapshot }, current: snapshot }
  })
  select(firstId)
  render(html`<${ArtifactsSurface} />`)
  const reader = within(await screen.findByRole('dialog'))
  expect(reader.getByText('외부 공유는 이 문서의 모든 버전에 적용됩니다.')).toBeTruthy()
  fireEvent.click(reader.getByRole('button', { name: '외부 공유 켜기' }))
  const headers = { 'x-masc-expected-base-path': '/workspace-a', 'x-masc-expected-masc-root': '/workspace-a/.masc' }
  const expected_workspace = { base_path: '/workspace-a', masc_root: '/workspace-a/.masc' }
  await waitFor(() => expect(post).toHaveBeenCalledWith('/api/v1/published-artifact-shares', expect.objectContaining({ id: firstId, shared: true, expected_version: 0, operation_id: expect.any(String), expected_workspace }), headers))
  await waitFor(() => expect(copyToClipboard).toHaveBeenCalledWith(
    `${window.location.origin}/dashboard/#/workspace?section=artifacts&artifact=${firstId}&revision=2`,
    screen.getByRole('dialog'),
  ))
  expect(await reader.findByRole('button', { name: '외부 공유 해제' })).toBeTruthy()
  fireEvent.click(reader.getByRole('button', { name: '외부 공유 해제' }))
  await waitFor(() => expect(post).toHaveBeenCalledWith('/api/v1/published-artifact-shares', expect.objectContaining({ id: firstId, shared: false, expected_version: 1, operation_id: expect.any(String), expected_workspace }), headers))
  expect(await reader.findByRole('button', { name: '외부 공유 켜기' })).toBeTruthy()
})

it('cannot infer private sharing from a response without a share state', async () => {
  const { shared: _omitted, ...unknown } = document()
  vi.mocked(get).mockImplementation(async path => path === list ? listing() : path === checks
    ? { checks: [], diagnostics: [] } : unknown)
  select(firstId)
  render(html`<${ArtifactsSurface} />`)
  const reader = within(await screen.findByRole('dialog'))
  const toggle = reader.getByRole('button', { name: '외부 공유 상태 미확인' }) as HTMLButtonElement
  expect(toggle.disabled).toBe(true)
  fireEvent.click(toggle)
  expect(post).not.toHaveBeenCalled()
})

it('refuses to send a stale toggle after a workspace-bound reread changes state', async () => {
  let reads = 0
  vi.mocked(get).mockImplementation(async path => path === '/health?full=1'
    ? { paths: { effective_base_path: '/workspace-a', effective_masc_root: '/workspace-a/.masc' } }
    : path === list ? listing() : path === checks ? { checks: [], diagnostics: [] }
      : { ...document(), shared: ++reads > 1 })
  select(firstId)
  render(html`<${ArtifactsSurface} />`)
  const reader = within(await screen.findByRole('dialog'))
  fireEvent.click(reader.getByRole('button', { name: '외부 공유 켜기' }))
  await waitFor(() => expect(screen.getByRole('button', { name: '외부 공유 해제' })).toBeTruthy())
  await reader.findByText(/요청을 보내지 않았습니다/)
  expect(post).not.toHaveBeenCalled()
  expect(await reader.findByRole('button', { name: '외부 공유 해제' })).toBeTruthy()
})

it('refuses an ABA sharing change even when the boolean returned to its earlier value', async () => {
  let reads = 0
  vi.mocked(get).mockImplementation(async path => path === '/health?full=1'
    ? { paths: { effective_base_path: '/workspace-a', effective_masc_root: '/workspace-a/.masc' } }
    : path === list ? listing() : path === checks ? { checks: [], diagnostics: [] }
      : { ...document(), share_version: ++reads > 1 ? 2 : 0 })
  select(firstId)
  render(html`<${ArtifactsSurface} />`)
  const reader = within(await screen.findByRole('dialog'))
  fireEvent.click(reader.getByRole('button', { name: '외부 공유 켜기' }))
  await reader.findByText(/요청을 보내지 않았습니다/)
  expect(post).not.toHaveBeenCalled()
})

it('does not send a share request when browser recovery storage is unavailable', async () => {
  vi.stubGlobal('localStorage', { length: 0, key: () => null, getItem: () => null,
    setItem: () => { throw new Error('quota') }, removeItem: () => {} })
  vi.mocked(get).mockImplementation(async path => path === '/health?full=1'
    ? { paths: { effective_base_path: '/workspace-a', effective_masc_root: '/workspace-a/.masc' } }
    : path === list ? listing() : path === checks ? { checks: [], diagnostics: [] } : document())
  select(firstId)
  render(html`<${ArtifactsSurface} />`)
  const reader = within(await screen.findByRole('dialog'))
  fireEvent.click(reader.getByRole('button', { name: '외부 공유 켜기' }))
  await reader.findByText(/보관하지 못해 전송하지 않았습니다/)
  expect(post).not.toHaveBeenCalled()
})

it('offers an already retained operation after a new reader is mounted', async () => {
  const operation = { id: firstId, operationId: '01890e2a-4c8e-7b21-9f3c-000000000099', expectedVersion: 0, shared: true }
  retainPendingShare({ operation, workspace: { basePath: '/workspace-a', mascRoot: '/workspace-a/.masc' }, title: first.title, revision: 2 })
  window.dispatchEvent(new StorageEvent('storage'))
  vi.mocked(get).mockImplementation(async path => path === '/health?full=1'
    ? { paths: { effective_base_path: '/workspace-a', effective_masc_root: '/workspace-a/.masc' } }
    : path === list ? listing() : path === checks ? { checks: [], diagnostics: [] } : document())
  vi.mocked(post).mockImplementation(async () => shareReply(firstId))
  select(firstId)
  render(html`<${ArtifactsSurface} />`)
  const reader = within(await screen.findByRole('dialog'))
  expect((reader.getByRole('button', { name: '외부 공유 상태 미확인' }) as HTMLButtonElement).disabled).toBe(true)
  fireEvent.click(reader.getByRole('button', { name: '같은 요청 확인' }))
  await waitFor(() => expect(post).toHaveBeenCalledWith('/api/v1/published-artifact-shares', expect.objectContaining({
    id: firstId, operation_id: operation.operationId, expected_version: 0, shared: true,
  }), expect.any(Object)))
  await waitFor(() => expect(reader.queryByRole('button', { name: '같은 요청 확인' })).toBeNull())
})

it('does not send a share change when the server reports a different workspace', async () => {
  vi.mocked(get).mockImplementation(async path => path === '/health?full=1'
    ? { paths: { effective_base_path: '/workspace-b', effective_masc_root: '/workspace-b/.masc' } }
    : path === list ? listing() : path === checks ? { checks: [], diagnostics: [] } : document())
  select(firstId)
  render(html`<${ArtifactsSurface} />`)
  const reader = within(await screen.findByRole('dialog'))
  fireEvent.click(reader.getByRole('button', { name: '외부 공유 켜기' }))
  await reader.findByText(/요청을 보내지 않았습니다/)
  expect(post).not.toHaveBeenCalled()
})

it('does not share a newer latest revision that the operator has not opened', async () => {
  let reads = 0
  const newer = { ...first, revision: 3, body: { _blob: { sha256: 'd'.repeat(64) } } }
  vi.mocked(get).mockImplementation(async path => path === '/health?full=1'
    ? { paths: { effective_base_path: '/workspace-a', effective_masc_root: '/workspace-a/.masc' } }
    : path === list ? listing() : path === checks ? { checks: [], diagnostics: [] }
      : document(++reads > 1 ? newer : first))
  select(firstId)
  render(html`<${ArtifactsSurface} />`)
  const reader = within(await screen.findByRole('dialog'))
  fireEvent.click(reader.getByRole('button', { name: '외부 공유 켜기' }))
  await reader.findByText(/요청을 보내지 않았습니다/)
  await waitFor(() => expect(reader.getByRole('combobox', { name: '문서 버전' }).textContent).toContain('v3'))
  expect(reader.getByRole('status').textContent).toContain('요청을 보내지 않았습니다')
  expect(post).not.toHaveBeenCalled()
  expect(get).toHaveBeenCalledWith(`/api/v1/published-artifacts/${firstId}`, {
    signal: undefined,
    extraHeaders: { 'x-masc-expected-base-path': '/workspace-a', 'x-masc-expected-masc-root': '/workspace-a/.masc' },
  })
})

it('does not show a refused preflight in a different artifact reader', async () => {
  const preflight = pending()
  vi.mocked(get).mockImplementation((path, options) => {
    if (path === '/health?full=1') return Promise.resolve({ paths: { effective_base_path: '/workspace-a', effective_masc_root: '/workspace-a/.masc' } })
    if (path === list) return Promise.resolve(listing())
    if (path === checks) return Promise.resolve({ checks: [], diagnostics: [] })
    if (path.includes(firstId) && options?.extraHeaders) return preflight.promise
    return Promise.resolve(document(path.includes(secondId) ? second : first))
  })
  select(firstId)
  render(html`<${ArtifactsSurface} />`)
  fireEvent.click(within(await screen.findByRole('dialog')).getByRole('button', { name: '외부 공유 켜기' }))
  await waitFor(() => expect(vi.mocked(get).mock.calls.some(([path, options]) => path.includes(firstId) && !!options?.extraHeaders)).toBe(true))
  await act(async () => { select(secondId) })
  await screen.findByRole('heading', { name: second.title })
  await act(async () => { preflight.resolve(document()) })
  expect(post).not.toHaveBeenCalled()
  expect(within(screen.getByRole('dialog')).queryByText(/요청을 보내지 않았습니다/)).toBeNull()
})

it('does not send an old share preflight after a batched A to B to A visit', async () => {
  const preflight = pending()
  vi.mocked(get).mockImplementation((path, options) => {
    if (path === '/health?full=1') return Promise.resolve({ paths: { effective_base_path: '/workspace-a', effective_masc_root: '/workspace-a/.masc' } })
    if (path === list) return Promise.resolve(listing())
    if (path === checks) return Promise.resolve({ checks: [], diagnostics: [] })
    if (path.includes(firstId) && options?.extraHeaders) return preflight.promise
    return Promise.resolve(document(path.includes(secondId) ? second : first))
  })
  select(firstId)
  render(html`<${ArtifactsSurface} />`)
  fireEvent.click(within(await screen.findByRole('dialog')).getByRole('button', { name: '외부 공유 켜기' }))
  await waitFor(() => expect(vi.mocked(get).mock.calls.some(([path, options]) => path.includes(firstId) && !!options?.extraHeaders)).toBe(true))
  await act(async () => {
    select(secondId)
    select(firstId)
    preflight.resolve(document())
  })
  expect(post).not.toHaveBeenCalled()
  expect(within(await screen.findByRole('dialog')).queryByText(/요청을 보내지 않았습니다/)).toBeNull()
})

it('keeps the operation and link copy through a same-revision refresh while the write is pending', async () => {
  const request = pending()
  let shared = false
  let reads = 0
  vi.mocked(post).mockReturnValue(request.promise)
  vi.mocked(get).mockImplementation(async path => path === '/health?full=1'
    ? { paths: { effective_base_path: '/workspace-a', effective_masc_root: '/workspace-a/.masc' } }
    : path === list ? listing() : path === checks ? { checks: [], diagnostics: [] }
      : (reads++, { ...document(), shared }))
  select(firstId)
  render(html`<${ArtifactsSurface} />`)
  fireEvent.click(within(await screen.findByRole('dialog')).getByRole('button', { name: '외부 공유 켜기' }))
  await waitFor(() => expect(post).toHaveBeenCalledTimes(1))
  const before = reads
  fireEvent.click(screen.getByRole('button', { name: '새로고침' }))
  await waitFor(() => expect(reads).toBeGreaterThan(before))
  shared = true
  await act(async () => { request.resolve(shareReply(firstId)) })
  await waitFor(() => expect(copyToClipboard).toHaveBeenCalledTimes(1))
})

it('keeps a lost share result unconfirmed after a workspace change and reread', async () => {
  const id = `artifact-${'c'.repeat(32)}`
  const report = { ...first, id }
  const request = pending()
  vi.mocked(post).mockReturnValue(request.promise)
  vi.mocked(get).mockImplementation(async path => path === '/health?full=1'
    ? { paths: { effective_base_path: '/workspace-a', effective_masc_root: '/workspace-a/.masc' } }
    : path === list ? listing([report, second]) : path === checks ? { checks: [], diagnostics: [] }
      : document(report))
  select(id)
  render(html`<${ArtifactsSurface} />`)
  fireEvent.click(within(await screen.findByRole('dialog')).getByRole('button', { name: '외부 공유 켜기' }))
  await waitFor(() => expect(post).toHaveBeenCalledTimes(1))
  await act(async () => { workspace.current.value = authority('/workspace-b') })
  await act(async () => { workspace.current.value = authority('/workspace-a') })
  await screen.findByRole('dialog')
  await act(async () => { request.reject(new Error('timeout')) })
  const receipt = await waitFor(() => {
    const region = within(screen.getByRole('dialog')).getByRole('region', { name: '외부 공유 요청 결과' })
    const row = Array.from(region.querySelectorAll('p')).find(item => item.textContent?.includes(id) && item.textContent?.includes('적용 여부 미확인'))
    expect(row).toBeDefined()
    return row!
  })
  expect(receipt.textContent).toContain('원래 작업 공간 /workspace-a')
  expect(receipt.textContent).toContain('요청: 외부 공유 켜기')
  expect(receipt.textContent).toContain('적용 여부 미확인: timeout')
  const reader = within(screen.getByRole('dialog'))
  const toggle = await reader.findByRole('button', { name: '외부 공유 상태 미확인' }) as HTMLButtonElement
  expect(toggle.disabled).toBe(true)
  fireEvent.click(toggle)
  expect(post).toHaveBeenCalledTimes(1)
  const sent = vi.mocked(post).mock.calls[0]![1]
  vi.mocked(post).mockImplementationOnce(async (_path, body) => {
    expect(body).toEqual(sent)
    return shareReply(id)
  })
  fireEvent.click(reader.getByRole('button', { name: '같은 요청 확인' }))
  await waitFor(() => expect(post).toHaveBeenCalledTimes(2))
  await waitFor(() => expect(reader.queryByRole('button', { name: '같은 요청 확인' })).toBeNull())
})

it.each(['confirmed', 'unconfirmed'] as const)('shows a prior owner share %s result inside the public reader without copying', async result => {
  const id = `artifact-${(result === 'confirmed' ? '1' : '2').repeat(32)}`
  const report = { ...first, id }
  const request = pending()
  let worker = false
  vi.mocked(post).mockReturnValue(request.promise)
  vi.mocked(get).mockImplementation(async path => {
    if (path === '/health?full=1') return { paths: { effective_base_path: '/workspace-a', effective_masc_root: '/workspace-a/.masc' } }
    if (path === list) return listing([report])
    if (path === checks) return { checks: [], diagnostics: [] }
    if (worker) throw new ApiRequestError({ method: 'GET', path, status: 403, detail: 'worker denied' })
    return document(report)
  })
  vi.mocked(getPublic).mockResolvedValue({ ...document(report, 'public body'), shared: true })
  select(id)
  render(html`<${ArtifactsSurface} />`)
  fireEvent.click(within(await screen.findByRole('dialog')).getByRole('button', { name: '외부 공유 켜기' }))
  await waitFor(() => expect(post).toHaveBeenCalledTimes(1))
  await act(async () => { worker = true; setStoredToken('worker-credential') })
  const publicReader = within(await screen.findByRole('dialog'))
  expect(publicReader.getByText('public body')).toBeTruthy()
  expect(publicReader.getByText('외부 공유 열람')).toBeTruthy()
  await act(async () => {
    if (result === 'confirmed') request.resolve(shareReply(id))
    else request.reject(new Error('lost response'))
  })
  const receipt = await waitFor(() => {
    const region = publicReader.getByRole('region', { name: '외부 공유 요청 결과' })
    const row = Array.from(region.querySelectorAll('p')).find(item => item.textContent?.includes(id) && item.textContent?.includes('요청:'))
    expect(row).toBeDefined()
    return row!
  }, { timeout: 500 })
  expect(receipt.textContent).toContain('원래 작업 공간 /workspace-a (/workspace-a/.masc)')
  expect(receipt.textContent).toContain('요청: 외부 공유 켜기')
  expect(receipt.textContent).toContain(result === 'confirmed' ? '요청 적용: 당시 공유 켜짐' : '적용 여부 미확인: lost response')
  expect(copyToClipboard).not.toHaveBeenCalled()
  expect(post).toHaveBeenCalledTimes(1)
})

it('retains a confirmed share result for the original selection after navigating away', async () => {
  const id = `artifact-${'e'.repeat(32)}`
  const report = { ...first, id }
  const request = pending()
  vi.mocked(post).mockReturnValue(request.promise)
  vi.mocked(get).mockImplementation(async path => path === '/health?full=1'
    ? { paths: { effective_base_path: '/workspace-a', effective_masc_root: '/workspace-a/.masc' } }
    : path === list ? listing([report, second]) : path === checks ? { checks: [], diagnostics: [] }
      : document(path.includes(secondId) ? second : report))
  select(id)
  render(html`<${ArtifactsSurface} />`)
  fireEvent.click(within(await screen.findByRole('dialog')).getByRole('button', { name: '외부 공유 켜기' }))
  await waitFor(() => expect(post).toHaveBeenCalledTimes(1))
  await act(async () => { select(secondId) })
  await screen.findByRole('heading', { name: second.title })
  const before = reads()
  await act(async () => { request.resolve(shareReply(id)) })
  const receipt = await waitFor(() => {
    const region = within(screen.getByRole('dialog')).getByRole('region', { name: '외부 공유 요청 결과' })
    const row = Array.from(region.querySelectorAll('p')).find(item => item.textContent?.includes(id) && item.textContent?.includes('요청:'))
    expect(row).toBeDefined()
    return row!
  })
  expect(receipt.textContent).toContain('요청 적용: 당시 공유 켜짐')
  expect(reads()).toBe(before)
  expect(copyToClipboard).not.toHaveBeenCalled()
})

it('rereads the same artifact reopened while its earlier share request is pending', async () => {
  const id = `artifact-${'f'.repeat(32)}`
  const report = { ...first, id }
  const request = pending()
  let shared = false
  vi.mocked(post).mockReturnValue(request.promise)
  vi.mocked(get).mockImplementation(async path => path === '/health?full=1'
    ? { paths: { effective_base_path: '/workspace-a', effective_masc_root: '/workspace-a/.masc' } }
    : path === list ? listing([report]) : path === checks ? { checks: [], diagnostics: [] }
      : { ...document(report), shared, share_version: shared ? 1 : 0 })
  select(id)
  render(html`<${ArtifactsSurface} />`)
  fireEvent.click(within(await screen.findByRole('dialog')).getByRole('button', { name: '외부 공유 켜기' }))
  await waitFor(() => expect(post).toHaveBeenCalledTimes(1))
  await act(async () => { select() })
  await act(async () => { select(id) })
  const reader = within(await screen.findByRole('dialog'))
  expect((reader.getByRole('button', { name: '외부 공유 상태 미확인' }) as HTMLButtonElement).disabled).toBe(true)
  shared = true
  await act(async () => { request.resolve(shareReply(id)) })
  expect(await reader.findByRole('button', { name: '외부 공유 해제' })).toBeTruthy()
  expect(copyToClipboard).not.toHaveBeenCalled()
})

it('withdraws the ready inventory, document, checks and preview immediately on workspace loss', async () => {
  select(firstId)
  render(html`<${ArtifactsSurface} />`)
  await screen.findByRole('dialog')
  fireEvent.click(screen.getByRole('button', { name: 'HTML 미리보기' }))
  await screen.findByTitle('HTML report 빠른 미리보기')
  await act(async () => { workspace.current.value = null })
  expect(screen.queryByRole('dialog')).toBeNull()
  expect(screen.queryByTitle('HTML report 빠른 미리보기')).toBeNull()
  expect(screen.queryByRole('button', { name: /Original report/ })).toBeNull()
  expect(screen.queryByRole('button', { name: '○ 미확인' })).toBeNull()
})

it('starts a new observation for an equal-valued replacement authority', async () => {
  render(html`<${ArtifactsSurface} />`)
  await screen.findByRole('button', { name: /Original report/ })
  const fresh = pending()
  vi.mocked(get).mockImplementation(path => path === list ? fresh.promise : Promise.resolve({ checks: [], diagnostics: [] }))
  const before = reads()
  await act(async () => { workspace.current.value = authority() })
  expect(screen.queryByRole('button', { name: /Original report/ })).toBeNull()
  await waitFor(() => expect(reads()).toBeGreaterThan(before))
  await act(async () => fresh.resolve(listing([{ ...first, title: 'fresh catalog' }])))
  await screen.findByRole('button', { name: /fresh catalog/ })
})

it('rejects workspace A to B to A late catalog success, document error and checks error', async () => {
  const oldList = pending(), oldDocument = pending(), oldChecks = pending()
  vi.mocked(get).mockImplementation(path => path === list ? oldList.promise : path === checks ? oldChecks.promise : oldDocument.promise)
  select(firstId); render(html`<${ArtifactsSurface} />`)
  await waitFor(() => expect(reads()).toBe(3))
  vi.mocked(get).mockImplementation(async path => path === list ? listing([{ ...first, title: 'fresh report' }]) : path === checks
    ? { checks: [], diagnostics: [] } : document({ ...first, title: 'fresh report' }, 'fresh body'))
  await act(async () => { workspace.current.value = authority('/workspace-b') })
  await act(async () => { workspace.current.value = authority() })
  await screen.findByRole('heading', { name: 'fresh report' })
  await act(async () => { oldList.resolve(listing([{ ...first, title: 'retired catalog' }])); oldDocument.reject(new Error('retired document')); oldChecks.reject(new Error('retired checks')) })
  expect(screen.queryByText(/retired/)).toBeNull()
  expect(screen.getByRole('heading', { name: 'fresh report' })).toBeTruthy()
})

it('does not revive the earlier ready document through selection A to B to A', async () => {
  select(firstId); render(html`<${ArtifactsSurface} />`)
  await screen.findByRole('dialog')
  expect(screen.getByText('original body')).toBeTruthy()
  const fresh = pending()
  vi.mocked(get).mockImplementation(path => path === list ? Promise.resolve(listing()) : path === checks
    ? Promise.resolve({ checks: [], diagnostics: [] }) : fresh.promise)
  await act(async () => select(secondId))
  await act(async () => select(firstId))
  expect(screen.queryByText('original body')).toBeNull()
  await act(async () => fresh.resolve(document(first, 'fresh body')))
  await screen.findByText('fresh body')
})

it('retains a sent check receipt with the original workspace, document, revision and hash without refreshing its successor', async () => {
  const sent = pending(); vi.mocked(post).mockReturnValue(sent.promise)
  select(firstId); render(html`<${ArtifactsSurface} />`)
  const reader = within(await screen.findByRole('dialog'))
  fireEvent.click(await reader.findByRole('button', { name: '○ 미확인' }))
  await waitFor(() => expect(post).toHaveBeenCalledTimes(1))
  await act(async () => { workspace.current.value = authority('/workspace-b') })
  await screen.findByRole('dialog')
  const before = reads()
  await act(async () => sent.resolve({ check: checkReceipt }))
  const receipt = (await screen.findByRole('region', { name: '문서 확인 요청 결과' })).textContent
  expect(receipt).toContain('/workspace-a'); expect(receipt).toContain(firstId)
  expect(receipt).toContain('v2'); expect(receipt).toContain(first.body._blob.sha256)
  expect(receipt).toContain('original-human')
  expect(reads()).toBe(before); expect(post).toHaveBeenCalledTimes(1)
})

it('retains an unconfirmed sent check outcome after authority loss without claiming a rollback or retrying', async () => {
  const sent = pending(); vi.mocked(post).mockReturnValue(sent.promise)
  render(html`<${ArtifactsSurface} />`)
  fireEvent.click((await screen.findAllByRole('button', { name: '○ 미확인' }))[0]!)
  await waitFor(() => expect(post).toHaveBeenCalledTimes(1))
  await act(async () => { workspace.current.value = null })
  const before = reads()
  await act(async () => sent.reject(new Error('transport failed after send')))
  const receipt = (await screen.findByRole('region', { name: '문서 확인 요청 결과' })).textContent
  expect(receipt).toContain('적용 여부 미확인'); expect(receipt).toContain('transport failed after send')
  expect(receipt).toContain(firstId); expect(receipt).toContain(first.body._blob.sha256)
  expect(reads()).toBe(before); expect(post).toHaveBeenCalledTimes(1)
})

it('rejects an old preview error after a workspace transition and preserves the new preview', async () => {
  const old = pending()
  const fallback = vi.mocked(get).getMockImplementation()!
  vi.mocked(get).mockImplementation((path, options) => path.includes(secondId) ? old.promise : fallback(path, options))
  render(html`<${ArtifactsSurface} />`)
  fireEvent.click(await screen.findByRole('button', { name: 'HTML 미리보기' }))
  await waitFor(() => expect(vi.mocked(get).mock.calls.some(([path]) => path.includes(secondId))).toBe(true))
  vi.mocked(get).mockImplementation(fallback)
  await act(async () => { workspace.current.value = authority('/workspace-b') })
  fireEvent.click(await screen.findByRole('button', { name: 'HTML 미리보기' }))
  await screen.findByTitle('HTML report 빠른 미리보기')
  await act(async () => old.reject(new Error('retired preview failure')))
  expect(screen.queryByText(/retired preview/)).toBeNull()
  expect(screen.getByTitle('HTML report 빠른 미리보기')).toBeTruthy()
})

it('rejects an old successful check inventory through authentication A to B to A', async () => {
  const old = pending()
  const fallback = vi.mocked(get).getMockImplementation()!
  vi.mocked(get).mockImplementation((path, options) => path === checks ? old.promise : fallback(path, options))
  render(html`<${ArtifactsSurface} />`)
  await screen.findByRole('button', { name: /Original report/ })
  vi.mocked(get).mockImplementation(fallback)
  await act(async () => setStoredToken('credential-b'))
  await act(async () => setStoredToken('credential-a'))
  await screen.findAllByRole('button', { name: '○ 미확인' })
  await act(async () => old.resolve({ checks: [checkReceipt], diagnostics: [] }))
  expect(screen.queryByText(/original-human/)).toBeNull()
  expect(screen.queryByRole('button', { name: '✓ 확인함' })).toBeNull()
})

it('preserves a sent reader check for the original selection without refreshing the replacement selection', async () => {
  const sent = pending(); vi.mocked(post).mockReturnValue(sent.promise)
  select(firstId); render(html`<${ArtifactsSurface} />`)
  fireEvent.click(await within(await screen.findByRole('dialog')).findByRole('button', { name: '○ 미확인' }))
  await waitFor(() => expect(post).toHaveBeenCalledTimes(1))
  await act(async () => select(secondId))
  await screen.findByRole('heading', { name: 'HTML report' })
  const before = reads()
  await act(async () => sent.resolve({ check: checkReceipt }))
  const receipt = await screen.findByRole('region', { name: '문서 확인 요청 결과' })
  expect(receipt.textContent).toContain(firstId)
  expect(receipt.textContent).not.toContain(secondId)
  expect(reads()).toBe(before); expect(post).toHaveBeenCalledTimes(1)
})
