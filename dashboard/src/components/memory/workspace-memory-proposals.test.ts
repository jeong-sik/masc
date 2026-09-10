import { html } from 'htm/preact'
import { render, cleanup, fireEvent, waitFor, act } from '@testing-library/preact'
import { afterEach, expect, it, vi } from 'vitest'
import { get } from '../../api/core'
import { WorkspaceMemoryProposalsPanel } from './workspace-memory-proposals'
vi.mock('../../api/core', () => ({ get: vi.fn() }))
afterEach(() => { cleanup(); vi.resetAllMocks() })
const idA = 'a'.repeat(64)
const idB = 'b'.repeat(64)
const draft = (id = idA, claim = 'Analyst corrected M to 21 seconds.') => ({
  id, semantic_verification: 'not_performed', proposal: {
    status: 'model_proposed', context_sha256: 'c'.repeat(64),
    sources: [
      { source_id: 's1', snapshot_id: 'snapshot1', keeper_id: 'writer', store: 'ordinary',
        revision: 2, snapshot_sha256: 'd'.repeat(64), fact_index: 0,
        fact: { claim: 'PDF ready', origin: { trace_id: 'writer-turn' } } },
      { source_id: 's2', snapshot_id: 'snapshot2', evidence_path: ['invalidations', 0] },
    ],
    snapshots: [
      { snapshot_id: 'snapshot1', keeper_id: 'writer', store: 'ordinary', snapshot_sha256: 'd'.repeat(64), metadata: { revision: 2 } },
      { snapshot_id: 'snapshot2', keeper_id: 'reviewer', store: 'source_bound', snapshot_sha256: 'e'.repeat(64), metadata: {
        revision: 3, invalidations: [{ source_path: 'report.pdf', reason: 'content_changed' }],
      } },
    ],
    gaps: [{ keeper_id: 'analyst', store: 'source_bound', observation: { status: 'missing' } },
      { keeper_id: 'offline', store: 'ordinary', observation: { status: 'unavailable', detail: 'permission denied' } }],
    proposal: { shared_claims: [{ claim, source_ids: ['s1'] }],
      conflicts: [{ description: 'Report file binding is invalidated.', source_ids: ['s1', 's2'] }], excluded: [] },
  },
})
const response = (...proposals: ReturnType<typeof draft>[]) => ({ semantic_verification: 'not_performed', proposals })
it('renders unverified claims, conflict attribution, clickable original evidence and collection gaps', async () => {
  vi.mocked(get).mockResolvedValue(response(draft()))
  const view = render(html`<${WorkspaceMemoryProposalsPanel} />`)
  await waitFor(() => expect(view.getByText('Analyst corrected M to 21 seconds.')).toBeTruthy())
  expect(view.getByText('모델이 작성한 공간 기억 제안입니다. 내용의 사실 여부는 별도로 검증하지 않았습니다.')).toBeTruthy()
  expect(view.getByText('Report file binding is invalidated.')).toBeTruthy()
  expect(view.getByText('analyst · 파일 출처 기억: 저장된 기억 없음')).toBeTruthy()
  expect(view.getByText('offline · 일반 기억: 읽기 실패: permission denied')).toBeTruthy()
  fireEvent.click(view.getByRole('button', { name: 's2 · reviewer · 파일 출처 기억' }))
  expect(view.getByRole('region', { name: '선택한 출처' }).textContent).toContain('report.pdf')
  expect(view.getByRole('region', { name: '선택한 출처' }).textContent).toContain('invalidations')
  fireEvent.click(view.getByRole('button', { name: '출처 닫기' }))
  expect(view.queryByRole('region', { name: '선택한 출처' })).toBeNull()
})
it('distinguishes HTTP errors from an empty store and retries', async () => {
  vi.mocked(get).mockRejectedValueOnce(new Error('HTTP 503'))
  const view = render(html`<${WorkspaceMemoryProposalsPanel} />`)
  await waitFor(() => expect(view.getByRole('alert').textContent).toContain('HTTP 503'))
  expect(view.queryByText('저장된 공간 기억 제안이 없습니다.')).toBeNull()
  vi.mocked(get).mockResolvedValueOnce(response())
  fireEvent.click(view.getByRole('button', { name: '제안 새로 읽기' }))
  await waitFor(() => expect(view.getByText('저장된 공간 기억 제안이 없습니다.')).toBeTruthy())
  expect(view.queryByRole('alert')).toBeNull()
})
it('preserves selected proposal identity across reordering and falls back when it disappears', async () => {
  vi.mocked(get).mockResolvedValueOnce(response(draft(), draft(idB, 'Second draft')))
  const view = render(html`<${WorkspaceMemoryProposalsPanel} />`)
  await waitFor(() => expect(view.getByLabelText('제안 선택')).toBeTruthy())
  fireEvent.change(view.getByLabelText('제안 선택'), { target: { value: idB } })
  expect(view.getByText('Second draft')).toBeTruthy()
  vi.mocked(get).mockResolvedValueOnce(response(draft(idB, 'Second draft'), draft()))
  fireEvent.click(view.getByRole('button', { name: '제안 새로 읽기' }))
  await waitFor(() => expect(view.getByText('Second draft')).toBeTruthy())
  expect((view.getByLabelText('제안 선택') as HTMLSelectElement).value).toBe(idB)
  vi.mocked(get).mockResolvedValueOnce(response(draft()))
  fireEvent.click(view.getByRole('button', { name: '제안 새로 읽기' }))
  await waitFor(() => expect(view.getByText('Analyst corrected M to 21 seconds.')).toBeTruthy())
  expect((view.getByLabelText('제안 선택') as HTMLSelectElement).value).toBe(idA)
})
it('does not replace refreshed data with an older request that completed late', async () => {
  let finish!: (value: unknown) => void
  vi.mocked(get).mockImplementationOnce(() => new Promise(resolve => { finish = resolve }))
  const view = render(html`<${WorkspaceMemoryProposalsPanel} />`)
  await waitFor(() => expect(get).toHaveBeenCalledTimes(1))
  vi.mocked(get).mockResolvedValueOnce(response(draft()))
  fireEvent.click(view.getByRole('button', { name: '제안 새로 읽기' }))
  await waitFor(() => expect(view.getByText('Analyst corrected M to 21 seconds.')).toBeTruthy())
  await act(async () => { finish(response()) })
  expect(view.queryByText('저장된 공간 기억 제안이 없습니다.')).toBeNull()
  expect(view.getByText('Analyst corrected M to 21 seconds.')).toBeTruthy()
})
it.each(['schema', 'orphan', 'duplicate', 'coverage', 'overlap'])('rejects malformed %s data', async kind => {
  const data = response(draft())
  if (kind === 'schema') data.semantic_verification = 'verified'
  if (kind === 'orphan') data.proposals[0]!.proposal.sources[0]!.snapshot_id = 'absent'
  if (kind === 'duplicate') data.proposals.push(draft())
  if (kind === 'coverage') data.proposals[0]!.proposal.proposal.conflicts = []
  if (kind === 'overlap') Object.assign(data.proposals[0]!.proposal.proposal, { excluded: [{ source_id: 's1', reason: 'excluded' }] })
  vi.mocked(get).mockResolvedValue(data)
  const view = render(html`<${WorkspaceMemoryProposalsPanel} />`)
  await waitFor(() => expect(view.getByRole('alert')).toBeTruthy())
  expect(view.queryByText('Analyst corrected M to 21 seconds.')).toBeNull()
  expect(view.queryByText('저장된 공간 기억 제안이 없습니다.')).toBeNull()
})
