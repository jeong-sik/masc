import { html } from 'htm/preact'
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
    <${Card} title="활동 타임라인" class="section mb-3.5">
      <div class="flex flex-col gap-2">
        ${grouped.size === 0
          ? html`<div class="empty-state text-center border border-dashed border-[var(--card-border)] rounded-[10px] py-[22px] px-4 text-[color:var(--text-muted)]">거버넌스 활동이 아직 없습니다.</div>`
          : Array.from(grouped.entries()).map(([, group]) => html`
              <div class="governance-case-group rounded-lg">
                <div class="flex items-center justify-between mb-2 gap-2">
                  <span class="governance-case-topic">${group.topic}</span>
                  <${LifecycleProgress} events=${group.events} />
                </div>
                <div class="governance-case-events">
                  ${group.events.map((event: GovernanceTimelineEvent) => html`
                    <div class="governance-activity-row">
                      <span class="governance-badge rounded-full ${governanceToneClass(event.kind)}">${activityKindLabel(event.kind)}</span>
                      <span class="governance-event-summary">${event.summary || ''}</span>
                      ${event.created_at ? html`<span class="governance-event-time"><${TimeAgo} timestamp=${event.created_at} /></span>` : null}
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
        const cls = done ? (current ? 'lifecycle-current' : 'lifecycle-done') : 'lifecycle-pending'
        return html`
          ${index > 0 ? html`<span class="lifecycle-arrow ${done ? 'done' : ''}">-></span>` : null}
          <span class="lifecycle-step ${cls}">${label}</span>
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
    <div class="monitor-meta" style="margin-top:4px;margin-bottom:8px">
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
    <${Card} title="Runtime Parameters" class="section mb-3.5">
      ${runtimeLoading.value
        ? html`<div class="text-center border border-dashed border-[var(--card-border)] rounded-xl py-12 px-4 text-[color:var(--text-muted)]">파라미터 로딩 중...</div>`
        : html`
            <div class="governance-params-surfaces">
              ${surfaces.map((surface: RuntimeParamsSurface) => {
                const surfaceParams = params.filter(p => surface.param_keys.includes(p.key))
                return html`
                  <div class="governance-surface-group">
                    <div class="governance-surface-head">
                      <strong>${surface.id}</strong>
                      <span class="governance-chip rounded-full ${surface.risk === 'high' ? 'warn' : ''}">${surface.risk}</span>
                      <span class="mt-1 flex flex-wrap gap-2 text-[#8ea9d6] text-[length:var(--fs-xs)]">${surface.description}</span>
                    </div>
                    <div class="governance-params-table">
                      ${surfaceParams.map(param => html`
                        <div class="governance-param-row ${param.has_override ? 'overridden' : ''}">
                          <span class="governance-param-key">${param.key}</span>
                          <span class="governance-param-value">
                            ${formatParamValue(param.current)}
                            ${param.has_override
                              ? html`<span class="governance-chip rounded-full warn" style="margin-left:4px">override</span>`
                              : null}
                          </span>
                          <span class="governance-param-default mt-1 flex flex-wrap gap-2 text-[#8ea9d6] text-[length:var(--fs-xs)]">
                            기본: ${formatParamValue(param.default)}
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
