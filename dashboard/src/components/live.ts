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
    <div class="flex flex-col gap-5">
      <section class="rounded-[24px] border border-[var(--card-border)] bg-[var(--card)] px-5 py-4 shadow-[0_12px_30px_rgba(0,0,0,0.16)]">
        <div class="flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
          <div class="flex flex-col gap-2">
            <h2 class="m-0 text-[1.25rem] font-semibold text-[var(--text-strong)]">라이브 모니터</h2>
            <p class="m-0 text-[13px] leading-[1.55] text-[var(--text-body)]">실시간 이벤트 흐름과 활성 에이전트 상태를 한 화면에서 봅니다.</p>
          </div>
          <div class="flex flex-wrap gap-2 items-center text-[13px] text-[var(--text-muted)]">
            <span class="inline-flex items-center gap-2 rounded-full border border-[var(--border-slate-12)] bg-[var(--white-3)] px-3 py-1.5">
            <span class="live-stat-dot ${isConnected ? 'connected' : 'disconnected'}"></span>
            ${isConnected ? '연결됨' : '오프라인'}
            </span>
            <span class="inline-flex items-center rounded-full border border-[var(--border-slate-12)] bg-[var(--white-3)] px-3 py-1.5">에이전트 ${agents.value.length}</span>
            <span class="inline-flex items-center rounded-full border border-[var(--border-slate-12)] bg-[var(--white-3)] px-3 py-1.5">이벤트 ${eventCount.value}</span>
          </div>
        </div>
      </section>

      <section class="rounded-[24px] border border-[var(--border-slate-12)] bg-[var(--white-3)] p-4">
        <${PulseStrip} />
      </section>

      <div class="live-panels grid gap-4 xl:grid-cols-[minmax(0,1.35fr)_minmax(320px,0.9fr)]">
        <section class="live-panel-main min-h-[420px] xl:min-h-[520px] rounded-[24px] border border-[var(--card-border)] bg-[var(--card)] p-4 shadow-[0_10px_24px_rgba(0,0,0,0.14)]">
          <${ActivityStream} />
        </section>
        <section class="live-panel-side min-h-[420px] xl:min-h-[520px] rounded-[24px] border border-[var(--card-border)] bg-[var(--card)] p-4 shadow-[0_10px_24px_rgba(0,0,0,0.14)]">
          <${FocusSidebar} />
        </section>
      </div>
    </div>
  `
}
