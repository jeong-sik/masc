import { html } from 'htm/preact'
import { render } from 'preact'
import { Status } from '../../src/components/status'
import { hydrateExecutionSnapshot, invalidateExecutionSnapshotGeneration } from '../../src/store'
import { navigate } from '../../src/router'
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
const execution = { execution_publication_epoch: 'web-machine-activity-fixture', execution_publication_generation: 1,
  status: { project: 'fixture', workspace_root: '/fixture' } }
invalidateExecutionSnapshotGeneration(execution.execution_publication_epoch, 0)
hydrateExecutionSnapshot(execution as Parameters<typeof hydrateExecutionSnapshot>[0])
Object.assign(window, { fixtureExecution: () => execution })
navigate('monitoring', { section: 'runtime', view: 'config' })
render(html`<main style="max-width:1200px;margin:20px auto;padding:16px">
  <p>Synthetic HTTP · actual Status, Machine activity, raw editor, router and API · no backend/model execution</p>
  <button onClick=${() => navigate('monitoring', { section: 'lane-inventory' })}>Fixture All Lanes</button>
  <button onClick=${() => navigate('monitoring', { section: 'runtime', view: 'config' })}>Fixture Runtime</button>
  <${Status} />
</main>`, document.getElementById('fixture')!)
