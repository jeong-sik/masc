import '../styles/ds-theme-tokens.css'
import '../styles/global.css'
import '../styles/keeper-workspace.css'

import { html } from 'htm/preact'
import { render } from 'preact'
import { signal } from '@preact/signals'
import type { Keeper } from '../types'
import { KeeperItemsPanel } from '../components/keeper-items-panel'
import { KeeperDetailSection, KeeperDetailSectionRail, activeKeeperDetailSection } from '../components/keeper-detail-shell'
import { hydrateExecutionSnapshot } from '../store'

const keeper = signal({
  name: 'rondo',
  candle_account_revision: '0'.repeat(64),
  portrait: {
    state: 'ready',
    equipment: { face: 'bare_face', neck: 'bare_neck', head: 'crown', hand: 'empty_hand', base: 'no_dish' },
  },
} as Keeper)

// Only this isolated fixture exposes a controlled roster observation.
declare global {
  interface Window {
    updateKeeperItemsFixture: (revision: string) => void
    updateKeeperItemsWorkspaceFixture: (workspaceRoot?: string | null) => Parameters<typeof hydrateExecutionSnapshot>[0]
  }
}
window.updateKeeperItemsFixture = revision => {
  keeper.value = { ...keeper.value, candle_account_revision: revision }
}

// Test-only publication sequence: this isolated browser fixture has no HTTP/SSE
// bootstrap. Workspace transitions use the real store admission path while
// the Keeper, wallet, outfit and project label remain unchanged.
let fixturePublicationGeneration = 0
let fixtureWorkspaceRoot: string | null = '/fixture/keeper-items'
window.updateKeeperItemsWorkspaceFixture = (workspaceRoot = fixtureWorkspaceRoot) => {
  fixtureWorkspaceRoot = workspaceRoot
  const snapshot = {
    execution_publication_epoch: 'keeper-items-browser-fixture',
    execution_publication_generation: ++fixturePublicationGeneration,
    status: { ...(workspaceRoot === null ? {} : { workspace_root: workspaceRoot }), project: 'keeper-items-fixture' },
  }
  const accepted = hydrateExecutionSnapshot(snapshot)
  if (!accepted) throw new Error('Item browser fixture workspace observation refused')
  return snapshot
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
