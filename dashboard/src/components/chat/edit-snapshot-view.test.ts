import { html } from 'htm/preact'
import { render, cleanup, fireEvent, waitFor } from '@testing-library/preact'
import { afterEach, expect, it, vi } from 'vitest'
import { fetchEditSnapshots } from '../../api/edit-snapshots'
import { ChatEditEvidence } from './edit-evidence'
import type { ToolCallEntry } from '../../api/dashboard'

vi.mock('../../api/edit-snapshots', async importOriginal => ({
  ...await importOriginal<typeof import('../../api/edit-snapshots')>(),
  fetchEditSnapshots: vi.fn(),
}))
afterEach(() => { cleanup(); vi.resetAllMocks() })
const ref = { _blob: { sha256: 'a'.repeat(64), bytes: 3 } }
const receipt: ToolCallEntry = {
  ts: 1, keeper: 'writer', tool: 'Edit', success: true, duration_ms: 3,
  input: {}, route_evidence: { descriptor_id: 'agent.edit_file' },
  output: JSON.stringify({ ok: true, mode: 'patch', path: 'essay.md', occurrences: 1,
    edit_snapshots: { status: 'stored', before: ref, after: ref } }),
}

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

it('shows a final-newline-only edit in the verified originals diff', async () => {
  vi.mocked(fetchEditSnapshots).mockResolvedValue({ before: 'same\n', after: 'same' })
  const view = render(html`<${ChatEditEvidence} output=${receipt} />`)
  fireEvent.click(view.getByRole('button'))
  await waitFor(() => expect(view.getByLabelText('편집 원본의 Unified diff').textContent).toContain('\\ No newline at end of file'))
  expect(view.getByLabelText('편집 원본의 Unified diff').textContent).toContain('-same\n+same\n')
})
