// 라이브 모니터 — 3패널 실시간 관찰 화면
// 상단 pulse strip + 좌측 activity stream + 우측 focus sidebar

import { html } from 'htm/preact'
import { PulseStrip } from './live/pulse-strip'
import { ActivityStream } from './live/activity-stream'
import { FocusSidebar } from './live/focus-sidebar'
import { connected, eventCount } from '../sse'
import { agents } from '../store'

export function Live() {
  const isConnected = connected.value

  return html`
    <div class="grid gap-4">
      <div class="live-header">
        <h2 class="m-0 text-[1.25rem] font-semibold">라이브 모니터</h2>
        <div class="flex gap-3 items-center text-[13px] text-[var(--white-50)]">
          <span class="live-stat">
            <span class="live-stat-dot ${isConnected ? 'connected' : 'disconnected'}"></span>
            ${isConnected ? '연결됨' : '오프라인'}
          </span>
          <span class="live-stat">에이전트 ${agents.value.length}</span>
          <span class="live-stat">이벤트 ${eventCount.value}</span>
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
