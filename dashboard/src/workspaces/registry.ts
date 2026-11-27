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
const pendingLoads = new Map<WorkspaceId, Promise<{ default: WorkspaceComponent }>>()
const subroutePreloaders = new Map<WorkspaceId, (subroute: string) => void>()

export function registerSubroutePreloader(
  id: WorkspaceId,
  preloader: (subroute: string) => void,
): void {
  subroutePreloaders.set(id, preloader)
}

export function preloadWorkspaceSubroute(id: WorkspaceId, subroute: string): void {
  subroutePreloaders.get(id)?.(subroute)
}

export class WorkspaceLoadError extends Error {
  constructor(cause: unknown) {
    super(cause instanceof Error ? cause.message : String(cause), { cause })
  }
}

function loadWorkspaceOnce(id: WorkspaceId): Promise<{ default: WorkspaceComponent }> {
  let pending = pendingLoads.get(id)
  if (!pending) {
    const loadPromise = WORKSPACE_LOADERS[id].load().then(
      (mod) => mod,
      (error) => {
        if (pendingLoads.get(id) === loadPromise) {
          pendingLoads.delete(id)
        }
        throw error
      },
    )
    pending = loadPromise
    pendingLoads.set(id, pending)
  }
  return pending
}

/**
 * Starts loading a workspace chunk in parallel with auth probing without
 * mounting it. Shares the exact promise with `getWorkspaceComponent(id)` so
 * `WORKSPACE_LOADERS[id].load()` is invoked at most once. Transient rejections
 * clear `pendingLoads` automatically so a failed background preload never
 * poisons subsequent navigation to that workspace.
 */
export function preloadWorkspace(id: WorkspaceId): void {
  void loadWorkspaceOnce(id).catch(() => {})
}

export function getWorkspaceComponent(id: WorkspaceId): WorkspaceComponent {
  let cached = lazyCache.get(id)
  if (!cached) {
    const component = lazy(async () => {
      try {
        return await loadWorkspaceOnce(id)
      } catch (error) {
        if (lazyCache.get(id) === component) lazyCache.delete(id)
        throw new WorkspaceLoadError(error)
      }
    }) as unknown as WorkspaceComponent
    cached = component
    lazyCache.set(id, cached)
  }
  return cached
}
