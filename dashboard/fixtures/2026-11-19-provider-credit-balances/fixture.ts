import { html } from 'htm/preact'
import { render } from 'preact'
import { OverviewRuntimeStats } from '../../src/components/overview/runtime-stats'
import { hydrateExecutionSnapshot, invalidateExecutionSnapshotGeneration } from '../../src/store'
import '../../src/styles/ds-theme-tokens.css'
import '../../src/styles/styleseed-theme.css'
import '../../src/styles/styleseed-base.css'
import '../../src/styles/global.css'
import '../../src/styles/tokens.css'
import '../../src/styles/keeper-v2/colors_and_type.css'
import '../../src/styles/keeper-v2/runtime.css'

const epoch = 'provider-credit-balances-browser-fixture'
invalidateExecutionSnapshotGeneration(epoch, 0)
hydrateExecutionSnapshot({
  projection_diagnostics: { read_completeness: 'complete', read_error: null },
  observer_instance_id: epoch,
  execution_publication_epoch: epoch,
  execution_publication_generation: 1,
  status: { project: 'fixture', workspace_root: '/fixture/provider-credit-balances' },
} as Parameters<typeof hydrateExecutionSnapshot>[0])

render(html`
  <main style="max-width:1100px;margin:24px auto;padding:20px">
    <h1>Provider Credit balances</h1>
    <p>Synthetic HTTP · actual OverviewRuntimeStats and API decoders · no provider calls</p>
    <${OverviewRuntimeStats} />
  </main>
`, document.getElementById('fixture')!)
