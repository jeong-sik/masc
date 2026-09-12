import { html } from 'htm/preact'
import { act, render, cleanup, fireEvent, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { fetchEditSnapshots } from '../../api/edit-snapshots'
import { computeEditSnapshotDiff } from './edit-snapshot-diff-engine'
import { ChatEditEvidence } from './edit-evidence'
import type { ToolCallEntry } from '../../api/dashboard'
import { ApiRequestError, clearStoredToken, setStoredToken } from '../../api/core'
import { fetchVerifiedToolBlobText } from '../../api/verified-tool-blob'

vi.mock('../../api/verified-tool-blob', () => ({ fetchVerifiedToolBlobText: vi.fn() }))

vi.mock('../../api/edit-snapshots', async importOriginal => ({
  ...await importOriginal<typeof import('../../api/edit-snapshots')>(),
  fetchEditSnapshots: vi.fn(),
}))
class DiffWorker {
  static instances: DiffWorker[] = []
  static defer = false
  onmessage: ((event: { data: string }) => void) | null = null
  onerror = null
  onmessageerror = null
  terminated = false
  terminate = vi.fn(() => { this.terminated = true })
  constructor() { DiffWorker.instances.push(this) }
  postMessage({ before, after }: { before: string; after: string }) {
    if (!DiffWorker.defer) queueMicrotask(() => {
      if (!this.terminated) this.onmessage?.({ data: computeEditSnapshotDiff(before, after) })
    })
  }
}
beforeEach(() => {
  clearStoredToken()
  DiffWorker.instances = []
  DiffWorker.defer = false
  vi.stubGlobal('Worker', DiffWorker)
})
afterEach(() => { cleanup(); clearStoredToken(); vi.resetAllMocks(); vi.unstubAllGlobals() })
const ref = { _blob: { sha256: 'a'.repeat(64), bytes: 3 } }
const receipt: ToolCallEntry = {
  ts: 1, keeper: 'writer', tool: 'Edit', success: true, duration_ms: 3,
  input: {}, route_evidence: { descriptor_id: 'agent.edit_file' },
  output: JSON.stringify({ ok: true, mode: 'patch', path: 'essay.md', occurrences: 1,
    edit_snapshots: { status: 'stored', before: ref, after: ref } }),
}

it('retries a denied manifest only after credentials change', async () => {
  vi.mocked(fetchVerifiedToolBlobText)
    .mockRejectedValueOnce(new ApiRequestError({ method: 'GET', path: '/artifacts/sha', status: 403 }))
    .mockResolvedValue(receipt.output as string)
  const output = { ...receipt, output: { _blob: { ...ref._blob, mime: 'application/json' } } }
  const view = render(html`<${ChatEditEvidence} output=${output} />`)
  await waitFor(() => expect(view.getByRole('alert').textContent).toContain('관리자 권한'))
  expect(fetchVerifiedToolBlobText).toHaveBeenCalledTimes(1)
  act(() => setStoredToken('fixture-admin'))
  await waitFor(() => expect(view.getByRole('button', { name: '편집 전후 원본 보기' })).toBeTruthy())
  expect(fetchVerifiedToolBlobText).toHaveBeenCalledTimes(2)
})

it('discards a late Admin manifest when the replacement credentials are denied', async () => {
  setStoredToken('fixture-admin')
  let complete!: (text: string) => void
  vi.mocked(fetchVerifiedToolBlobText)
    .mockReturnValueOnce(new Promise(resolve => { complete = resolve }))
    .mockRejectedValue(new ApiRequestError({ method: 'GET', path: '/artifacts/sha', status: 403 }))
  const output = { ...receipt, output: { _blob: { ...ref._blob, mime: 'application/json' } } }
  const view = render(html`<${ChatEditEvidence} output=${output} />`)
  await waitFor(() => expect(fetchVerifiedToolBlobText).toHaveBeenCalledOnce())
  act(() => setStoredToken('fixture-worker'))
  complete(receipt.output as string)
  await waitFor(() => expect(view.getByRole('alert').textContent).toContain('관리자 권한'))
  expect(view.queryByRole('button', { name: '편집 전후 원본 보기' })).toBeNull()
  expect(view.queryByText('essay.md · 1곳 편집')).toBeNull()
})

it('opens full originals even when recorded input snippets are unavailable', async () => {
  vi.mocked(fetchEditSnapshots).mockResolvedValue({ before: '\told\r\n', after: '<b>new</b>\r\n' })
  const view = render(html`<${ChatEditEvidence} output=${receipt} />`)
  expect(fetchEditSnapshots).not.toHaveBeenCalled()
  fireEvent.click(view.getByRole('button', { name: '편집 전후 원본 보기' }))
  await waitFor(() => expect(view.getByLabelText('편집 후 전체 원본').textContent).toBe('<b>new</b>\r\n'))
  expect(view.getByLabelText('편집 후 전체 원본').querySelector('b')).toBeNull()
  expect(view.getByLabelText('편집 원본의 Unified diff').textContent).toContain('-\told\r\n+<b>new</b>\r\n')
  view.getByLabelText('편집 전 전체 원본').focus()
  expect(document.activeElement).toBe(view.getByLabelText('편집 전 전체 원본'))
  fireEvent.click(view.getByRole('button', { name: '편집 원본 닫기' }))
  expect(view.queryByLabelText('편집 전 전체 원본')).toBeNull()
})

it('shows retrieval failure and lets the operator close and retry', async () => {
  vi.mocked(fetchEditSnapshots).mockRejectedValueOnce(new Error('원본을 찾을 수 없습니다.'))
  const view = render(html`<${ChatEditEvidence} output=${receipt} />`)
  fireEvent.click(view.getByRole('button'))
  await waitFor(() => expect(view.getByRole('alert').textContent).toContain('원본을 찾을 수 없습니다.'))
  expect(view.queryByLabelText('편집 전 전체 원본')).toBeNull()
  fireEvent.click(view.getByRole('button'))
  vi.mocked(fetchEditSnapshots).mockResolvedValueOnce({ before: 'old', after: 'new' })
  fireEvent.click(view.getByRole('button'))
  await waitFor(() => expect(view.getByLabelText('편집 후 전체 원본').textContent).toBe('new'))
})

it('discards visible originals after a credential change and permits a fresh authorized read', async () => {
  setStoredToken('fixture-admin')
  vi.mocked(fetchEditSnapshots).mockResolvedValueOnce({ before: 'private-before', after: 'private-after' })
    .mockRejectedValueOnce(new ApiRequestError({ method: 'GET', path: '/artifacts/sha', status: 403 }))
    .mockResolvedValue({ before: 'new-before', after: 'new-after' })
  const view = render(html`<${ChatEditEvidence} output=${receipt} />`)
  fireEvent.click(view.getByRole('button', { name: '편집 전후 원본 보기' }))
  await waitFor(() => expect(view.getByLabelText('편집 전 전체 원본').textContent).toBe('private-before'))
  act(() => setStoredToken('fixture-worker'))
  expect(view.queryByText('private-before')).toBeNull()
  fireEvent.click(view.getByRole('button', { name: '편집 전후 원본 보기' }))
  await waitFor(() => expect(view.getByRole('alert').textContent).toContain('관리자 권한'))
  act(() => setStoredToken('fixture-new-admin'))
  fireEvent.click(view.getByRole('button', { name: '편집 전후 원본 보기' }))
  await waitFor(() => expect(view.getByLabelText('편집 전 전체 원본').textContent).toBe('new-before'))
})

it.each([401, 403])('requires administrator credentials for snapshot HTTP %i without retry', async status => {
  vi.mocked(fetchEditSnapshots).mockRejectedValue(new ApiRequestError({ method: 'GET', path: '/artifacts/sha', status }))
  const view = render(html`<${ChatEditEvidence} output=${receipt} />`)
  fireEvent.click(view.getByRole('button', { name: '편집 전후 원본 보기' }))
  await waitFor(() => expect(view.getByRole('alert').textContent).toContain('관리자 권한'))
  expect(view.queryByRole('button')).toBeNull()
  expect(view.queryByLabelText('편집 전 전체 원본')).toBeNull()
  expect(fetchEditSnapshots).toHaveBeenCalledTimes(1)
})

it('shows a final-newline-only edit in the verified originals diff', async () => {
  vi.mocked(fetchEditSnapshots).mockResolvedValue({ before: 'same\n', after: 'same' })
  const view = render(html`<${ChatEditEvidence} output=${receipt} />`)
  fireEvent.click(view.getByRole('button'))
  await waitFor(() => expect(view.getByLabelText('편집 원본의 Unified diff').textContent).toContain('\\ No newline at end of file'))
  expect(view.getByLabelText('편집 원본의 Unified diff').textContent).toContain('-same\n+same\n')
})

it('terminates comparison when closed and gives a reopened comparison a fresh worker', async () => {
  DiffWorker.defer = true
  vi.mocked(fetchEditSnapshots).mockResolvedValue({ before: 'old', after: 'new' })
  const view = render(html`<${ChatEditEvidence} output=${receipt} />`)
  fireEvent.click(view.getByRole('button'))
  await waitFor(() => expect(DiffWorker.instances).toHaveLength(1))
  const first = DiffWorker.instances[0]!
  fireEvent.click(view.getByRole('button'))
  expect(first.terminate).toHaveBeenCalledOnce()
  fireEvent.click(view.getByRole('button'))
  await waitFor(() => expect(DiffWorker.instances).toHaveLength(2))
  expect(DiffWorker.instances[1]!.terminated).toBe(false)
  view.unmount()
  expect(DiffWorker.instances[1]!.terminate).toHaveBeenCalledOnce()
})

it('does not start a diff worker after closing during retrieval', async () => {
  let finish!: (value: { before: string; after: string }) => void
  vi.mocked(fetchEditSnapshots).mockReturnValue(new Promise(resolve => { finish = resolve }))
  const view = render(html`<${ChatEditEvidence} output=${receipt} />`)
  fireEvent.click(view.getByRole('button'))
  await waitFor(() => expect(fetchEditSnapshots).toHaveBeenCalledOnce())
  fireEvent.click(view.getByRole('button'))
  finish({ before: 'old', after: 'new' })
  await new Promise(resolve => setTimeout(resolve, 0))
  expect(DiffWorker.instances).toHaveLength(0)
})
