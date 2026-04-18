// 라이브 모니터 — 3패널 실시간 관찰 화면
// 상단 pulse strip + 좌측 activity stream + 우측 focus sidebar

import { html } from 'htm/preact'
import { PulseStrip } from './live/pulse-strip'
import { KeeperHealthStrip } from './live/keeper-health-strip'
import { ActivityStream } from './live/activity-stream'
import { FocusSidebar } from './live/focus-sidebar'
import { CollapsibleSection } from './common/collapsible'

interface LiveProps {
  variant?: 'full' | 'observatory'
}

export function Live({ variant = 'full' }: LiveProps) {
  const observatoryMode = variant === 'observatory'

  return html`
    <div class="flex flex-col gap-5">
      ${!observatoryMode ? html`
        <section class="monitor-surface-card monitor-surface-card-strong px-5 py-4">
          <div class="flex flex-col gap-2">
            <div class="flex flex-col gap-2">
              <h2 class="m-0 text-[1.25rem] font-semibold text-[var(--text-strong)]">라이브 모니터</h2>
              <p class="m-0 text-sm leading-paragraph text-[var(--text-body)]">실시간 이벤트 흐름과 활성 에이전트 상태를 한 화면에서 봅니다.</p>
            </div>
          </div>
        </section>
      ` : null}

      ${!observatoryMode ? html`
        <section class="rounded-[var(--radius-xl)] border border-[var(--border-slate-12)] bg-[var(--white-3)] p-4">
          <${PulseStrip} />
        </section>
      ` : null}

      ${!observatoryMode ? html`<${KeeperHealthStrip} />` : null}

      ${observatoryMode ? html`
        <section class="live-panel-main monitor-surface-card monitor-surface-card-medium p-4">
          <${ActivityStream} />
        </section>

        <${CollapsibleSection} title="에이전트 상태 상세">
          <${FocusSidebar} compact=${true} />
        <//>
      ` : html`
        <div class="live-panels grid gap-4 xl:grid-cols-[minmax(0,1.35fr)_minmax(320px,0.9fr)]">
          <section class="live-panel-main monitor-surface-card monitor-surface-card-medium min-h-[420px] xl:min-h-130 p-4">
            <${ActivityStream} />
          </section>
          <section class="live-panel-side monitor-surface-card monitor-surface-card-medium min-h-[420px] xl:min-h-130 p-4">
            <${FocusSidebar} />
          </section>
        </div>
      `}
    </div>
  `
}
