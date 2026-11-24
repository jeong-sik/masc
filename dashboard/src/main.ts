// MASC Dashboard — Entry point
// Single OKLCH design system (7 lean CSS files, 0 raw hex, 0 eager theme globs)

import './styles/tokens.generated.css'
import './styles/base.css'
import './styles/shell.css'
import './styles/primitives.css'
import './styles/charts.css'
import './styles/chat.css'
import './styles/surfaces.css'

import { render } from 'preact'
import { html } from 'htm/preact'
import { App } from './app'
import { performanceMonitor } from './lib/performance-monitor'
import { startWebVitalsCapture } from './utils/performance-metrics'
import { startNavTelemetry } from './lib/nav-telemetry'
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

performanceMonitor.start()
startWebVitalsCapture()
startNavTelemetry()
