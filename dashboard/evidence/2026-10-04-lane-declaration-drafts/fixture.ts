import { html } from 'htm/preact'
import { render } from 'preact'
import { Status } from '../../src/components/status'
import { navigate } from '../../src/router'
import { hydrateExecutionSnapshot, invalidateExecutionSnapshotGeneration } from '../../src/store'
import '../../src/styles/global.css'
import '../../src/styles/tokens.css'
import '../../src/styles/keeper-v2/colors_and_type.css'

let generation = 0
const epoch = 'synthetic-lane-drafts-browser'
invalidateExecutionSnapshotGeneration(epoch, 0)
function workspace(root: string) {
  hydrateExecutionSnapshot({ execution_publication_epoch: epoch, execution_publication_generation: ++generation,
    status: { project: 'fixture', workspace_root: root } } as Parameters<typeof hydrateExecutionSnapshot>[0])
}
workspace('/fixture/workspace-a')
navigate('monitoring', { section: 'lane-addons' })
render(html`<main style="max-width:1250px;margin:20px auto;padding:16px">
  <p>Synthetic HTTP + accepted execution authority fixture · actual Status/router/Lane editor</p>
  <div style="display:flex;gap:12px;margin:16px 0">
    <button onClick=${() => navigate('monitoring', { section: 'skills' })}>Fixture leave to Skills</button>
    <button onClick=${() => navigate('monitoring', { section: 'lane-addons' })}>Fixture return to Lanes</button>
    <button onClick=${() => workspace('/fixture/workspace-a')}>Fixture workspace A</button>
    <button onClick=${() => workspace('/fixture/workspace-b')}>Fixture workspace B</button>
  </div>
  <${Status} />
</main>`, document.getElementById('fixture')!)
