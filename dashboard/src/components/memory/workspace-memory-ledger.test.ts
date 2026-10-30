import { html } from 'htm/preact'
import { render, cleanup, fireEvent, waitFor, act } from '@testing-library/preact'
import { afterEach, expect, it, vi } from 'vitest'
import { get } from '../../api/core'
import { WorkspaceMemoryLedgerPanel } from './workspace-memory-ledger'

vi.mock('../../api/core', () => ({ get: vi.fn() }))
afterEach(() => { cleanup(); vi.resetAllMocks() })

const response = () => ({
  status: 'available', semantic_verification: 'not_performed', ledger_sha256: 'a'.repeat(64),
  source_resolution: { status: 'available' },
  ledger: { schema: 'workspace.memory.ledger.v1',
    claims: [{ claim_id: 'claim-1', claim: 'The report has twelve pages' }],
    conflicts: [], facts: [{ keeper_id: 'writer', store: 'ordinary',
      claim_sha256: 'b'.repeat(64), disposition: { kind: 'claim', claim_id: 'claim-1' },
      current_claim: 'Writer observed twelve pages', source_state: 'present' }],
  },
})

it('renders current ledger membership with an unverified status', async () => {
  vi.mocked(get).mockResolvedValue(response())
  const view = render(html`<${WorkspaceMemoryLedgerPanel} />`)
  await waitFor(() => expect(view.getByText('The report has twelve pages')).toBeTruthy())
  expect(view.getByText('Writer observed twelve pages')).toBeTruthy()
  expect(view.getByText('Keeper 사실을 모델이 분류한 기록입니다. 의미 검증은 수행하지 않았습니다.')).toBeTruthy()
})

it('distinguishes missing ledger, unavailable source read, and HTTP errors', async () => {
  vi.mocked(get).mockRejectedValueOnce(new Error('HTTP 503'))
  const view = render(html`<${WorkspaceMemoryLedgerPanel} />`)
  await waitFor(() => expect(view.getByRole('alert').textContent).toContain('HTTP 503'))
  vi.mocked(get).mockResolvedValueOnce({ status: 'missing' })
  fireEvent.click(view.getByRole('button', { name: '원장 새로 읽기' }))
  await waitFor(() => expect(view.getByText('아직 저장된 공간 기억 원장이 없습니다.')).toBeTruthy())
  const unresolved = response()
  vi.mocked(get).mockResolvedValueOnce({ ...unresolved,
    source_resolution: { status: 'unavailable', detail: 'keeper store unreadable' },
    ledger: { ...unresolved.ledger, facts: unresolved.ledger.facts.map(row =>
      ({ ...row, current_claim: null, source_state: 'unavailable' })) } })
  fireEvent.click(view.getByRole('button', { name: '원장 새로 읽기' }))
  await waitFor(() => expect(view.getByText('현재 Keeper 원문 조회 실패: keeper store unreadable')).toBeTruthy())
})

it('ignores an older request after refresh and rejects dangling memberships', async () => {
  let finish!: (value: unknown) => void
  vi.mocked(get).mockImplementationOnce(() => new Promise(resolve => { finish = resolve }))
  const view = render(html`<${WorkspaceMemoryLedgerPanel} />`)
  await waitFor(() => expect(get).toHaveBeenCalledTimes(1))
  vi.mocked(get).mockResolvedValueOnce(response())
  fireEvent.click(view.getByRole('button', { name: '원장 새로 읽기' }))
  await waitFor(() => expect(view.getByText('The report has twelve pages')).toBeTruthy())
  await act(async () => { finish({ status: 'missing' }) })
  expect(view.queryByText('아직 저장된 공간 기억 원장이 없습니다.')).toBeNull()
  const invalid = response()
  invalid.ledger.claims = []
  vi.mocked(get).mockResolvedValueOnce(invalid)
  fireEvent.click(view.getByRole('button', { name: '원장 새로 읽기' }))
  await waitFor(() => expect(view.getByRole('alert').textContent).toContain('Invalid workspace ledger references'))
})
