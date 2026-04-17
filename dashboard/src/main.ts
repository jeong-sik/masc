// MASC Dashboard — Entry point
// Mounts the root <App /> component into the DOM

// Foundation styles (load first)
import './styles/tokens.css'
import './styles/variables.css'
import './styles/base.css'
import './styles/keyframes.css'

// Opt-in paper theme — activated by ?theme=paper or
// localStorage.dashboardTheme = "paper". Component code is unchanged;
// the theme only swaps the values behind existing --color-* tokens.
import './styles/paper-theme.css'

// Global utilities and layout
import './styles/global.css'

// Component-specific styles
import './styles/ui.css'
import './styles/board.css'
/* chat.css: styles merged into global.css @utility blocks (#3915) */
import './styles/dashboard.css'
import './styles/governance.css'
import './styles/governance-agent.css'
import './styles/ops.css'
import './styles/tools.css'

import { render } from 'preact'
import { html } from 'htm/preact'
import { App } from './app'

// Theme resolution precedence: ?theme= URL param (session scoped) >
// localStorage.dashboardTheme (persistent) > default (unset).
// Invalid values are silently dropped so a typo cannot break layout.
function resolveTheme(): string | null {
  const valid = new Set(['paper'])
  const fromUrl = new URLSearchParams(window.location.search).get('theme')
  if (fromUrl && valid.has(fromUrl)) {
    try { localStorage.setItem('dashboardTheme', fromUrl) } catch { /* quota */ }
    return fromUrl
  }
  if (fromUrl === '') {
    try { localStorage.removeItem('dashboardTheme') } catch { /* quota */ }
    return null
  }
  try {
    const stored = localStorage.getItem('dashboardTheme')
    if (stored && valid.has(stored)) return stored
  } catch { /* access denied */ }
  return null
}

const theme = resolveTheme()
if (theme) {
  document.documentElement.dataset.theme = theme
}

const root = document.getElementById('app')
if (root) {
  render(html`<${App} />`, root)
}
