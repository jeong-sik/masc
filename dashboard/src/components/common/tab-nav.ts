// Tab navigation bar — controls hash-based routing

import { html } from 'htm/preact'
import type { TabId } from '../../types'
import { route, navigate } from '../../router'

interface TabDef {
  id: TabId
  label: string
  icon: string
}

const TABS: TabDef[] = [
  { id: 'overview', label: 'Overview', icon: '\uD83C\uDFE0' },
  { id: 'council', label: 'Council', icon: '\uD83C\uDFDB\uFE0F' },
  { id: 'board', label: 'Board', icon: '\uD83D\uDCAC' },
  { id: 'activity', label: 'Activity', icon: '\uD83D\uDCCA' },
  { id: 'agents', label: 'Agents', icon: '\uD83E\uDD16' },
  { id: 'tasks', label: 'Tasks', icon: '\uD83D\uDCCB' },
  { id: 'journal', label: 'Journal', icon: '\uD83D\uDCD3' },
  { id: 'trpg', label: 'TRPG', icon: '\u2694\uFE0F' },
]

export function TabNav() {
  const currentTab = route.value.tab

  return html`
    <div class="main-tab-bar">
      ${TABS.map(t => html`
        <button
          class="main-tab-btn ${currentTab === t.id ? 'active' : ''}"
          onClick=${() => navigate(t.id)}
        >
          ${t.icon} ${t.label}
        </button>
      `)}
    </div>
  `
}
