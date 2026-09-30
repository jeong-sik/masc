import '../styles/ds-theme-tokens.css'
import '../styles/global.css'
import '../styles/keeper-workspace.css'

import { html } from 'htm/preact'
import { render } from 'preact'
import { signal } from '@preact/signals'
import type { Keeper } from '../types'
import { hydrateExecutionSnapshot } from '../store'
import { KeeperItemsPanel } from '../components/keeper-items-panel'
import { KeeperDetailSection, KeeperDetailSectionRail, activeKeeperDetailSection } from '../components/keeper-detail-shell'

const keeper = signal({
  name: 'rondo',
  portrait: {
    state: 'ready',
    equipment: { face: 'bare_face', neck: 'bare_neck', head: 'crown', hand: 'empty_hand', base: 'no_dish' },
  },
} as Keeper)

// Only this isolated fixture exposes a controlled roster observation.
declare global {
  interface Window {
    updateKeeperItemsFixture: (revision: string) => void
  }
}
window.updateKeeperItemsFixture = revision => {
  keeper.value = { ...keeper.value, candle_account_revision: revision }
}

// This isolated fixture has no production HTTP/SSE bootstrap. Admit its
// explicitly synthetic workspace through the same store path as production.
declare global {
  interface Window {
    updateKeeperItemsWorkspaceFixture: (workspaceRoot: string | null) => void
  }
}
let fixturePublicationGeneration = 0
window.updateKeeperItemsWorkspaceFixture = workspaceRoot => {
  const accepted = hydrateExecutionSnapshot({
    execution_publication_epoch: 'keeper-items-browser-fixture',
    execution_publication_generation: ++fixturePublicationGeneration,
    status: { project: 'keeper-items-fixture', ...(workspaceRoot === null ? {} : { workspace_root: workspaceRoot }) },
  })
  if (!accepted) throw new Error('Item fixture workspace observation refused')
}
window.updateKeeperItemsWorkspaceFixture('/fixture/keeper-items')

activeKeeperDetailSection.value = 'keeper-items'
const root = document.getElementById('app')
function Fixture() {
  return html`
  <main class="kw-detail-content mx-auto flex w-full max-w-[1380px] flex-col gap-5 pb-8" style="background: var(--color-bg-page); color: var(--color-fg-primary)">
    <header class="kw-detail-full-head w-full p-4"><h1 class="m-0 text-xl font-semibold">${keeper.value.name}</h1></header>
    <div class="kw-detail-body mx-auto flex w-full max-w-[1180px] flex-col gap-5">
      <${KeeperDetailSectionRail} />
      <${KeeperDetailSection} id="keeper-items" eyebrow="Candle & 초상화" title="아이템">
        <${KeeperItemsPanel} keeper=${keeper.value} />
      <//>
    </div>
  </main>
`
}
if (root) render(html`<${Fixture} />`, root)
