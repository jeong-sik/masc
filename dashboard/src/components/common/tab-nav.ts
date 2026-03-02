// Tab navigation bar — controls hash-based routing

import { html } from 'htm/preact'
import { route, navigate } from '../../router'
import { DASHBOARD_NAV_ITEMS } from '../../config/navigation'

export function TabNav() {
  const currentTab = route.value.tab

  return html`
    <div class="main-tab-bar">
      ${DASHBOARD_NAV_ITEMS.map(t => html`
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
