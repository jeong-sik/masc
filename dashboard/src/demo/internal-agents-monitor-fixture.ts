import '../styles/ds-theme-tokens.css'
import '../styles/global.css'
import '../styles/tokens.css'
import '../styles/surfaces-v2.css'
import '../styles/keeper-v2/colors_and_type.css'
import '../styles/keeper-v2/v2.css'
import '../styles/keeper-v2/surfaces.css'
import '../styles/keeper-v2/monitor.css'

import { html } from 'htm/preact'
import { render } from 'preact'

import { InternalAgentsMonitor } from '../components/internal-agents-monitor'

const root = document.getElementById('app')
if (root) {
  render(
    html`
      <main class="min-h-screen bg-[var(--color-bg-page)] p-6 text-[var(--color-fg-primary)]">
        <div class="mx-auto max-w-[1180px]"><${InternalAgentsMonitor} /></div>
      </main>
    `,
    root,
  )
}
