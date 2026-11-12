import { signal } from '@preact/signals'
import { html } from 'htm/preact'
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { KeeperQueueCancellation, KeeperQueuePreview, KeeperQueueRow } from '../../api/keeper-event-queue'

vi.mock('../../store', () => ({
  executionWorkspaceAuthority: signal({ workspaceRoot: '/fixture/a', epoch: 'epoch-a', connectionGeneration: 1,
    observerInstanceId: null }),
  shellAuthSummary: signal({ effective_role: 'admin' }),
}))
vi.mock('../../api/core', async importOriginal => {
  const original = await importOriginal<typeof import('../../api/core')>()
  return { ...original, captureDashboardCredentialOwner: vi.fn(() => ({ actor: 'fixture-admin' })), dashboardCredentialOwnerIsCurrent: vi.fn(() => true) }
})
vi.mock('../../api/keeper-event-queue', async importOriginal => {
  const original = await importOriginal<typeof import('../../api/keeper-event-queue')>()
  return { ...original, previewKeeperQueue: vi.fn(), cancelKeeperQueue: vi.fn() }
})
import { executionWorkspaceAuthority, shellAuthSummary } from '../../store'
import { dashboardCredentialOwnerIsCurrent } from '../../api/core'
import { cancelKeeperQueue, previewKeeperQueue } from '../../api/keeper-event-queue'
import { keeperQueueOperation } from '../../lib/keeper-queue-operation'
import { KeeperEventQueuePanel } from './keeper-event-queue-panel'

const authority = executionWorkspaceAuthority as ReturnType<typeof signal<import('../../store').ExecutionWorkspaceAuthority | null>>
const auth = shellAuthSummary as ReturnType<typeof signal<import('../../types').DashboardShellAuthSummary | null>>
const first: KeeperQueueRow = { keeper_name: 'alpha', source_ref: 'a'.repeat(64), source_incarnation: '9007199254740993', source: 'bootstrap', state: 'pending', source_arrived_at: 1, first_admitted_at: null }
const second: KeeperQueueRow = { ...first, keeper_name: 'beta', source_ref: 'b'.repeat(64), source_incarnation: '2' }
function preview(rows: readonly KeeperQueueRow[] = [first, second]): KeeperQueuePreview {
  return { schema: 'keeper_event_queue.bulk.result.v2', ok: true, action: 'preview', workspace_root: '/fixture/a',
    would_cancel: rows.length, keeper_counts: {}, source_counts: {}, oldest_age_seconds: null, rows }
}
function result(): KeeperQueueCancellation {
  return { schema: 'keeper_event_queue.bulk.result.v2', ok: true, action: 'cancel', workspace_root: '/fixture/a',
    operation_id: 'fixture-op', backup_path: '/fixture/target.json', requested: 1, cancelled: 1, committed_followup_failed: 0, failed: 0,
    results: [{ row: first, status: 'cancelled', result: { status: 'applied', transition_id: 'transition-a' } }] }
}
function deferred<T>() {
  let resolve!: (value: T) => void
  let reject!: (reason: unknown) => void
  const promise = new Promise<T>((ok, no) => { resolve = ok; reject = no })
  return { promise, resolve, reject }
}
async function prepare() {
  fireEvent.click(screen.getByRole('button', { name: '대기열 조회' }))
  await screen.findByText('alpha')
  fireEvent.click(screen.getByRole('checkbox', { name: `${first.keeper_name} ${first.source_ref} ${first.source_incarnation} 선택` }))
  fireEvent.input(screen.getByRole('textbox', { name: '취소 사유' }), { target: { value: 'only alpha' } })
  fireEvent.click(screen.getByRole('button', { name: '선택 1건 취소 내용 확인' }))
}
beforeEach(() => {
  keeperQueueOperation.value = { kind: 'idle' }
  authority.value = { workspaceRoot: '/fixture/a', epoch: 'epoch-a', connectionGeneration: 1, observerInstanceId: null }
  auth.value = { effective_role: 'admin' } as import('../../types').DashboardShellAuthSummary
  vi.mocked(dashboardCredentialOwnerIsCurrent).mockReturnValue(true)
  vi.mocked(previewKeeperQueue).mockResolvedValue(preview())
  vi.mocked(cancelKeeperQueue).mockResolvedValue(result())
})
afterEach(() => { cleanup(); vi.clearAllMocks() })

describe('fleet queue cancel workflow', () => {
  it('requires selection, a reason and explicit confirmation, then submits only that row and reads back', async () => {
    render(html`<${KeeperEventQueuePanel} />`)
    expect(previewKeeperQueue).not.toHaveBeenCalled()
    await prepare()
    expect(screen.getByRole('button', { name: '확인한 1건 취소' }).hasAttribute('disabled')).toBe(true)
    expect(cancelKeeperQueue).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole('checkbox', { name: '선택한 대기 항목 취소 확인' }))
    fireEvent.click(screen.getByRole('button', { name: '확인한 1건 취소' }))
    await screen.findByText(/취소 완료 1건/)
    expect(cancelKeeperQueue).toHaveBeenCalledTimes(1)
    expect(vi.mocked(cancelKeeperQueue).mock.calls[0]?.slice(0, 4)).toEqual(['/fixture/a', {}, [first], 'only alpha'])
    expect(previewKeeperQueue).toHaveBeenCalledTimes(2)
    expect(await screen.findByText(/같은 버전으로 대기 중/)).toBeTruthy()
    expect(screen.queryByRole('button', { name: '확인한 1건 취소' })).toBeNull()
  })
  it('shows a known cancellation receipt while the independent readback is still pending', async () => {
    const pendingRead = deferred<KeeperQueuePreview>()
    vi.mocked(previewKeeperQueue).mockResolvedValueOnce(preview()).mockReturnValueOnce(pendingRead.promise)
    render(html`<${KeeperEventQueuePanel} />`)
    await prepare()
    fireEvent.click(screen.getByRole('checkbox', { name: '선택한 대기 항목 취소 확인' }))
    fireEvent.click(screen.getByRole('button', { name: '확인한 1건 취소' }))
    await screen.findByText(/취소 완료 1건/)
    expect(screen.getByText('취소 요청 이후 대기열을 다시 확인하고 있습니다.')).toBeTruthy()
    expect(keeperQueueOperation.peek().kind).toBe('settled')
    await act(async () => { pendingRead.resolve(preview([second])) })
    await screen.findByText(/확인한 대상 중 0건/)
  })
  it('allows passive readback after a same-workspace reconnect without reviving an old confirmation', async () => {
    render(html`<${KeeperEventQueuePanel} />`)
    await prepare()
    fireEvent.click(screen.getByRole('checkbox', { name: '선택한 대기 항목 취소 확인' }))
    fireEvent.click(screen.getByRole('button', { name: '확인한 1건 취소' }))
    await screen.findByText(/취소 완료 1건/)
    await screen.findByText(/같은 버전으로 대기 중/)
    await act(async () => { authority.value = { workspaceRoot: '/fixture/a', epoch: 'epoch-a', connectionGeneration: 2, observerInstanceId: null } })
    vi.mocked(previewKeeperQueue).mockResolvedValueOnce(preview([second]))
    fireEvent.click(screen.getByRole('button', { name: '요청 대상 재조회' }))
    await screen.findByText(/확인한 대상 중 0건/)
    expect(cancelKeeperQueue).toHaveBeenCalledTimes(1)
  })
  it('retires the preview when the filter, actor credentials or workspace changes', async () => {
    render(html`<${KeeperEventQueuePanel} />`)
    await prepare()
    fireEvent.input(screen.getByRole('textbox', { name: 'Keeper 이름 필터' }), { target: { value: 'beta' } })
    expect(screen.queryByRole('group', { name: '취소 내용 확인' })).toBeNull()
    expect(cancelKeeperQueue).not.toHaveBeenCalled()
    await act(async () => { authority.value = { workspaceRoot: '/fixture/b', epoch: 'epoch-b', connectionGeneration: 2, observerInstanceId: null } })
    expect(screen.queryByText('alpha')).toBeNull()
    expect(cancelKeeperQueue).not.toHaveBeenCalled()
  })
  it('does not let an old preview reply replace the new filter scope', async () => {
    const pending = deferred<KeeperQueuePreview>()
    vi.mocked(previewKeeperQueue).mockReturnValueOnce(pending.promise)
    render(html`<${KeeperEventQueuePanel} />`)
    fireEvent.click(screen.getByRole('button', { name: '대기열 조회' }))
    fireEvent.input(screen.getByRole('textbox', { name: 'Keeper 이름 필터' }), { target: { value: 'beta' } })
    await act(async () => { pending.resolve(preview()) })
    expect(screen.queryByText('alpha')).toBeNull()
  })
  it('retains an unavailable mutation as unknown across panel navigation without replay', async () => {
    const pending = deferred<KeeperQueueCancellation>()
    vi.mocked(cancelKeeperQueue).mockReturnValueOnce(pending.promise)
    const view = render(html`<${KeeperEventQueuePanel} />`)
    await prepare()
    fireEvent.click(screen.getByRole('checkbox', { name: '선택한 대기 항목 취소 확인' }))
    fireEvent.click(screen.getByRole('button', { name: '확인한 1건 취소' }))
    await waitFor(() => expect(cancelKeeperQueue).toHaveBeenCalledTimes(1))
    view.unmount()
    await act(async () => { pending.reject(new Error('reply lost after commit')) })
    render(html`<${KeeperEventQueuePanel} />`)
    expect(screen.getByRole('alert').textContent).toContain('처리되었을 수')
    expect(cancelKeeperQueue).toHaveBeenCalledTimes(1)
    fireEvent.click(screen.getByRole('button', { name: '요청 대상 재조회' }))
    await screen.findByText(/같은 버전으로 대기 중/)
    expect(cancelKeeperQueue).toHaveBeenCalledTimes(1)
  })
  it('prevents a send after credential ownership is withdrawn and blocks readers', async () => {
    render(html`<${KeeperEventQueuePanel} />`)
    await prepare()
    fireEvent.click(screen.getByRole('checkbox', { name: '선택한 대기 항목 취소 확인' }))
    vi.mocked(dashboardCredentialOwnerIsCurrent).mockReturnValue(false)
    fireEvent.click(screen.getByRole('button', { name: '확인한 1건 취소' }))
    expect(cancelKeeperQueue).not.toHaveBeenCalled()
    await act(async () => { auth.value = { effective_role: 'reader' } as import('../../types').DashboardShellAuthSummary })
    expect(screen.getByRole('button', { name: '대기열 조회' }).hasAttribute('disabled')).toBe(true)
  })
})
