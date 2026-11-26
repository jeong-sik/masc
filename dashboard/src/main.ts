// MASC Dashboard — Ultra-Lean Proposal A+ Entry Point
// Single OKLCH design system (6 lean CSS files, 0 raw hex, capability-gated boot, 0 eager god-store bloat)

import './styles/tokens.generated.css'
import './styles/base.css'
import './styles/primitives.css'
import './styles/shell.css'
import './styles/charts.css'
import './styles/surfaces.css'

import { render } from 'preact'
import { html } from 'htm/preact'
import { App } from './app'
import {
  applyContrast,
  applyTheme,
  resolveInitialContrast,
  resolveInitialTheme,
} from './lib/theme'

applyTheme(resolveInitialTheme())
applyContrast(resolveInitialContrast())

const root = document.getElementById('app')
if (root) {
  render(html`<${App} />`, root)
}
