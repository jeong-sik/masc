import { html } from 'htm/preact'
import { render } from 'preact'
import { Status } from '../../src/components/status'
import { navigate, initRouter } from '../../src/router'
import { hydrateExecutionSnapshot, invalidateExecutionSnapshotGeneration } from '../../src/store'
import '../../src/styles/global.css'
import '../../src/styles/tokens.css'
import '../../src/styles/keeper-v2/colors_and_type.css'
import '../../src/styles/keeper-v2/runtime.css'
let generation = 0
const epoch = 'synthetic-lane-navigation'
invalidateExecutionSnapshotGeneration(epoch, 0)
function workspace(root: string) {
  hydrateExecutionSnapshot({ execution_publication_epoch: epoch, execution_publication_generation: ++generation,
    status: { project: 'fixture', workspace_root: root } } as Parameters<typeof hydrateExecutionSnapshot>[0])
}
workspace('/fixture/A')
if (location.hash) initRouter()
else navigate('monitoring', { section: 'lane-inventory' })
render(html`<main style="max-width:1400px;margin:24px auto;padding:16px">
  <p>Synthetic HTTP · actual Status/router/Lane controls · no live backend</p>
  <div style="display:flex;gap:12px;flex-wrap:wrap;margin:16px 0">
    <button onClick=${() => navigate('monitoring', { section: 'lane-inventory' })}>Fixture All Lanes</button>
    <button onClick=${() => workspace('/fixture/A')}>Fixture workspace A</button>
    <button onClick=${() => workspace('/fixture/B')}>Fixture workspace B</button>
  </div><${Status} />
</main>`, document.getElementById('fixture')!)
