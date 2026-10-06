import { html } from 'htm/preact'
import { render } from 'preact'
import { signal } from '@preact/signals'
import { OverviewRuntimeStats } from '../../src/components/overview/runtime-stats'
import { ConfigResolutionPanel } from '../../src/components/tools/config-resolution-panel'
import { hydrateExecutionSnapshot, invalidateExecutionSnapshotGeneration } from '../../src/store'
import { resolution } from './payloads.mjs'
import '../../src/styles/ds-theme-tokens.css'
import '../../src/styles/styleseed-theme.css'
import '../../src/styles/styleseed-base.css'
import '../../src/styles/global.css'
import '../../src/styles/tokens.css'
import '../../src/styles/keeper-v2/colors_and_type.css'
import '../../src/styles/keeper-v2/runtime.css'
const selected = signal<string | null>('A')
const epoch = 'runtime-observation-browser-fixture'
let generation = 0
invalidateExecutionSnapshotGeneration(epoch, 0)
function workspace(name: string | null) {
  hydrateExecutionSnapshot({ execution_publication_epoch: epoch, execution_publication_generation: ++generation,
    status: { project: 'fixture', workspace_root: name === null ? null : `/fixture/${name}` },
  } as Parameters<typeof hydrateExecutionSnapshot>[0])
  selected.value = name
}
workspace('A')
function Fixture() {
  return html`<main style="max-width:1100px;margin:24px auto;padding:20px">
    <h1>작업공간별 통계와 연결 상태</h1>
    <p>Synthetic HTTP · actual OverviewRuntimeStats, ConfigResolutionPanel and API decoders · no backend or CLI execution</p>
    <p>Fixture workspace: ${selected.value ?? 'unconfirmed'}</p>
    <div style="display:flex;gap:12px;flex-wrap:wrap;margin:20px 0">
      <button onClick=${() => workspace('A')}>Fixture workspace A</button>
      <button onClick=${() => workspace('B')}>Fixture workspace B</button>
      <button onClick=${() => workspace(null)}>Fixture withdraw authority</button>
    </div>
    <${OverviewRuntimeStats} />
    <${ConfigResolutionPanel} runtimeResolution=${resolution(selected.value ?? 'unconfirmed')} />
  </main>`
}
render(html`<${Fixture} />`, document.getElementById('fixture')!)
