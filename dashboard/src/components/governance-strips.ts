import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { EmptyState } from './common/empty-state'
import { LoadingState } from './common/feedback-state'
import { Card } from './common/card'
import { TimeAgo } from './common/time-ago'
import { governanceToneClass } from '../lib/tone'
import type { GovernanceTimelineEvent } from '../types'
import type { RuntimeParamsSurface } from '../api'
import { setRuntimeParam, clearRuntimeParam } from '../api/dashboard'
import { showToast } from './common/toast'
import {
  governanceData,
  runtimeLoading,
  runtimeParams,
  runtimeSurfaces,
  loadRuntimeParams,
  paramAuditEntries,
  paramAuditLoading,
  loadParamAudit,
} from './governance-store'
import type { ParamAuditEntry } from '../api'
import {
  activityKindLabel,
  formatParamValue,
} from './governance-utils'

const editingParam = signal<string | null>(null)
const editValue = signal<string>('')

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
                      ${surfaceParams.map(param => {
                        const isEditing = editingParam.value === param.key
                        const meta = param.meta
                        return html`
                        <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-white/3 ${param.has_override ? 'border border-warn/20' : ''}">
                          <div class="flex flex-col gap-0.5">
                            <span class="text-xs font-mono text-text-muted">${param.key}</span>
                            ${meta?.description ? html`<span class="text-[10px] text-text-muted/60">${meta.description}</span>` : null}
                          </div>
                          <div class="flex items-center gap-2">
                            ${isEditing ? html`
                              <input type="number"
                                class="w-20 py-0.5 px-2 rounded text-xs font-mono bg-[var(--white-5)] border border-[var(--white-10)] text-text-strong outline-none focus:border-accent/50"
                                value=${editValue.value}
                                min=${meta?.min_value ?? ''}
                                max=${meta?.max_value ?? ''}
                                onInput=${(e: Event) => { editValue.value = (e.target as HTMLInputElement).value }}
                                onKeyDown=${(e: KeyboardEvent) => {
                                  if (e.key === 'Enter') {
                                    const val = meta?.value_type === 'float' ? parseFloat(editValue.value) : parseInt(editValue.value, 10)
                                    if (!isNaN(val)) {
                                      void setRuntimeParam(param.key, val).then((res) => {
                                        editingParam.value = null
                                        const isPetition = res.message?.includes('petition')
                                        showToast(res.message ?? 'Parameter updated', isPetition ? 'warning' : 'success')
                                        void loadRuntimeParams()
                                      })
                                    }
                                  } else if (e.key === 'Escape') {
                                    editingParam.value = null
                                  }
                                }}
                              />
                              <button type="button"
                                class="text-[10px] py-0.5 px-1.5 rounded bg-[var(--accent-10)] text-accent hover:bg-accent/20 cursor-pointer border-none"
                                onClick=${() => {
                                  const val = meta?.value_type === 'float' ? parseFloat(editValue.value) : parseInt(editValue.value, 10)
                                  if (!isNaN(val)) {
                                    void setRuntimeParam(param.key, val).then((res) => {
                                      editingParam.value = null
                                      const isPetition = res.message?.includes('petition')
                                      showToast(res.message ?? 'Parameter updated', isPetition ? 'warning' : 'success')
                                      void loadRuntimeParams()
                                    })
                                  }
                                }}
                              >${surface.risk === 'high' ? 'Petition' : 'Apply'}</button>
                              <button type="button"
                                class="text-[10px] py-0.5 px-1.5 rounded bg-white/5 text-text-muted hover:bg-white/10 cursor-pointer border-none"
                                onClick=${() => { editingParam.value = null }}
                              >Cancel</button>
                            ` : html`
                              <span class="text-xs font-medium text-text-strong">
                                ${formatParamValue(param.current)}
                              </span>
                              ${param.has_override ? html`
                                <span class="text-[10px] text-warn font-bold">override</span>
                                <button type="button"
                                  class="text-[10px] py-0.5 px-1.5 rounded bg-white/5 text-text-muted hover:bg-white/10 cursor-pointer border-none"
                                  onClick=${() => {
                                    void clearRuntimeParam(param.key).then((res) => {
                                      const isPetition = res.message?.includes('petition')
                                      showToast(res.message ?? 'Parameter reset', isPetition ? 'warning' : 'success')
                                      void loadRuntimeParams()
                                    })
                                  }}
                                >${surface.risk === 'high' ? 'Petition Reset' : 'Reset'}</button>
                              ` : null}
                              <button type="button"
                                class="text-[10px] py-0.5 px-1.5 rounded ${surface.risk === 'high' ? 'bg-warn/10 text-warn hover:bg-warn/20' : 'bg-white/5 text-text-muted hover:bg-white/10'} cursor-pointer border-none"
                                onClick=${() => {
                                  editingParam.value = param.key
                                  editValue.value = String(param.current)
                                }}
                              >${surface.risk === 'high' ? 'Edit (petition)' : 'Edit'}</button>
                            `}
                          </div>
                        </div>
                      `})}
                    </div>
                  </div>
                `
              })}
            </div>
          `}
    <//>
  `
}

export function ParamAuditTrail() {
  const entries = paramAuditEntries.value
  const loading = paramAuditLoading.value

  if (entries.length === 0 && !loading) return null

  return html`
    <${Card} title="파라미터 변경 이력" class="section mb-4">
      ${loading
        ? html`<${LoadingState}>이력 로딩 중...<//>`
        : html`
            <div class="flex flex-col gap-1.5">
              ${entries.slice(0, 20).map((entry: ParamAuditEntry) => html`
                <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-white/3 border border-card-border">
                  <div class="flex flex-col gap-0.5 flex-1 min-w-0">
                    <div class="flex items-center gap-2">
                      <span class="text-xs font-mono text-accent truncate">${entry.key}</span>
                      <span class="text-[10px] text-text-dim"><${TimeAgo} timestamp=${entry.timestamp} /></span>
                    </div>
                    <div class="flex items-center gap-1 text-[11px]">
                      <span class="text-text-muted">${formatAuditValue(entry.old_value)}</span>
                      <span class="text-text-dim">${'\u2192'}</span>
                      <span class="text-text-strong">${formatAuditValue(entry.new_value)}</span>
                      <span class="text-text-dim ml-1">by ${entry.actor}</span>
                    </div>
                  </div>
                  <button
                    class="text-[10px] py-0.5 px-2 rounded bg-white/5 text-text-muted hover:bg-white/10 cursor-pointer border-none shrink-0 ml-2"
                    onClick=${() => rollbackParam(entry)}
                  >되돌리기</button>
                </div>
              `)}
            </div>
          `}
    <//>
  `
}

function formatAuditValue(value: unknown): string {
  if (value === null || value === undefined) return 'null'
  if (typeof value === 'object') return JSON.stringify(value)
  return String(value)
}

async function rollbackParam(entry: ParamAuditEntry) {
  try {
    const res = await setRuntimeParam(entry.key, entry.old_value, 'rollback from audit trail')
    if (res.ok) {
      showToast('파라미터를 이전 값으로 되돌렸습니다', 'success')
      void loadRuntimeParams()
      void loadParamAudit()
    } else {
      showToast(res.message || '되돌리기 실패', 'error')
    }
  } catch (err) {
    showToast(err instanceof Error ? err.message : '되돌리기 실패', 'error')
  }
}
