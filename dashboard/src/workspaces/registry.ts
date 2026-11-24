/**
 * Lazy Workspace Registry for Proposal A+ (All 8 Workspaces).
 *
 * - Re-exports the shared `WorkspaceViewProps` / `WorkspaceInspectPayload` contract.
 * - Lazily loads all 8 workspaces (`pulse`, `work`, `knowledge`, `keepers`,
 *   `runtime`, `infra`, `settings`, `account`) so first-load JS/CSS stays strictly
 *   bounded to the shell + vendor runtime.
 */

import { lazy } from 'preact/compat'
import type {
  WorkspaceComponent,
  WorkspaceId,
  WorkspaceInspectPayload,
  WorkspaceLoaderEntry,
  WorkspaceViewProps,
} from './types'

export type {
  WorkspaceComponent,
  WorkspaceId,
  WorkspaceInspectPayload,
  WorkspaceLoaderEntry,
  WorkspaceViewProps,
}

export const WORKSPACE_LOADERS: Readonly<Record<WorkspaceId, WorkspaceLoaderEntry>> = Object.freeze({
  pulse: {
    id: 'pulse',
    title: '1 Pulse',
    load: async () => {
      const mod = await import('./pulse/index')
      return { default: mod.PulseWorkspace }
    },
  },
  work: {
    id: 'work',
    title: '2 Work',
    load: async () => {
      const mod = await import('./work/index')
      return { default: mod.WorkWorkspace }
    },
  },
  knowledge: {
    id: 'knowledge',
    title: '3 Knowledge',
    load: async () => {
      const mod = await import('./knowledge/index')
      return { default: mod.KnowledgeWorkspace }
    },
  },
  keepers: {
    id: 'keepers',
    title: '4 Keepers',
    load: async () => {
      const mod = await import('./keepers/index')
      return { default: mod.KeepersWorkspace }
    },
  },
  runtime: {
    id: 'runtime',
    title: '5 Runtime',
    load: async () => {
      const mod = await import('./runtime/index')
      return { default: mod.RuntimeWorkspace }
    },
  },
  infra: {
    id: 'infra',
    title: '6 Infra',
    load: async () => {
      const mod = await import('./infra/index')
      return { default: mod.InfraWorkspace }
    },
  },
  settings: {
    id: 'settings',
    title: 'Settings',
    load: async () => {
      const mod = await import('./settings/index')
      return { default: mod.SettingsWorkspace }
    },
  },
  account: {
    id: 'account',
    title: 'Account',
    load: async () => {
      const mod = await import('./account/index')
      return { default: mod.AccountWorkspace }
    },
  },
})

const lazyCache = new Map<WorkspaceId, WorkspaceComponent>()

export class WorkspaceLoadError extends Error {
  constructor(cause: unknown) {
    super(cause instanceof Error ? cause.message : String(cause), { cause })
  }
}

export function getWorkspaceComponent(id: WorkspaceId): WorkspaceComponent {
  let cached = lazyCache.get(id)
  if (!cached) {
    cached = lazy(async () => {
      try {
        return await WORKSPACE_LOADERS[id].load()
      } catch (error) {
        throw new WorkspaceLoadError(error)
      }
    }) as unknown as WorkspaceComponent
    lazyCache.set(id, cached)
  }
  return cached
}
