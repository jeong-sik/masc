import type { Keeper } from '../../types'
import { isOfflineStatus } from '../../lib/status-utils'
import { navigate } from '../../router'

type ToolAuditEmptyState =
  | 'offline'
  | 'not_collected'
  | 'none_recent'
  | 'not_applicable'
  | 'unlinked'

export function linkedRuntimeState(keeper: Keeper | null | undefined): 'offline' | 'online' | 'unlinked' {
  if (!keeper) return 'unlinked'
  if (keeper.agent?.exists === false) return 'offline'
  if (isOfflineStatus(keeper.status)) {
    return 'offline'
  }
  return 'online'
}

export function toolAuditStateLabel(state: ToolAuditEmptyState): string {
  switch (state) {
    case 'offline':
      return 'offline'
    case 'none_recent':
      return 'none_recent'
    case 'not_applicable':
      return 'not_applicable'
    case 'unlinked':
      return 'unlinked'
    default:
      return 'not_collected'
  }
}

export function allowlistEmptyState(keeper: Keeper | null | undefined): ToolAuditEmptyState {
  const runtime = linkedRuntimeState(keeper)
  if (runtime === 'unlinked') return 'unlinked'
  if (runtime === 'offline') return 'offline'
  return 'not_collected'
}

export function observedToolsEmptyState(
  keeper: Keeper | null | undefined,
  auditSource?: string | null,
): ToolAuditEmptyState {
  const runtime = linkedRuntimeState(keeper)
  if (runtime === 'unlinked') return 'unlinked'
  if (runtime === 'offline') return 'offline'
  return auditSource?.trim() ? 'none_recent' : 'not_collected'
}

export function auditMetadataState(
  keeper: Keeper | null | undefined,
  auditSource?: string | null,
): ToolAuditEmptyState {
  const runtime = linkedRuntimeState(keeper)
  if (runtime === 'unlinked') return 'unlinked'
  if (runtime === 'offline') return 'offline'
  return auditSource?.trim() ? 'none_recent' : 'not_collected'
}

export function linkedRecentToolsEmptyState(keeper: Keeper | null | undefined): ToolAuditEmptyState {
  const runtime = linkedRuntimeState(keeper)
  if (runtime === 'unlinked') return 'unlinked'
  if (runtime === 'offline') return 'offline'
  return 'none_recent'
}

export function openToolsInventory(search?: string | null): void {
  const q = search?.trim()
  navigate('lab', { section: 'tools', ...(q ? { q } : {}) })
}
