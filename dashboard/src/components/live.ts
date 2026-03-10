// Live Monitor — 3-panel real-time swarm observation view
// Pulse Strip (top) + Activity Stream (left 60%) + Focus Sidebar (right 40%)

import { html } from 'htm/preact'
import { PulseStrip } from './live/pulse-strip'
import { ActivityStream } from './live/activity-stream'
import { FocusSidebar } from './live/focus-sidebar'
import { connected, eventCount } from '../sse'
import { agents } from '../store'

export function Live() {
  const isConnected = connected.value

  return html`
    <div class="live-monitor">
      <div class="live-header">
        <h2>Live Monitor</h2>
        <div class="live-header-stats">
          <span class="live-stat">
            <span class="live-stat-dot ${isConnected ? 'connected' : 'disconnected'}"></span>
            ${isConnected ? 'Connected' : 'Offline'}
          </span>
          <span class="live-stat">${agents.value.length} agents</span>
          <span class="live-stat">${eventCount.value} events</span>
        </div>
      </div>

      <${PulseStrip} />

      <div class="live-panels">
        <div class="live-panel-main">
          <${ActivityStream} />
        </div>
        <div class="live-panel-side">
          <${FocusSidebar} />
        </div>
      </div>
    </div>
  `
}
