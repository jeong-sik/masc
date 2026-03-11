// MASC Dashboard — Entry point
// Mounts the root <App /> component into the DOM

import './styles/global.css'
import './styles/tabs.css'
import './styles/badge-card.css'
import './styles/agent.css'
import './styles/keeper.css'
import './styles/tasks.css'
import './styles/board.css'
import './styles/trpg.css'
import './styles/ui.css'
import './styles/dashboard.css'
import './styles/council.css'
import './styles/layout.css'
import './styles/goals.css'
import './styles/ops.css'
import './styles/command.css'
import './styles/activity.css'
import './styles/animations.css'
import './styles/live.css'

import { render } from 'preact'
import { html } from 'htm/preact'
import { App } from './app'

const root = document.getElementById('app')
if (root) {
  render(html`<${App} />`, root)
}
