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

export const STATE_BLOCK_TEMPLATE = [
  '[STATE]',
  'Goal: ',
  'DONE: ',
  'NEXT: ',
  'Decisions: ',
  'OpenQuestions: ',
  'Constraints: ',
  '[/STATE]',
].join('\n')

const STATE_BLOCK_KEYS: Record<string, string> = {
  constraints: 'Constraints',
  decisions: 'Decisions',
  done: 'DONE',
  goal: 'Goal',
  next: 'NEXT',
  openquestions: 'OpenQuestions',
  progress: 'Progress',
}

function stateBlockBody(message: string): string | null {
  const match = message.match(/\[STATE\]([\s\S]*?)\[\/STATE\]/)
  return match?.[1] ?? null
}

export function stateBlockKeys(message: string): string[] {
  const body = stateBlockBody(message)
  if (!body) return []

  const seen = new Set<string>()
  const keys: string[] = []
  for (const line of body.split(/\r?\n/)) {
    const match = line.match(/^\s*([A-Za-z][A-Za-z0-9]{0,31}):\s*(.*)$/)
    const rawKey = match?.[1]?.toLowerCase()
    const value = match?.[2]?.trim()
    const key = rawKey ? STATE_BLOCK_KEYS[rawKey] : null
    if (!key || !value || seen.has(key)) continue
    seen.add(key)
    keys.push(key)
  }
  return keys
}

export function hasStateBlock(message: string): boolean {
  return stateBlockKeys(message).length > 0
}

export function ensureStateBlockDraft(draft: string): string {
  if (/\[STATE\][\s\S]*?\[\/STATE\]/.test(draft)) return draft
  const trimmed = draft.trimEnd()
  return trimmed ? `${trimmed}\n\n${STATE_BLOCK_TEMPLATE}` : STATE_BLOCK_TEMPLATE
}

export function persistActorName(value: string): void {
  actorName.value = persistDashboardActorName(value)
}
