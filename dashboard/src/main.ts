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
import './styles/status.css'
import './styles/governance.css'
import './styles/layout.css'
import './styles/goals.css'
import './styles/ops.css'
import './styles/command.css'
import './styles/command-swarm.css'
import './styles/command-gauge.css'
import './styles/activity.css'
import './styles/social.css'
import './styles/animations.css'
import './styles/spacing.css'
import './styles/pixel-avatars.css'
import './styles/overview.css'
import './styles/live.css'
import './styles/tool-metrics.css'
import './styles/tools.css'
import './styles/chat.css'
import './styles/roster.css'
import './styles/ff-theme.css'
import './styles/oas-pipeline.css'
import './styles/pipeline-stage.css'
import './styles/logs.css'

import { render } from 'preact'
import { html } from 'htm/preact'
import { App } from './app'

const root = document.getElementById('app')
if (root) {
  render(html`<${App} />`, root)
}
