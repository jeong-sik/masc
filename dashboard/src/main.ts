// MASC Dashboard — Entry point
// Mounts the root <App /> component into the DOM

// Foundation styles (load first)
import './styles/tokens.css'
import './styles/variables.css'
import './styles/base.css'
import './styles/keyframes.css'

// Global utilities and layout
import './styles/global.css'

// Component-specific styles
import './styles/ui.css'
import './styles/board.css'
/* chat.css: styles merged into global.css @utility blocks (#3915) */
import './styles/dashboard.css'
import './styles/governance.css'
import './styles/governance-agent.css'
import './styles/mission.css'
import './styles/ops.css'
import './styles/tools.css'

import { render } from 'preact'
import { html } from 'htm/preact'
import { App } from './app'

const root = document.getElementById('app')
if (root) {
  render(html`<${App} />`, root)
}
