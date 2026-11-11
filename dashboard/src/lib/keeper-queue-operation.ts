import { signal } from '@preact/signals'
import { cancelKeeperQueue, previewKeeperQueue, type KeeperQueueCancellation, type KeeperQueueFilter, type KeeperQueuePreview, type KeeperQueueRow } from '../api/keeper-event-queue'
import { dashboardCredentialOwnerIsCurrent, type DashboardCredentialOwner } from '../api/core'
import { executionWorkspaceAuthority, shellAuthSummary, type ExecutionWorkspaceAuthority } from '../store'
import { dashboardAuthAccess } from './dashboard-auth-access'

export interface KeeperQueuePlan {
  authority: ExecutionWorkspaceAuthority
  credentials: DashboardCredentialOwner
  filter: KeeperQueueFilter
  rows: readonly KeeperQueueRow[]
  reason: string
}
interface Attempt { plan: KeeperQueuePlan; controller: AbortController }
type Readback = { kind: 'loading' } | { kind: 'ready'; preview: KeeperQueuePreview } | { kind: 'unavailable'; message: string }
export type KeeperQueueOperation =
  | { kind: 'idle' }
  | { kind: 'sending'; attempt: Attempt }
  | { kind: 'settled'; attempt: Attempt; report: KeeperQueueCancellation; readback: Readback }
  | { kind: 'unknown'; attempt: Attempt; message: string; readback?: Readback }

// Retain an in-flight/unknown outcome across panel navigation in this tab.
// No credentials, private selections or reasons are written to browser storage.
export const keeperQueueOperation = signal<KeeperQueueOperation>({ kind: 'idle' })

export function keeperQueuePlanIsCurrent(plan: KeeperQueuePlan): boolean {
  return executionWorkspaceAuthority.peek() === plan.authority
    && dashboardCredentialOwnerIsCurrent(plan.credentials)
    && dashboardAuthAccess(shellAuthSummary.peek(), 'admin').allowed
}

async function readback(plan: KeeperQueuePlan): Promise<Readback> {
  const authority = executionWorkspaceAuthority.peek()
  const current = () => executionWorkspaceAuthority.peek() === authority
    && dashboardCredentialOwnerIsCurrent(plan.credentials)
    && dashboardAuthAccess(shellAuthSummary.peek(), 'admin').allowed
  if (authority === null || authority.workspaceRoot !== plan.authority.workspaceRoot || !current()) {
    return { kind: 'unavailable', message: '작업 공간이나 인증이 바뀌어 재조회하지 못했습니다.' }
  }
  try {
    const preview = await previewKeeperQueue(plan.authority.workspaceRoot, plan.filter)
    return current()
      ? { kind: 'ready', preview }
      : { kind: 'unavailable', message: '재조회 도중 작업 공간이나 인증이 바뀌었습니다.' }
  } catch {
    return { kind: 'unavailable', message: '현재 대기열을 다시 읽지 못했습니다. 목록 조회로 확인하세요.' }
  }
}

export async function executeKeeperQueuePlan(plan: KeeperQueuePlan): Promise<void> {
  if (!keeperQueuePlanIsCurrent(plan) || keeperQueueOperation.peek().kind === 'sending') return
  const attempt: Attempt = { plan, controller: new AbortController() }
  keeperQueueOperation.value = { kind: 'sending', attempt }
  let report: KeeperQueueCancellation
  try {
    report = await cancelKeeperQueue(plan.authority.workspaceRoot, plan.filter, plan.rows, plan.reason, attempt.controller.signal)
  } catch {
    const current = keeperQueueOperation.peek()
    if (current.kind !== 'idle' && current.attempt === attempt) {
      keeperQueueOperation.value = { kind: 'unknown', attempt,
        message: '취소 결과를 확인하지 못했습니다. 요청은 처리되었을 수 있습니다. 다시 취소하기 전에 대기열을 조회하세요.' }
    }
    return
  }
  const current = keeperQueueOperation.peek()
  if (current.kind !== 'idle' && current.attempt === attempt) {
    // Publish the received cancellation receipt before any new read. A slow
    // readback cannot hide a known primary outcome behind a sending state.
    keeperQueueOperation.value = { kind: 'settled', attempt, report, readback: { kind: 'loading' } }
  }
  const observed = await readback(plan)
  const afterRead = keeperQueueOperation.peek()
  if (afterRead.kind === 'settled' && afterRead.attempt === attempt) {
    keeperQueueOperation.value = { ...afterRead, readback: observed }
  }
}

export function stopKeeperQueueResponse(): void {
  const current = keeperQueueOperation.peek()
  if (current.kind !== 'sending') return
  keeperQueueOperation.value = { kind: 'unknown', attempt: current.attempt,
    message: '응답 확인을 중단했습니다. 취소 요청은 계속 처리될 수 있습니다. 다시 취소하기 전에 대기열을 조회하세요.' }
  current.attempt.controller.abort()
}

export async function readbackKeeperQueueOperation(): Promise<void> {
  const current = keeperQueueOperation.peek()
  if (current.kind !== 'unknown' && current.kind !== 'settled') return
  if (current.readback?.kind === 'loading') return
  const pending = { ...current, readback: { kind: 'loading' as const } }
  keeperQueueOperation.value = pending
  const observed = await readback(current.attempt.plan)
  if (keeperQueueOperation.peek() === pending) keeperQueueOperation.value = { ...current, readback: observed }
}
