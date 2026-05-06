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
export type QuickComposerMode = 'broadcast' | 'dm' | 'state'

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

export const quickTarget = signal('namespace')
export const quickMessage = signal('')
export const quickComposerMode = signal<QuickComposerMode>('broadcast')

const STATE_BLOCK_KEYS: Record<string, string> = {
  constraints: 'Constraints',
  decisions: 'Decisions',
  done: 'DONE',
  goal: 'Goal',
  next: 'NEXT',
  openquestions: 'OpenQuestions',
  progress: 'Progress',
}

export function composerModeForFocus(focus?: string | null): QuickComposerMode | null {
  switch (focus?.trim().toLowerCase()) {
    case 'broadcast':
      return 'broadcast'
    case 'mention':
    case 'dm':
      return 'dm'
    case 'state':
      return 'state'
    default:
      return null
  }
}

function stateBlockBody(message: string): string | null {
  const match = message.match(/\[STATE\]([\s\S]*?)\[\/STATE\]/i)
  return match?.[1] ?? null
}

export function stateBlockKeys(message: string): string[] {
  const body = stateBlockBody(message)
  if (!body) return []

  const seen = new Set<string>()
  const keys: string[] = []
  for (const line of body.split(/\r?\n/)) {
    const match = line.match(/^\s*([A-Za-z][A-Za-z0-9 _-]{0,31})\s*:\s*(.*)$/)
    const rawKey = match?.[1]?.trim()
    const value = match?.[2]?.trim()
    const normalized = rawKey?.replace(/\s+/g, '').toLowerCase()
    const key = normalized ? STATE_BLOCK_KEYS[normalized] : null
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
  if (/\[STATE\][\s\S]*?\[\/STATE\]/i.test(draft)) return draft
  const trimmed = draft.trimEnd()
  return trimmed ? `${trimmed}\n\n${STATE_BLOCK_TEMPLATE}` : STATE_BLOCK_TEMPLATE
}

export function persistActorName(value: string): void {
  actorName.value = persistDashboardActorName(value)
}
