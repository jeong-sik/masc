// Keeper detail sub-components — KPIs, charts, field dictionary,
// TRPG stats, equipment, relationships, autonomy, traits
// Extracted from keeper-detail.ts for maintainability.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { TimeAgo } from './common/time-ago'
import type { Keeper, KeeperMetricPoint, TrpgCharacterStats, AutonomyLevel } from '../types'

// ── Autonomy helpers ─────────────────────────────────────

const AUTONOMY_LEVELS: { level: AutonomyLevel; label: string; color: string }[] = [
  { level: 'L1_Reactive', label: 'L1 Reactive', color: '#6b7280' },
  { level: 'L2_Suggestive', label: 'L2 Suggestive', color: '#3b82f6' },
  { level: 'L3_Guided', label: 'L3 Guided', color: '#f59e0b' },
  { level: 'L4_Autonomous', label: 'L4 Autonomous', color: '#f97316' },
  { level: 'L5_Independent', label: 'L5 Independent', color: '#ef4444' },
]

function autonomyIndex(level: AutonomyLevel | undefined): number {
  if (!level) return 0
  const idx = AUTONOMY_LEVELS.findIndex(a => a.level === level)
  return idx >= 0 ? idx : 0
}

export function AutonomyMeter({ keeper }: { keeper: Keeper }) {
  const idx = autonomyIndex(keeper.autonomy_level)
  const info = AUTONOMY_LEVELS[idx] ?? AUTONOMY_LEVELS[0]
  if (!info) return null
  const pct = ((idx + 1) / AUTONOMY_LEVELS.length) * 100

  return html`
    <div class="keeper-signal-list">
      <div style="margin-bottom:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
          <span style="font-size:13px; font-weight:600; color:${info.color};">${info.label}</span>
          <span style="font-size:11px; color:#888;">${idx + 1} / ${AUTONOMY_LEVELS.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${pct}%; height:100%; background:${info.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div style="display:flex; justify-content:space-between; margin-top:2px;">
          ${AUTONOMY_LEVELS.map((a, i) => html`
            <span style="width:8px; height:8px; border-radius:50%; background:${i <= idx ? a.color : '#333'}; display:inline-block;"></span>
          `)}
        </div>
      </div>
      <div class="keeper-signal-row">
        <span>Autonomous actions</span>
        <strong>${keeper.autonomous_action_count ?? 0}</strong>
      </div>
      ${keeper.last_autonomous_action_at
        ? html`<div class="keeper-signal-row">
            <span>Last autonomous action</span>
            <strong><${TimeAgo} timestamp=${keeper.last_autonomous_action_at} /></strong>
          </div>`
        : null}
      ${keeper.active_goal_ids && keeper.active_goal_ids.length > 0
        ? html`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${keeper.active_goal_ids.length}</strong>
          </div>`
        : null}
    </div>
  `
}

// ── Utility functions ────────────────────────────────────

export function formatTokens(n: number | undefined): string {
  if (!n) return '—'
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}K`
  return String(n)
}


// ── KPI & Chart components ───────────────────────────────

export function KpiGrid({ keeper }: { keeper: Keeper }) {
  const series = keeper.metrics_series ?? []
  const lastPt = series[series.length - 1] as KeeperMetricPoint | undefined
  const latestCost =
    lastPt && Number.isFinite(lastPt.cost_usd)
      ? `$${lastPt.cost_usd.toFixed(4)}`
      : null

  const items: { label: string; value: string | number; hint?: string }[] = [
    {
      label: '세대',
      value: keeper.generation ?? '-',
      hint: '승계 횟수',
    },
    {
      label: '턴',
      value: keeper.turn_count ?? '-',
      hint: '총 루프 턴',
    },
    {
      label: '컨텍스트',
      value: keeper.context_ratio != null ? `${Math.round(keeper.context_ratio * 100)}%` : '-',
      hint: keeper.context_ratio != null && keeper.context_ratio > 0.8 ? '한계 근접' : undefined,
    },
    {
      label: '활동도',
      value: keeper.activityLevel ?? '-',
      hint: '0–5 단계',
    },
  ]

  return html`
    <div class="keeper-kpis">
      ${items.map(i => html`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${i.label}</div>
          <div class="keeper-kpi-value">${i.value}</div>
          ${i.hint ? html`<div class="keeper-kpi-hint">${i.hint}</div>` : null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${formatTokens(keeper.context_tokens)}</div>
        <div class="kpi-label">Tokens</div>
      </div>
      <div class="kpi-tile">
        <div class="kpi-value">${keeper.handoff_count_total ?? '—'}</div>
        <div class="kpi-label">Handoffs</div>
      </div>
      <div class="kpi-tile">
        <div class="kpi-value">${keeper.compaction_count ?? '—'}</div>
        <div class="kpi-label">Compactions</div>
      </div>
      ${latestCost
        ? html`
            <div class="kpi-tile">
              <div class="kpi-value">${latestCost}</div>
              <div class="kpi-label">Cost (USD)</div>
            </div>
          `
        : null}
    </div>
  `
}

export function ContextChart({ keeper }: { keeper: Keeper }) {
  const series = keeper.metrics_series ?? []
  if (series.length < 2) {
    const pct = ((keeper.context?.context_ratio ?? 0) * 100)
    const color = pct > 85 ? '#ef4444' : pct > 70 ? '#f59e0b' : '#22c55e'
    return html`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${pct.toFixed(1)}%;background:${color}"></div>
        </div>
        <span class="chart-pct">${pct.toFixed(1)}%</span>
      </div>`
  }

  const W = 200, H = 60, pad = 2
  const n = series.length
  const pts = series.map((p: KeeperMetricPoint, i: number) => {
    const x = pad + (i / (n - 1)) * (W - 2 * pad)
    const y = H - pad - (p.context_ratio ?? 0) * (H - 2 * pad)
    return { x, y, p }
  })
  const polyline = pts.map(({ x, y }) => `${x.toFixed(1)},${y.toFixed(1)}`).join(' ')
  const lastRatio = ((series[series.length - 1] as KeeperMetricPoint)?.context_ratio ?? 0) * 100
  const lineColor = lastRatio > 85 ? '#ef4444' : lastRatio > 70 ? '#f59e0b' : '#22c55e'

  return html`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${pad}" y1="${(H - pad - 0.5 * (H - 2 * pad)).toFixed(1)}" x2="${W - pad}" y2="${(H - pad - 0.5 * (H - 2 * pad)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${pad}" y1="${(H - pad - 0.7 * (H - 2 * pad)).toFixed(1)}" x2="${W - pad}" y2="${(H - pad - 0.7 * (H - 2 * pad)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${pad}" y1="${(H - pad - 0.85 * (H - 2 * pad)).toFixed(1)}" x2="${W - pad}" y2="${(H - pad - 0.85 * (H - 2 * pad)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${pts.filter(({ p }) => p.is_handoff).map(({ x }) => html`
          <line x1="${x.toFixed(1)}" y1="${pad}" x2="${x.toFixed(1)}" y2="${H - pad}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${polyline}" fill="none" stroke="${lineColor}" stroke-width="1.5"/>
        ${pts.filter(({ p }) => p.is_compaction).map(({ x, y }) => html`
          <circle cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${lastRatio.toFixed(1)}%</span>
    </div>`
}

// ── Field Dictionary ─────────────────────────────────────

const fieldSearch = signal('')

export function FieldDictionary({ keeper }: { keeper: Keeper }) {
  const filter = fieldSearch.value.toLowerCase()

  const fields: { title: string; key: string; value: string }[] = [
    { title: 'Name', key: 'name', value: keeper.name },
    { title: 'Emoji', key: 'emoji', value: keeper.emoji ?? '-' },
    { title: 'Korean', key: 'koreanName', value: keeper.koreanName ?? '-' },
    { title: 'Model', key: 'model', value: keeper.model ?? '-' },
    { title: 'Status', key: 'status', value: keeper.status },
    { title: 'Primary', key: 'primaryValue', value: keeper.primaryValue ?? '-' },
    { title: 'Activity', key: 'activityLevel', value: String(keeper.activityLevel ?? '-') },
    { title: 'Gen', key: 'generation', value: String(keeper.generation ?? '-') },
    { title: 'Turns', key: 'turn_count', value: String(keeper.turn_count ?? '-') },
    { title: 'Context', key: 'context_ratio', value: keeper.context_ratio != null ? `${Math.round(keeper.context_ratio * 100)}%` : '-' },
    { title: 'Heartbeat', key: 'last_heartbeat', value: keeper.last_heartbeat ?? '-' },
    { title: 'Traits', key: 'traits', value: keeper.traits?.join(', ') || '-' },
    { title: 'Interests', key: 'interests', value: keeper.interests?.join(', ') || '-' },
  ]

  const filtered = filter
    ? fields.filter(f => f.title.toLowerCase().includes(filter) || f.key.includes(filter) || f.value.toLowerCase().includes(filter))
    : fields

  return html`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${fieldSearch.value}
        onInput=${(e: Event) => { fieldSearch.value = (e.target as HTMLInputElement).value }}
      />
      ${filtered.map(f => html`
        <div class="keeper-field-row">
          <span class="keeper-field-title">${f.title}</span>
          <span class="keeper-field-key">${f.key}</span>
          <span style="flex:1; text-align:right; color:#ccc;">${f.value}</span>
        </div>
      `)}
      ${keeper.trace_id ? html`<div class="keeper-field-row"><span class="keeper-field-title">Trace ID</span><span class="keeper-field-key mono">${keeper.trace_id}</span></div>` : ''}
      ${keeper.agent_name ? html`<div class="keeper-field-row"><span class="keeper-field-title">Agent</span><span style="flex:1; text-align:right; color:#ccc;">${keeper.agent_name}</span></div>` : ''}
      ${keeper.primary_model ? html`<div class="keeper-field-row"><span class="keeper-field-title">Primary Model</span><span class="mono" style="flex:1; text-align:right; color:#ccc;">${keeper.primary_model}</span></div>` : ''}
      ${keeper.active_model ? html`<div class="keeper-field-row"><span class="keeper-field-title">Active Model</span><span class="mono" style="flex:1; text-align:right; color:#ccc;">${keeper.active_model}</span></div>` : ''}
      ${keeper.next_model_hint ? html`<div class="keeper-field-row"><span class="keeper-field-title">Next Model Hint</span><span class="mono" style="flex:1; text-align:right; color:#ccc;">${keeper.next_model_hint}</span></div>` : ''}
      ${keeper.skill_primary ? html`<div class="keeper-field-row"><span class="keeper-field-title">Skill (Primary)</span><span style="flex:1; text-align:right; color:#ccc;">${keeper.skill_primary}</span></div>` : ''}
      ${keeper.skill_secondary ? html`<div class="keeper-field-row"><span class="keeper-field-title">Skill (Secondary)</span><span style="flex:1; text-align:right; color:#ccc;">${keeper.skill_secondary}</span></div>` : ''}
      ${keeper.skill_reason ? html`<div class="keeper-field-row"><span class="keeper-field-title">Skill Reason</span><span style="flex:1; text-align:right; color:#ccc;">${keeper.skill_reason}</span></div>` : ''}
      ${keeper.context_source ? html`<div class="keeper-field-row"><span class="keeper-field-title">Context Source</span><span style="flex:1; text-align:right; color:#ccc;">${keeper.context_source}</span></div>` : ''}
      ${keeper.context_tokens != null ? html`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${formatTokens(keeper.context_tokens)}</span></div>` : ''}
      ${keeper.context_max != null ? html`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${formatTokens(keeper.context_max)}</span></div>` : ''}
      ${keeper.memory_recent_note ? html`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${keeper.memory_recent_note}</span></div>` : ''}
      ${keeper.k2k_count != null ? html`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${keeper.k2k_count}</span></div>` : ''}
      ${keeper.conversation_tail_count != null ? html`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${keeper.conversation_tail_count}</span></div>` : ''}
      ${keeper.handoff_count_total != null ? html`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${keeper.handoff_count_total}</span></div>` : ''}
      ${keeper.compaction_count != null ? html`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${keeper.compaction_count}</span></div>` : ''}
      ${keeper.last_compaction_saved_tokens != null ? html`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${formatTokens(keeper.last_compaction_saved_tokens)}</span></div>` : ''}
      ${keeper.context?.message_count != null ? html`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${keeper.context.message_count}</span></div>` : ''}
      ${keeper.context?.has_checkpoint != null ? html`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${keeper.context.has_checkpoint ? 'Yes' : 'No'}</span></div>` : ''}
    </div>
  `
}

// ── TRPG, Equipment, Relationships, Traits ───────────────

export function TrpgStats({ stats }: { stats: TrpgCharacterStats }) {
  const hpPct = stats.max_hp > 0 ? Math.round((stats.hp / stats.max_hp) * 100) : 0
  const mpPct = stats.max_mp > 0 ? Math.round((stats.mp / stats.max_mp) * 100) : 0

  return html`
    <div>
      <div style="display: flex; gap: 12px; margin-bottom: 10px;">
        <div style="flex:1;">
          <div style="font-size:11px; color:#888;">HP ${stats.hp}/${stats.max_hp}</div>
          <div style="height:6px; background:rgba(255,255,255,0.06); border-radius:3px; overflow:hidden;">
            <div style="width:${hpPct}%; height:100%; background:${hpPct > 50 ? '#4ade80' : hpPct > 25 ? '#fbbf24' : '#ef4444'}; border-radius:3px;" />
          </div>
        </div>
        <div style="flex:1;">
          <div style="font-size:11px; color:#888;">MP ${stats.mp}/${stats.max_mp}</div>
          <div style="height:6px; background:rgba(255,255,255,0.06); border-radius:3px; overflow:hidden;">
            <div style="width:${mpPct}%; height:100%; background:#818cf8; border-radius:3px;" />
          </div>
        </div>
      </div>
      <div style="display:grid; grid-template-columns: repeat(3,1fr); gap:6px;">
        ${[
          { label: 'STR', value: stats.strength },
          { label: 'DEX', value: stats.dexterity },
          { label: 'CON', value: stats.constitution },
          { label: 'INT', value: stats.intelligence },
          { label: 'WIS', value: stats.wisdom },
          { label: 'CHA', value: stats.charisma },
        ].map(s => html`
          <div style="text-align:center; padding:6px; background:rgba(255,255,255,0.03); border-radius:6px;">
            <div style="font-size:10px; color:#888; text-transform:uppercase;">${s.label}</div>
            <div style="font-size:16px; font-weight:bold; color:#e0e0e0;">${s.value}</div>
          </div>
        `)}
      </div>
      <div style="margin-top:8px; font-size:12px; color:#888;">
        레벨 ${stats.level} · 경험치 ${stats.xp}
      </div>
    </div>
  `
}

export function EquipmentList({ items }: { items: string[] }) {
  if (items.length === 0) return html`<div class="empty-state" style="font-size:13px">장비 없음</div>`

  return html`
    <div class="keeper-equipment-list">
      ${items.map((item, i) => html`
        <div class="keeper-equipment-row">
          <span>${item}</span>
          <span class="keeper-gen-label">#${i + 1}</span>
        </div>
      `)}
    </div>
  `
}

export function RelationshipList({ rels }: { rels: Record<string, string> }) {
  const entries = Object.entries(rels)
  if (entries.length === 0) return html`<div class="empty-state" style="font-size:13px">관계 없음</div>`

  return html`
    <div class="keeper-k2k-list">
      ${entries.map(([name, relation]) => html`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${name}</span>
          <span class="keeper-k2k-route">${relation}</span>
        </div>
      `)}
    </div>
  `
}

export function TraitsList({ traits, label }: { traits: string[]; label: string }) {
  if (traits.length === 0) return null

  return html`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${label}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${traits.map(t => html`<span class="keeper-mention-chip">${t}</span>`)}
      </div>
    </div>
  `
}
