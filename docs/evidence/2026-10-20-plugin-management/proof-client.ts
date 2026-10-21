// Real Dashboard component with an isolated HTTP fixture, not a live MASC server.
import { render } from 'preact'
import { html } from 'htm/preact'
import { LaneAddonsPanel } from '../../../dashboard/src/components/lane-addons-panel'
import { hydrateExecutionSnapshot, invalidateExecutionSnapshotGeneration } from '../../../dashboard/src/store'
import '../../../dashboard/src/styles/global.css'

invalidateExecutionSnapshotGeneration('plugin-management-proof', 0)
hydrateExecutionSnapshot({ execution_publication_epoch: 'plugin-management-proof', execution_publication_generation: 1,
  status: { project: 'Isolated HTTP fixture', workspace_root: '/fixture' },
} as Parameters<typeof hydrateExecutionSnapshot>[0])
render(html`<main style="max-width:1280px;margin:auto"><p style="padding:16px">Isolated Dashboard component · HTTP fixture · no production configuration</p><${LaneAddonsPanel} /></main>`, document.body)
