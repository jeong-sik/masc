/**
 * Lazy Workspace Registry for Proposal A+ (8 Workspaces).
 *
 * - Re-exports the shared `WorkspaceViewProps` / `WorkspaceInspectPayload` contract.
 * - Lazily loads the real `AccountWorkspace` (`./account/index.ts`).
 * - Provides clean typed placeholder loader wrappers for the 7 sibling workspaces
 *   being authored in parallel by Layers 5–7 (`pulse`, `keepers`, `work`, `knowledge`,
 *   `runtime`, `infra`, `settings`) — each swaps cleanly in 1 line when stacked.
 */

import { html } from 'htm/preact'
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

function createWorkspacePlaceholder(
  id: WorkspaceId,
  title: string,
  description: string,
): WorkspaceComponent {
  return function WorkspacePlaceholder(props: WorkspaceViewProps) {
    return html`
      <section class="ap-placeholder" data-workspace-placeholder=${id}>
        <header class="ap-placeholder-head">
          <span class="ap-eyebrow">PROPOSAL A+ WORKSPACE</span>
          <h1 class="ap-placeholder-title">${title}</h1>
          <p class="ap-placeholder-desc">${description}</p>
        </header>
        <dl class="ap-placeholder-meta mono">
          <div><dt>workspace</dt><dd>${id}</dd></div>
          <div><dt>subroute</dt><dd>${props.subroute}</dd></div>
          ${props.entityId ? html`<div><dt>entity</dt><dd>${props.entityId}</dd></div>` : null}
          ${props.entityTab ? html`<div><dt>tab</dt><dd>${props.entityTab}</dd></div>` : null}
        </dl>
        <div class="ap-placeholder-actions">
          <button
            type="button"
            class="btn-ghost"
            onClick=${() => props.onInspect({
              title: `${title} · Route Contract`,
              subtitle: `/${id}/${props.subroute}`,
              kind: 'workspace-meta',
              data: { id, subroute: props.subroute, entityId: props.entityId, entityTab: props.entityTab },
            })}
          >
            Quick-Peek Inspect
          </button>
          <button
            type="button"
            class="btn-primary"
            onClick=${() => props.onNavigate('/account')}
          >
            Open Account
          </button>
        </div>
      </section>
    `
  }
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
    load: async () => ({
      default: createWorkspacePlaceholder(
        'work',
        '2 Work — Goals, Tasks, Inbox & Candle',
        'Goal verification lifecycle, Task/Schedule CRUD, Target-Locked Unified HITL Inbox & Candle Ledger (Layer 6).',
      ),
    }),
  },
  knowledge: {
    id: 'knowledge',
    title: '3 Knowledge',
    load: async () => ({
      default: createWorkspacePlaceholder(
        'knowledge',
        '3 Knowledge — Board, Wiki, Artifacts & World Memory',
        'Signal-only Board, Librarian Wiki CAS editor, Lean Artifacts & World Memory Diff/Conflicts (Layer 6).',
      ),
    }),
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
    load: async () => ({
      default: createWorkspacePlaceholder(
        'runtime',
        '5 Runtime — Quotas, Efficiency, Lanes, Tools & Add-ons',
        '3-tier Provider Quotas, 4-panel synced uPlot Efficiency suite, Failover/Exact/Fusion Lanes & Add-ons (Layer 7).',
      ),
    }),
  },
  infra: {
    id: 'infra',
    title: '6 Infra',
    load: async () => ({
      default: createWorkspacePlaceholder(
        'infra',
        '6 Infra — Sandboxes, Repos & Live SSE Logs',
        'MicroVM/SSH/Docker Sandboxes, 24h Repo Diffs & Virtualized Live SSE Logs (Layer 7, Admin-only).',
      ),
    }),
  },
  settings: {
    id: 'settings',
    title: 'Settings',
    load: async () => ({
      default: createWorkspacePlaceholder(
        'settings',
        'Settings — Schema-Driven Config & TOML Patch',
        'Schema-driven runtime config editor with dry-run unified diff & CAS apply (Layer 7, Admin-only).',
      ),
    }),
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
