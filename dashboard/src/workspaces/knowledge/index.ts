/**
 * `3 Knowledge` Workspace Entry (`dashboard/src/workspaces/knowledge/index.ts`)
 *
 * L1 subroutes: `board | wiki | artifacts | memory`.
 */

import { html } from 'htm/preact'
import './knowledge.css'
import { BoardTab } from './board-tab'
import { WikiTab } from './wiki-tab'
import { ArtifactsTab } from './artifacts-tab'
import { MemoryTab } from './memory-tab'
import {
  normalizeKnowledgeSubroute,
  type KnowledgeSubroute,
  type WorkspaceInspectPayload,
  type WorkspaceViewProps,
} from './types'

export type { WorkspaceInspectPayload, WorkspaceViewProps, KnowledgeSubroute }
export * from './types'
export { BoardTab, WikiTab, ArtifactsTab, MemoryTab }

const KNOWLEDGE_TABS: readonly { id: KnowledgeSubroute; label: string }[] = [
  { id: 'board', label: 'Board' },
  { id: 'wiki', label: 'Librarian Wiki' },
  { id: 'artifacts', label: 'Artifacts' },
  { id: 'memory', label: 'World Memory' },
]

export function KnowledgeWorkspace(props: WorkspaceViewProps) {
  const activeTab = normalizeKnowledgeSubroute(props.subroute)

  return html`
    <section class="kn-root" aria-label="Knowledge workspace">
      <header class="kn-subbar">
        <div class="kn-tabs" role="tablist" aria-label="Knowledge sub-tabs">
          ${KNOWLEDGE_TABS.map((tab) => html`
            <button
              key=${tab.id}
              type="button"
              role="tab"
              class="kn-tab"
              aria-selected=${activeTab === tab.id}
              onClick=${() => props.onNavigate(`/knowledge/${tab.id}`)}
            >
              ${tab.label}
            </button>
          `)}
        </div>
      </header>

      <div class="kn-body">
        ${activeTab === 'board' && html`<${BoardTab} ...${props} />`}
        ${activeTab === 'wiki' && html`<${WikiTab} ...${props} />`}
        ${activeTab === 'artifacts' && html`<${ArtifactsTab} ...${props} />`}
        ${activeTab === 'memory' && html`<${MemoryTab} ...${props} />`}
      </div>
    </section>
  `
}
