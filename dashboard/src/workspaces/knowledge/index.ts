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

export function KnowledgeWorkspace(props: WorkspaceViewProps) {
  const activeTab = normalizeKnowledgeSubroute(props.subroute)

  return html`
    <section class="kn-root" aria-label="Knowledge workspace">
      <div class="kn-body">
        ${activeTab === 'board' && html`<${BoardTab} ...${props} />`}
        ${activeTab === 'wiki' && html`<${WikiTab} ...${props} />`}
        ${activeTab === 'artifacts' && html`<${ArtifactsTab} ...${props} />`}
        ${activeTab === 'memory' && html`<${MemoryTab} ...${props} />`}
      </div>
    </section>
  `
}
