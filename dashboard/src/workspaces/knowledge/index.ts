/**
 * `3 Knowledge` Workspace Entry (`dashboard/src/workspaces/knowledge/index.ts`)
 *
 * L1 subroutes: `board | wiki | artifacts | memory`.
 */

import { html } from 'htm/preact'
import { Suspense } from 'preact/compat'
import './knowledge.css'
import { createPreloadableLazy } from '../../lib/lazy-component'
import { registerSubroutePreloader } from '../registry'
import { BoardTab } from './board-tab'
import {
  normalizeKnowledgeSubroute,
  type KnowledgeSubroute,
  type WorkspaceInspectPayload,
  type WorkspaceViewProps,
} from './types'

const wikiTab = createPreloadableLazy<WorkspaceViewProps>(async () => (await import('./wiki-tab')).WikiTab)
const artifactsTab = createPreloadableLazy<WorkspaceViewProps>(async () => (await import('./artifacts-tab')).ArtifactsTab)
const memoryTab = createPreloadableLazy<WorkspaceViewProps>(async () => (await import('./memory-tab')).MemoryTab)

export function preloadKnowledgeSubroute(subroute: KnowledgeSubroute | string): Promise<void> {
  switch (normalizeKnowledgeSubroute(subroute)) {
    case 'wiki':
      return wikiTab.preload()
    case 'artifacts':
      return artifactsTab.preload()
    case 'memory':
      return memoryTab.preload()
    default:
      return Promise.resolve()
  }
}

registerSubroutePreloader('knowledge', (subroute) => {
  void preloadKnowledgeSubroute(subroute).catch(() => {})
})

export type { WorkspaceInspectPayload, WorkspaceViewProps, KnowledgeSubroute }
export * from './types'
export { BoardTab }

export function KnowledgeWorkspace(props: WorkspaceViewProps) {
  const activeTab = normalizeKnowledgeSubroute(props.subroute)

  return html`
    <section class="kn-root" aria-label="Knowledge workspace">
      <div class="kn-body">
        ${activeTab === 'board' && html`<${BoardTab} ...${props} />`}
        ${activeTab !== 'board' && html`
          <${Suspense} fallback=${null}>
            ${activeTab === 'wiki' && html`<${wikiTab.Component} ...${props} />`}
            ${activeTab === 'artifacts' && html`<${artifactsTab.Component} ...${props} />`}
            ${activeTab === 'memory' && html`<${memoryTab.Component} ...${props} />`}
          <//>
        `}
      </div>
    </section>
  `
}
