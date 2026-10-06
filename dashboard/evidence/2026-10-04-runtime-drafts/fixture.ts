import { html } from 'htm/preact'
import { render } from 'preact'
import { Status } from '../../src/components/status'
import { navigate } from '../../src/router'
import { hydrateExecutionSnapshot, invalidateExecutionSnapshotGeneration } from '../../src/store'
import '../../src/styles/global.css'
import '../../src/styles/tokens.css'
import '../../src/styles/keeper-v2/colors_and_type.css'
import '../../src/styles/keeper-v2/runtime.css'
let generation = 0, root: string | null = '/fixture/A'
const epoch = 'synthetic-runtime-drafts'
invalidateExecutionSnapshotGeneration(epoch, 0)
function snapshot() {
  return { execution_publication_epoch: epoch, execution_publication_generation: ++generation,
    status: { project: 'fixture', workspace_root: root } }
}
Object.assign(window, { fixtureExecution: snapshot })
function workspace(next: string | null) {
  root = next
  hydrateExecutionSnapshot(snapshot() as Parameters<typeof hydrateExecutionSnapshot>[0])
}
workspace(root)
const runtime = () => navigate('monitoring', { section: 'runtime', view: 'config' })
runtime()
render(html`<main style="max-width:1400px;margin:24px auto;padding:16px">
  <p>Synthetic HTTP · actual Status/router/Runtime editor and decoders · no live runtime</p>
  <div style="display:flex;gap:12px;flex-wrap:wrap;margin:16px 0">
    <button onClick=${() => navigate('monitoring', { section: 'skills' })}>Fixture leave to Skills</button>
    <button onClick=${runtime}>Fixture return to Runtime</button>
    <button onClick=${() => workspace('/fixture/A')}>Fixture workspace A</button>
    <button onClick=${() => workspace('/fixture/B')}>Fixture workspace B</button>
    <button onClick=${() => workspace(null)}>Fixture withdraw authority</button>
  </div><${Status} />
</main>`, document.getElementById('fixture')!)
