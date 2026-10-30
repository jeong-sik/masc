import { html } from 'htm/preact'
import { render, cleanup, fireEvent, waitFor, act } from '@testing-library/preact'
import { afterEach, expect, it, vi } from 'vitest'
import { get } from '../../api/core'
import { WorkspaceMemoryContextPanel } from './workspace-memory-context'
vi.mock('../../api/core', () => ({ get: vi.fn() }))
afterEach(() => { cleanup(); vi.resetAllMocks() })
const available = (claim: string) => ({ status: 'available', snapshot: {
  revision: 2, updated_at: 1, facts: [{ claim, origin: { trace_id: 'source-turn' } }],
  change: { removed: [] },
} })
const response = {
  schema: 'workspace.memory.context.v1', generated_at: 1,
  source_validation: 'stored_bindings_not_revalidated', consistency: 'individual_store_snapshots',
  discovery: { status: 'available' }, keepers: [
    { keeper_id: 'writer', ordinary: available('Chapter finished'), source_bound: { status: 'missing' } },
    { keeper_id: 'reviewer', ordinary: available('Chapter incomplete'), source_bound: { status: 'unavailable', detail: 'source read failed' } },
  ],
}
it('shows conflicting keeper claims, origins and read failures without another inspector', async () => {
  vi.mocked(get).mockResolvedValue(response)
  const view = render(html`<${WorkspaceMemoryContextPanel} />`)
  await waitFor(() => expect(view.getByText('Chapter finished')).toBeTruthy())
  expect(view.getByText('Chapter incomplete')).toBeTruthy()
  expect(view.getByRole('alert').textContent).toContain('source read failed')
  expect(view.getByText('저장된 기억이 없습니다.')).toBeTruthy()
  expect(view.getAllByLabelText('일반 기억 저장 원문')[0]?.textContent).toContain('source-turn')
  fireEvent.change(view.getByLabelText('Keeper 선택'), { target: { value: 'reviewer' } })
  expect(view.queryByText('Chapter finished')).toBeNull()
  expect(view.getByText('Chapter incomplete')).toBeTruthy()
})
it('rejects malformed response instead of showing an empty workspace and permits retry', async () => {
  vi.mocked(get).mockResolvedValueOnce({ ...response, keepers: [{ keeper_id: 'bad', ordinary: { status: 'available' } }] })
  const view = render(html`<${WorkspaceMemoryContextPanel} />`)
  await waitFor(() => expect(view.getByRole('alert')).toBeTruthy())
  expect(view.queryByText('이 공간에는 조회할 Keeper 기억이 없습니다.')).toBeNull()
  vi.mocked(get).mockResolvedValueOnce(response)
  fireEvent.click(view.getByRole('button', { name: '새로 읽기' }))
  await waitFor(() => expect(view.getByText('Chapter finished')).toBeTruthy())
})
it('keeps discovery failure distinct from a successful empty inventory', async () => {
  vi.mocked(get).mockResolvedValue({ ...response, discovery: { status: 'unavailable', detail: 'permission denied' }, keepers: [] })
  const view = render(html`<${WorkspaceMemoryContextPanel} />`)
  await waitFor(() => expect(view.getByRole('alert').textContent).toContain('permission denied'))
  expect(view.queryByText('이 공간에는 조회할 Keeper 기억이 없습니다.')).toBeNull()
})
it('does not replace a refreshed inventory with a late response from an older request', async () => {
  let finishOld!: (value: unknown) => void
  vi.mocked(get).mockImplementationOnce(() => new Promise(resolve => { finishOld = resolve }))
  const view = render(html`<${WorkspaceMemoryContextPanel} />`)
  await waitFor(() => expect(get).toHaveBeenCalledTimes(1))
  vi.mocked(get).mockResolvedValueOnce(response)
  fireEvent.click(view.getByRole('button', { name: '새로 읽기' }))
  await waitFor(() => expect(view.getByText('Chapter finished')).toBeTruthy())
  await act(async () => { finishOld({ ...response, keepers: [] }) })
  await waitFor(() => expect(view.queryByText('이 공간에는 조회할 Keeper 기억이 없습니다.')).toBeNull())
  expect(view.getByText('Chapter finished')).toBeTruthy()
})
it('shows remaining keepers when the selected keeper disappears on refresh', async () => {
  vi.mocked(get).mockResolvedValueOnce(response)
  const view = render(html`<${WorkspaceMemoryContextPanel} />`)
  await waitFor(() => expect(view.getByText('Chapter finished')).toBeTruthy())
  fireEvent.change(view.getByLabelText('Keeper 선택'), { target: { value: 'reviewer' } })
  vi.mocked(get).mockResolvedValueOnce({ ...response, keepers: [response.keepers[0]] })
  fireEvent.click(view.getByRole('button', { name: '새로 읽기' }))
  await waitFor(() => expect(view.getByText('Chapter finished')).toBeTruthy())
  expect((view.getByLabelText('Keeper 선택') as HTMLSelectElement).value).toBe('')
})
