// MASC Dashboard — Entry point
// Mounts the root <App /> component into the DOM

import './styles/global.css'

import { render } from 'preact'
import { html } from 'htm/preact'
import { App } from './app'

const root = document.getElementById('app')
if (root) {
  render(html`<${App} />`, root)
}
