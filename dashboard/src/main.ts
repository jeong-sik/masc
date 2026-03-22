// MASC Dashboard — Entry point
// Mounts the root <App /> component into the DOM

import './styles/global.css'
import './styles/ui.css'
import './styles/dashboard.css'
import './styles/governance.css'
import './styles/ops.css'
import './styles/command-swarm.css'
import './styles/pixel-avatars.css'
import './styles/overview.css'
import './styles/live.css'
import './styles/roster.css'
import './styles/oas-pipeline.css'

import { render } from 'preact'
import { html } from 'htm/preact'
import { App } from './app'

const root = document.getElementById('app')
if (root) {
  render(html`<${App} />`, root)
}
