import { html } from 'htm/preact'
import { render } from 'preact'
import { Status } from '../../src/components/status'
import { navigate } from '../../src/router'
import { hydrateExecutionSnapshot, invalidateExecutionSnapshotGeneration } from '../../src/store'
import '../../src/styles/global.css'
import '../../src/styles/tokens.css'
import '../../src/styles/keeper-v2/colors_and_type.css'

let generation = 0
const epoch = 'synthetic-addons-workspace'
invalidateExecutionSnapshotGeneration(epoch, 0)
function workspace(root: string | null) {
  hydrateExecutionSnapshot({ execution_publication_epoch: epoch, execution_publication_generation: ++generation,
    status: { project: 'fixture', workspace_root: root } } as Parameters<typeof hydrateExecutionSnapshot>[0])
}
workspace('/fixture/A')
navigate('monitoring', { section: 'lane-addons' })
render(html`<main style="max-width:1250px;margin:20px auto;padding:16px">
  <p>Synthetic HTTP fixture · actual Status, Add-ons component and decoder · no live package</p>
  <div style="display:flex;gap:12px;flex-wrap:wrap;margin:16px 0">
    <button onClick=${() => workspace('/fixture/A')}>Fixture workspace A</button>
    <button onClick=${() => workspace('/fixture/B')}>Fixture workspace B</button>
    <button onClick=${() => workspace(null)}>Fixture withdraw authority</button>
  </div>
  <${Status} />
</main>`, document.getElementById('fixture')!)
