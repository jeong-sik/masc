import { html } from 'htm/preact'
import { render } from 'preact'
import { useState } from 'preact/hooks'
import { LaneAddonsPanel } from '../../src/components/lane-addons-panel'
import { hydrateExecutionSnapshot, invalidateExecutionSnapshotGeneration } from '../../src/store'
import '../../src/styles/ds-theme-tokens.css'
import '../../src/styles/primitives.css'
import '../../src/styles/layout.css'
import '../../src/styles/layers.css'
import '../../src/styles/kpi.css'
import '../../src/styles/rail.css'
import '../../src/styles/deck.css'
import '../../src/styles/drawer.css'
import '../../src/styles/swimlanes.css'
import '../../src/styles/code.css'
import '../../src/styles/styleseed-theme.css'
import '../../src/styles/styleseed-base.css'
import '../../src/styles/global.css'
import '../../src/styles/tokens.css'
import '../../src/styles/paper-theme.css'
import '../../src/styles/keeper-workspace.css'
import '../../src/styles/copilot-dock.css'
import '../../src/styles/states.css'
import '../../src/styles/ss-keeper-v2-bridge.css'
import.meta.glob('../../src/styles/*-v2.css', { eager: true })
import '../../src/styles/keeper-v2/colors_and_type.css'
import '../../src/styles/keeper-v2/v2.css'
import '../../src/styles/keeper-v2/surfaces.css'
import '../../src/styles/keeper-v2/dock.css'
import '../../src/styles/keeper-v2/craft.css'
import '../../src/styles/keeper-v2/inspector.css'
import '../../src/styles/keeper-v2/perf.css'
import '../../src/styles/keeper-v2/fleet.css'
import '../../src/styles/keeper-v2/logs.css'
import '../../src/styles/keeper-v2/keeper-config.css'
import '../../src/styles/keeper-v2/fusion.css'
import '../../src/styles/keeper-v2/memory.css'
import '../../src/styles/keeper-v2/schedule.css'
import '../../src/styles/keeper-v2/runtime.css'
import '../../src/styles/keeper-v2/ops-cluster.css'
import '../../src/styles/keeper-v2/prompt-book.css'
import '../../src/styles/keeper-v2/verify.css'
import '../../src/styles/keeper-v2/registry.css'
import '../../src/styles/keeper-v2/monitor.css'
import '../../src/styles/keeper-v2/lanes.css'
import '../../src/styles/keeper-v2/tempered.css'
import '../../src/styles/mobile-operator-targets.css'
let execution = { execution_publication_epoch: 'package-installation-fixture', execution_publication_generation: 1,
  status: { project: 'fixture', workspace_root: '/workspace' } }
invalidateExecutionSnapshotGeneration(execution.execution_publication_epoch, 0)
hydrateExecutionSnapshot(execution as Parameters<typeof hydrateExecutionSnapshot>[0])
function workspace(root: string) {
 execution = { ...execution, execution_publication_generation: execution.execution_publication_generation + 1,
   status: { ...execution.status, workspace_root: root } }
 hydrateExecutionSnapshot(execution as Parameters<typeof hydrateExecutionSnapshot>[0])
}
Object.assign(window, { fixtureExecution: () => execution })
function Fixture() {
 const [show, setShow] = useState(true)
 return html`<main style="max-width:1100px;margin:16px auto;padding:16px">
  <p>Synthetic HTTP · actual package installer, declaration owner/editor and API · no backend/worker execution</p>
  <button onClick=${() => setShow(!show)}>Fixture hide/show</button>
  <button onClick=${() => workspace('/workspace')}>Workspace A</button>
  <button onClick=${() => workspace('/workspace-b')}>Workspace B</button>
  ${show ? html`<${LaneAddonsPanel} />` : html`<p>Other fixture page</p>`}
 </main>`
}
render(html`<${Fixture} />`, document.getElementById('fixture')!)
