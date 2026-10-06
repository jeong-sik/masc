import { html } from 'htm/preact'
import { render } from 'preact'
import { Status } from '../../src/components/status'
import { hydrateExecutionSnapshot, invalidateExecutionSnapshotGeneration } from '../../src/store'
import { navigate } from '../../src/router'
import '../../src/styles/ds-theme-tokens.css'
import '../../src/styles/styleseed-theme.css'
import '../../src/styles/styleseed-base.css'
import '../../src/styles/global.css'
import '../../src/styles/tokens.css'
import '../../src/styles/keeper-v2/colors_and_type.css'
const epoch = 'synthetic-browser-activity'
invalidateExecutionSnapshotGeneration(epoch, 0)
hydrateExecutionSnapshot({ execution_publication_epoch: epoch, execution_publication_generation: 1,
  status: { project: 'fixture', workspace_root: '/fixture' } } as Parameters<typeof hydrateExecutionSnapshot>[0])
navigate('monitoring', { section: 'lane-inventory' })
render(html`<main style="max-width:1200px;margin:20px auto;padding:16px">
  <p>Synthetic Browser activity readings · actual Status and inventory · no server/model execution</p>
  <${Status} />
</main>`, document.getElementById('fixture')!)
