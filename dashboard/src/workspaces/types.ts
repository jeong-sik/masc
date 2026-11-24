/**
 * Shared Workspace View Contract for MASC Web Dashboard Renewal (Proposal A+).
 *
 * All 8 workspaces (`pulse`, `work`, `knowledge`, `keepers`, `runtime`, `infra`,
 * `settings`, `account`) implement `WorkspaceViewProps` and pass read-only
 * inspector payloads via `onInspect` to the single shell-hosted `QuickPeekDrawer`.
 */

import type { ComponentChildren, ComponentType } from 'preact'

export type WorkspaceId =
  | 'pulse'
  | 'work'
  | 'knowledge'
  | 'keepers'
  | 'runtime'
  | 'infra'
  | 'settings'
  | 'account'

export interface WorkspaceInspectPayload {
  title: string
  subtitle?: string
  kind: string
  data?: unknown
  render?: () => ComponentChildren
}

export interface WorkspaceViewProps {
  subroute: string
  entityId?: string
  entityTab?: string
  onNavigate: (path: string) => void
  onInspect: (payload: WorkspaceInspectPayload) => void
}

export type WorkspaceComponent = ComponentType<WorkspaceViewProps>

export interface WorkspaceLoaderEntry {
  readonly id: WorkspaceId
  readonly title: string
  readonly load: () => Promise<{ readonly default: WorkspaceComponent }>
}
