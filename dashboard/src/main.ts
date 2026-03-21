// MASC Dashboard — Entry point
// Mounts the root <App /> component into the DOM

import './styles/global.css'
import './styles/ui.css'
import './styles/agent.css'
import './styles/keeper.css'
import './styles/keeper-chat.css'
import './styles/board.css'
import './styles/dashboard.css'
import './styles/status.css'
import './styles/governance.css'
import './styles/layout.css'
import './styles/goals.css'
import './styles/ops.css'
import './styles/command.css'
import './styles/animations.css'
import './styles/pixel-avatars.css'
import './styles/overview.css'
import './styles/live.css'
import './styles/tools.css'
import './styles/chat.css'
import './styles/roster.css'

import './styles/oas-pipeline.css'
import './styles/agent-monitor.css'
import './styles/logs.css'

import { render } from 'preact'
import { html } from 'htm/preact'
import { App } from './app'

const root = document.getElementById('app')
if (root) {
  render(html`<${App} />`, root)
}
