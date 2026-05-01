import { signal } from '@preact/signals'
import {
  persistDashboardActorName,
  resolveDashboardActorName,
} from '../../lib/dashboard-actor'

function initialActorName(): string {
  return resolveDashboardActorName() || 'dashboard'
}

export const actorName = signal(initialActorName())
export const broadcastMessage = signal('')
export const pauseReason = signal('Operator maintenance')
export const taskTitle = signal('')
export const taskDescription = signal('')
export const taskPriority = signal('2')
export const selectedKeeperName = signal('')
export const keeperMessage = signal('')
export const hydratedWorkflowId = signal<string | null>(null)

// QuickIntervene: unified message target
// 'namespace' = broadcast, 'keeper:{name}' = keeper_message
export const quickTarget = signal('namespace')
export const quickMessage = signal('')

export function persistActorName(value: string): void {
  actorName.value = persistDashboardActorName(value)
}
