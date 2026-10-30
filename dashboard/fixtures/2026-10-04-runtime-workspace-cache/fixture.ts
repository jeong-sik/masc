import { html } from 'htm/preact'
import { render } from 'preact'
import { AgentRuntimeStrip } from '../../src/components/agent-monitor/runtime-strip'
import { FleetRotationSection } from '../../src/components/fleet-aside-extras'
import { hydrateExecutionSnapshot, invalidateExecutionSnapshotGeneration, keepers } from '../../src/store'
import { reloadRuntimeCatalog } from '../../src/lib/runtime-catalog-resource'
import { reloadRuntimeResolved } from '../../src/lib/runtime-resolved-resource'
import type { Keeper } from '../../src/types'
import '../../src/styles/global.css'
import '../../src/styles/tokens.css'
import '../../src/styles/keeper-v2/colors_and_type.css'
import '../../src/styles/keeper-v2/runtime.css'
const keeper = { name: 'fixture', agent_name: 'fixture-agent', status: 'idle', phase: 'Paused',
  runtime_canonical: 'shared.runtime', pipeline_stage: 'idle', context_ratio: 0.2,
} as Keeper
let generation = 0
const epoch = 'synthetic-runtime-workspace-cache'
invalidateExecutionSnapshotGeneration(epoch, 0)
function workspace(root: string | null) {
  hydrateExecutionSnapshot({ execution_publication_epoch: epoch, execution_publication_generation: ++generation,
    status: { project: 'fixture', workspace_root: root },
  } as Parameters<typeof hydrateExecutionSnapshot>[0])
  keepers.value = [keeper]
}
workspace('/fixture/A')
render(html`<main style="max-width:1100px;margin:32px auto;padding:20px">
  <h1>작업공간별 런타임 목록</h1>
  <p>Synthetic HTTP · real shared resources, AgentRuntimeStrip and FleetRotationSection · no live Keeper</p>
  <div style="display:flex;gap:12px;flex-wrap:wrap;margin:20px 0">
    <button onClick=${() => workspace('/fixture/A')}>Fixture workspace A</button>
    <button onClick=${() => workspace('/fixture/B')}>Fixture workspace B</button>
    <button onClick=${() => workspace(null)}>Fixture withdraw authority</button>
    <button onClick=${() => Promise.allSettled([reloadRuntimeCatalog(), reloadRuntimeResolved()])}>Fixture refresh</button>
  </div>
  <section style="border:1px solid #62523e;padding:24px;margin-top:20px">
    <h2>렌더 중 목록 요청하는 런타임 표시</h2><${AgentRuntimeStrip} name="fixture" />
  </section>
  <section style="border:1px solid #62523e;padding:24px;margin-top:20px">
    <h2>처음 열 때 한 번 요청하는 후보 표시</h2><${FleetRotationSection} keeper=${keeper} />
  </section>
</main>`, document.getElementById('fixture')!)
