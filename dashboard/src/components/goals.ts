// Goals tab — view and filter goals by horizon / status / keeper

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { signal, computed } from '@preact/signals'
import { Card } from './common/card'
import { StatusBadge } from './common/status-badge'
import { TimeAgo } from './common/time-ago'
import { goals, goalsLoading, refreshGoals } from '../store'
import type { Goal } from '../types'

// ── Filter state ──────────────────────────────────

type HorizonFilter = 'all' | 'short' | 'mid' | 'long'
type StatusFilter = 'all' | 'active' | 'completed' | 'paused'

const horizonFilter = signal<HorizonFilter>('all')
const statusFilter = signal<StatusFilter>('all')

// ── Derived data ──────────────────────────────────

const filteredGoals = computed(() => {
  let list = goals.value
  if (horizonFilter.value !== 'all') {
    list = list.filter(g => g.horizon === horizonFilter.value)
  }
  if (statusFilter.value !== 'all') {
    list = list.filter(g => g.status === statusFilter.value)
  }
  return list
})

const groupedByHorizon = computed(() => {
  const groups: Record<string, Goal[]> = { short: [], mid: [], long: [] }
  for (const g of filteredGoals.value) {
    const bucket = groups[g.horizon]
    if (bucket) bucket.push(g)
  }
  return groups
})

// ── Helpers ───────────────────────────────────────

function priorityStars(n: number): string {
  return '★'.repeat(Math.min(n, 5)) + '☆'.repeat(Math.max(0, 5 - n))
}

function horizonLabel(h: string): string {
  switch (h) {
    case 'short': return 'Short-term'
    case 'mid': return 'Mid-term'
    case 'long': return 'Long-term'
    default: return h
  }
}

function horizonColor(h: string): string {
  switch (h) {
    case 'short': return '#4ade80'
    case 'mid': return '#f59e0b'
    case 'long': return '#818cf8'
    default: return '#888'
  }
}

// ── Sub-components ────────────────────────────────

function GoalRow({ goal }: { goal: Goal }) {
  return html`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${horizonColor(goal.horizon)}">
            ${horizonLabel(goal.horizon)}
          </span>
          <span class="goal-title">${goal.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${goal.priority}">${priorityStars(goal.priority)}</span>
          ${goal.metric ? html`<span class="goal-metric">${goal.metric}${goal.target_value ? ` → ${goal.target_value}` : ''}</span>` : null}
          ${goal.due_date ? html`<span class="goal-due">Due: <${TimeAgo} timestamp=${goal.due_date} /></span>` : null}
        </div>
        ${goal.last_review_note ? html`
          <div class="goal-review-note">${goal.last_review_note}</div>
        ` : null}
      </div>
      <div class="goal-row-right">
        <${StatusBadge} status=${goal.status} />
        <div class="goal-updated">
          <${TimeAgo} timestamp=${goal.updated_at} />
        </div>
      </div>
    </div>
  `
}

function HorizonGroup({ horizon, items }: { horizon: string; items: Goal[] }) {
  if (items.length === 0) return null

  const sorted = [...items].sort((a, b) => b.priority - a.priority)

  return html`
    <${Card} title="${horizonLabel(horizon)} Goals (${items.length})" class="section">
      <div class="goal-list">
        ${sorted.map(g => html`<${GoalRow} key=${g.id} goal=${g} />`)}
      </div>
    <//>
  `
}

function FilterBar() {
  return html`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${(['all', 'short', 'mid', 'long'] as HorizonFilter[]).map(h => html`
          <button
            class="goal-filter-btn ${horizonFilter.value === h ? 'active' : ''}"
            onClick=${() => { horizonFilter.value = h }}
          >
            ${h === 'all' ? 'All' : horizonLabel(h)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">Status</label>
        ${(['all', 'active', 'completed', 'paused'] as StatusFilter[]).map(s => html`
          <button
            class="goal-filter-btn ${statusFilter.value === s ? 'active' : ''}"
            onClick=${() => { statusFilter.value = s }}
          >
            ${s === 'all' ? 'All' : s.charAt(0).toUpperCase() + s.slice(1)}
          </button>
        `)}
      </div>
    </div>
  `
}

function GoalsSummary() {
  const all = goals.value
  const active = all.filter(g => g.status === 'active').length
  const completed = all.filter(g => g.status === 'completed').length
  const byHorizon = { short: 0, mid: 0, long: 0 }
  for (const g of all) {
    if (g.horizon in byHorizon) byHorizon[g.horizon as keyof typeof byHorizon]++
  }

  return html`
    <div class="goal-summary">
      <div class="goal-summary-item">
        <div class="goal-summary-value">${all.length}</div>
        <div class="goal-summary-label">Total</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:#4ade80">${active}</div>
        <div class="goal-summary-label">Active</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:#888">${completed}</div>
        <div class="goal-summary-label">Completed</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${horizonColor('short')}">${byHorizon.short}</div>
        <div class="goal-summary-label">Short</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${horizonColor('mid')}">${byHorizon.mid}</div>
        <div class="goal-summary-label">Mid</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${horizonColor('long')}">${byHorizon.long}</div>
        <div class="goal-summary-label">Long</div>
      </div>
    </div>
  `
}

// ── Main export ───────────────────────────────────

export function Goals() {
  useEffect(() => {
    refreshGoals()
  }, [])

  const grouped = groupedByHorizon.value

  return html`
    <div>
      <${Card} title="Goals Overview" class="section">
        <${GoalsSummary} />
        <${FilterBar} />
        <div style="margin-top:8px;">
          <button class="control-btn ghost" onClick=${refreshGoals} disabled=${goalsLoading.value}>
            ${goalsLoading.value ? 'Refreshing...' : 'Refresh'}
          </button>
        </div>
      <//>

      ${goalsLoading.value && goals.value.length === 0
        ? html`<div class="loading-indicator">Loading goals...</div>`
        : filteredGoals.value.length === 0
          ? html`<div class="empty-state">No goals match the current filters</div>`
          : html`
            <${HorizonGroup} horizon="short" items=${grouped.short ?? []} />
            <${HorizonGroup} horizon="mid" items=${grouped.mid ?? []} />
            <${HorizonGroup} horizon="long" items=${grouped.long ?? []} />
          `}
    </div>
  `
}
