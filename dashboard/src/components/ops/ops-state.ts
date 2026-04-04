import { signal } from '@preact/signals'
import {
  persistDashboardActorName,
  resolveDashboardActorName,
} from '../../lib/dashboard-actor'

function initialActorName(): string {
  return resolveDashboardActorName() || 'dashboard'
}

export type OpsTeamTurnKind =
  | 'note'
  | 'broadcast'
  | 'task'
  | 'worker_spawn_batch'

export const actorName = signal(initialActorName())
export const broadcastMessage = signal('')
export const pauseReason = signal('운영 점검')
export const taskTitle = signal('')
export const taskDescription = signal('')
export const taskPriority = signal('2')
export const selectedSessionId = signal('')
export const selectedReviewItemId = signal('')
export const selectedReviewTab = signal<'active' | 'deferred' | 'recent'>('active')
export const reviewDecisionReason = signal('')
export const teamTurnKind = signal<OpsTeamTurnKind>('note')
export const teamMessage = signal('')
export const teamTaskTitle = signal('')
export const teamTaskDescription = signal('')
export const teamTaskPriority = signal('2')
export const teamSpawnBatchJson = signal('')
export const teamStopReason = signal('운영자 중지 요청')
export const selectedKeeperName = signal('')
export const keeperMessage = signal('')
export const hydratedWorkflowId = signal<string | null>(null)

// QuickIntervene: unified message target
// 'namespace' = broadcast, 'session:{id}' = team_note, 'keeper:{name}' = keeper_message
export const quickTarget = signal('namespace')
export const quickMessage = signal('')

export function persistActorName(value: string): void {
  actorName.value = persistDashboardActorName(value)
}
