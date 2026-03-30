// MASC Dashboard — Entry point
// Mounts the root <App /> component into the DOM

import './styles/global.css'
import './styles/ui.css'
import './styles/agent-monitor.css'
import './styles/board.css'
import './styles/dashboard.css'
import './styles/governance.css'
import './styles/governance-agent.css'
import './styles/governance-keeper.css'
import './styles/ops.css'
import './styles/command-swarm.css'
import './styles/chat.css'
import './styles/tools.css'
import './styles/roster.css'
import './styles/mission.css'

import { render } from 'preact'
import { html } from 'htm/preact'
import { App } from './app'

const root = document.getElementById('app')
if (root) {
  render(html`<${App} />`, root)
}
