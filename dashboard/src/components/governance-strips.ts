import { html } from 'htm/preact'
import { EmptyState } from './common/empty-state'
import { LoadingState } from './common/feedback-state'
import { Card } from './common/card'
import { TimeAgo } from './common/time-ago'
import { governanceToneClass } from '../lib/tone'
import type { GovernanceTimelineEvent } from '../types'
import type { RuntimeParamsSurface } from '../api'
import {
  governanceData,
  runtimeLoading,
  runtimeParams,
  runtimeSurfaces,
} from './governance-store'
import {
  activityKindLabel,
  formatParamValue,
} from './governance-utils'

export function ActivityRail() {
  const events = (governanceData.value?.activity ?? []).slice(0, 20)

  const grouped = new Map<string, { topic: string; events: GovernanceTimelineEvent[] }>()
  for (const event of events) {
    const key = event.item_id || event.topic || 'unknown'
    const existing = grouped.get(key)
    if (existing) {
      existing.events.push(event)
    } else {
      grouped.set(key, { topic: event.topic || key, events: [event] })
    }
  }
  return html`
    <${Card} title="활동 타임라인" class="section mb-4">
      <div class="flex flex-col gap-2">
        ${grouped.size === 0
          ? html`<${EmptyState} message="거버넌스 활동이 아직 없습니다." compact />`
          : Array.from(grouped.entries()).map(([, group]) => html`
              <div class="p-3 rounded-xl border border-card-border bg-card/40">
                <div class="flex items-center justify-between mb-2 gap-2">
                  <span class="text-[13px] font-semibold text-text-strong truncate">${group.topic}</span>
                  <${LifecycleProgress} events=${group.events} />
                </div>
                <div class="flex flex-col gap-1.5">
                  ${group.events.map((event: GovernanceTimelineEvent) => html`
                    <div class="flex items-center gap-2 text-xs">
                      <span class="governance-badge rounded-full ${governanceToneClass(event.kind)}">${activityKindLabel(event.kind)}</span>
                      <span class="text-text-muted truncate flex-1">${event.summary || ''}</span>
                      ${event.created_at ? html`<span class="text-text-dim text-[11px] shrink-0"><${TimeAgo} timestamp=${event.created_at} /></span>` : null}
                    </div>
                  `)}
                </div>
              </div>
            `)}
      </div>
    <//>
  `
}

const LIFECYCLE_ORDER: Record<string, number> = {
  petition_submitted: 0,
  brief_submitted: 1,
  ruling_issued: 2,
  execution_order: 3,
}

const LIFECYCLE_STEPS = ['청원', '의견', '판정', '집행']

function LifecycleProgress({ events }: { events: GovernanceTimelineEvent[] }) {
  const reached = new Set(events.map(event => LIFECYCLE_ORDER[event.kind] ?? -1))
  const maxStep = Math.max(...Array.from(reached), -1)
  return html`
    <div class="flex items-center gap-0.5 shrink-0">
      ${LIFECYCLE_STEPS.map((label, index) => {
        const done = reached.has(index)
        const current = index === maxStep
        const color = done
          ? (current ? 'text-accent font-bold' : 'text-ok')
          : 'text-text-dim'
        return html`
          ${index > 0 ? html`<span class="text-[10px] ${done ? 'text-ok' : 'text-text-dim'}">${'\u2192'}</span>` : null}
          <span class="text-[10px] px-1 ${color}">${label}</span>
        `
      })}
    </div>
  `
}

export function GovernanceFreshnessStrip() {
  const data = governanceData.value
  if (!data) return null
  const itemCount = data.items?.length ?? 0
  const activityCount = data.activity?.length ?? 0
  return html`
    <div class="flex flex-wrap gap-x-3 gap-y-2 mt-3 text-[var(--text-muted)] text-[13px]" style="margin-top:4px;margin-bottom:8px">
      <span>데이터 범위: 진행 중 ${itemCount}건</span>
      <span>최근 활동: ${activityCount}건</span>
      ${data.generated_at ? html`<span>생성 시각: ${data.generated_at}</span>` : null}
    </div>
  `
}

export function RuntimeParamsPanel() {
  const params = runtimeParams.value
  const surfaces = runtimeSurfaces.value
  if (params.length === 0 && !runtimeLoading.value) return null

  return html`
    <${Card} title="런타임 파라미터" class="section mb-4">
      ${runtimeLoading.value
        ? html`<${LoadingState}>파라미터 로딩 중...<//>`
        : html`
            <div class="flex flex-col gap-4">
              ${surfaces.map((surface: RuntimeParamsSurface) => {
                const surfaceParams = params.filter(p => surface.param_keys.includes(p.key))
                return html`
                  <div class="p-3 rounded-xl border border-card-border bg-card/40">
                    <div class="flex items-center gap-2 mb-2">
                      <strong class="text-[13px] text-text-strong">${surface.id}</strong>
                      <span class="governance-chip rounded-full ${surface.risk === 'high' ? 'warn' : ''}">${surface.risk}</span>
                    </div>
                    <div class="text-[11px] text-text-muted mb-3">${surface.description}</div>
                    <div class="flex flex-col gap-1.5">
                      ${surfaceParams.map(param => html`
                        <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-white/3 ${param.has_override ? 'border border-warn/20' : ''}">
                          <span class="text-xs font-mono text-text-muted">${param.key}</span>
                          <span class="text-xs font-medium text-text-strong">
                            ${formatParamValue(param.current)}
                            ${param.has_override
                              ? html`<span class="ml-1.5 text-[10px] text-warn font-bold">override</span>`
                              : null}
                          </span>
                        </div>
                      `)}
                    </div>
                  </div>
                `
              })}
            </div>
          `}
    <//>
  `
}
