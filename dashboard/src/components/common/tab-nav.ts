// Tab navigation bar — controls hash-based routing

import { html } from 'htm/preact'
import { route, navigate } from '../../router'
import { DASHBOARD_NAV_ITEMS } from '../../config/navigation'

export function TabNav() {
  const currentTab = route.value.tab

  return html`
    <div class="flex gap-2 mb-5 p-2.5 bg-white/[0.03] rounded-xl border border-white/[0.06] flex-wrap">
      ${DASHBOARD_NAV_ITEMS.map(t => html`
        <button type="button"
          class="px-4 py-2 border-none rounded-lg bg-transparent cursor-pointer text-[13px] transition-all duration-200 ${currentTab === t.id ? 'bg-green-400/15 text-green-400' : 'text-[var(--text-dim)] hover:bg-white/[0.05] hover:text-[#ccc]'}"
          onClick=${() => navigate(t.id)}
        >
          ${t.icon} ${t.label}
        </button>
      `)}
    </div>
  `
}
