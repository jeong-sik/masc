import { html } from 'htm/preact'
import type { Signal } from '@preact/signals'
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/preact'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { get, post, clearStoredToken, setStoredToken } from '../../api/core'
import { executionWorkspaceAuthority, type ExecutionWorkspaceAuthority } from '../../store'
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
const document = (artifact = first, content = 'original body') => ({ artifact, content, revisions: [artifact] })
const listing = (artifacts = [first, second]) => ({ artifacts, diagnostics: [] })
const select = (id?: string) => { route.value = { tab: 'workspace', params: { section: 'artifacts', ...(id ? { artifact: id } : {}) }, postId: null } }
const checks = '/api/v1/published-artifact-checks'
const list = '/api/v1/published-artifacts'
const reads = () => vi.mocked(get).mock.calls.length
const checkReceipt = { id: firstId, revision: 2, body_sha256: first.body._blob.sha256, checked: true,
  change_id: `check-${'c'.repeat(32)}`, changed_by: 'original-human', changed_at: '2026-10-22T01:00:00Z' }

beforeEach(() => {
  expect(executionWorkspaceAuthority).toBe(workspace.current)
  vi.mocked(get).mockReset(); vi.mocked(post).mockReset()
  setStoredToken('credential-a'); workspace.current.value = authority(); select()
  vi.mocked(get).mockImplementation(async path => path === list ? listing() : path === checks
    ? { checks: [], diagnostics: [] } : document(path.includes(secondId) ? second : first))
})
afterEach(() => { cleanup(); clearStoredToken() })

it('waits without reading or inventing an empty catalog when workspace authority is unknown', async () => {
  workspace.current.value = null
  render(html`<${ArtifactsSurface} />`)
  await act(async () => {})
  expect(get).not.toHaveBeenCalled()
  expect(screen.queryByText(/아직 게시된 아티팩트가 없습니다/)).toBeNull()
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
