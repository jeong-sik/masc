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
    <${Card} title="활동 타임라인" class="section" semanticId="governance.activity">
      <div class="governance-activity-list">
        ${grouped.size === 0
          ? html`<div class="empty-state">거버넌스 활동이 아직 없습니다.</div>`
          : Array.from(grouped.entries()).map(([, group]) => html`
              <div class="governance-case-group">
                <div class="governance-case-header">
                  <span class="governance-case-topic">${group.topic}</span>
                  <${LifecycleProgress} events=${group.events} />
                </div>
                <div class="governance-case-events">
                  ${group.events.map((event: GovernanceTimelineEvent) => html`
                    <div class="governance-activity-row">
                      <span class="governance-badge ${governanceToneClass(event.kind)}">${activityKindLabel(event.kind)}</span>
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
    <div class="governance-lifecycle">
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
    <${Card} title="Runtime Parameters" class="section" semanticId="governance.params">
      ${runtimeLoading.value
        ? html`<div class="loading-indicator">파라미터 로딩 중...</div>`
        : html`
            <div class="governance-params-surfaces">
              ${surfaces.map((surface: RuntimeParamsSurface) => {
                const surfaceParams = params.filter(p => surface.param_keys.includes(p.key))
                return html`
                  <div class="governance-surface-group">
                    <div class="governance-surface-head">
                      <strong>${surface.id}</strong>
                      <span class="governance-chip ${surface.risk === 'high' ? 'warn' : ''}">${surface.risk}</span>
                      <span class="council-sub">${surface.description}</span>
                    </div>
                    <div class="governance-params-table">
                      ${surfaceParams.map(param => html`
                        <div class="governance-param-row ${param.has_override ? 'overridden' : ''}">
                          <span class="governance-param-key">${param.key}</span>
                          <span class="governance-param-value">
                            ${formatParamValue(param.current)}
                            ${param.has_override
                              ? html`<span class="governance-chip warn" style="margin-left:4px">override</span>`
                              : null}
                          </span>
                          <span class="governance-param-default council-sub">
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
