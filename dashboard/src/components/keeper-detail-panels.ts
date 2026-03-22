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
    <div class="flex flex-col gap-1.5">
      <div class="mb-2">
        <div class="flex justify-between items-center mb-1">
          <span style="font-size:13px; font-weight:600; color:${info.color};">${info.label}</span>
          <span class="text-[11px] text-[var(--text-dim)]">${idx + 1} / ${AUTONOMY_LEVELS.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${pct}%; height:100%; background:${info.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div class="flex justify-between mt-0.5">
          ${AUTONOMY_LEVELS.map((a, i) => html`
            <span style="width:8px; height:8px; border-radius:50%; background:${i <= idx ? a.color : '#333'}; display:inline-block;"></span>
          `)}
        </div>
      </div>
      <div class="keeper-signal-row rounded-lg">
        <span>Autonomous actions</span>
        <strong>${keeper.autonomous_action_count ?? 0}</strong>
      </div>
      ${keeper.last_autonomous_action_at
        ? html`<div class="keeper-signal-row rounded-lg">
            <span>Last autonomous action</span>
            <strong><${TimeAgo} timestamp=${keeper.last_autonomous_action_at} /></strong>
          </div>`
        : null}
      ${keeper.active_goal_ids && keeper.active_goal_ids.length > 0
        ? html`<div class="keeper-signal-row rounded-lg">
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
    <div class="grid grid-cols-4 gap-2.5 mb-4">
      ${items.map(i => html`
        <div class="keeper-kpi rounded-lg">
          <div class="keeper-kpi rounded-lg-label">${i.label}</div>
          <div class="keeper-kpi rounded-lg-value">${i.value}</div>
          ${i.hint ? html`<div class="keeper-kpi rounded-lg-hint">${i.hint}</div>` : null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="text-[color:var(--text-strong)] text-[17px] leading-[1.1] font-semibold tabular-nums">${formatTokens(keeper.context_tokens)}</div>
        <div class="kpi-label">Tokens</div>
      </div>
      <div class="kpi-tile">
        <div class="text-[color:var(--text-strong)] text-[17px] leading-[1.1] font-semibold tabular-nums">${keeper.handoff_count_total ?? '—'}</div>
        <div class="kpi-label">Handoffs</div>
      </div>
      <div class="kpi-tile">
        <div class="text-[color:var(--text-strong)] text-[17px] leading-[1.1] font-semibold tabular-nums">${keeper.compaction_count ?? '—'}</div>
        <div class="kpi-label">Compactions</div>
      </div>
      ${latestCost
        ? html`
            <div class="kpi-tile">
              <div class="text-[color:var(--text-strong)] text-[17px] leading-[1.1] font-semibold tabular-nums">${latestCost}</div>
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
    <div class="context-chart" class="flex items-center gap-2">
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
    <div class="max-h-[460px] overflow-y-auto">
      <input
        class="keeper-field-search rounded-lg"
        type="text"
        placeholder="필드 검색..."
        value=${fieldSearch.value}
        onInput=${(e: Event) => { fieldSearch.value = (e.target as HTMLInputElement).value }}
      />
      ${filtered.map(f => html`
        <div class="flex gap-2.5 py-1.5 border-b border-[var(--white-4)] text-[var(--fs-base)]">
          <span class="font-semibold min-w-[90px]">${f.title}</span>
          <span class="font-mono text-cyan text-[var(--fs-sm)]">${f.key}</span>
          <span class="flex-1 text-right text-[#ccc]">${f.value}</span>
        </div>
      `)}
      ${keeper.trace_id ? html`<div class="flex gap-2.5 py-1.5 border-b border-[var(--white-4)] text-[var(--fs-base)]"><span class="font-semibold min-w-[90px]">Trace ID</span><span class="keeper-field-key font-mono">${keeper.trace_id}</span></div>` : ''}
      ${keeper.agent_name ? html`<div class="flex gap-2.5 py-1.5 border-b border-[var(--white-4)] text-[var(--fs-base)]"><span class="font-semibold min-w-[90px]">Agent</span><span class="flex-1 text-right text-[#ccc]">${keeper.agent_name}</span></div>` : ''}
      ${keeper.primary_model ? html`<div class="flex gap-2.5 py-1.5 border-b border-[var(--white-4)] text-[var(--fs-base)]"><span class="font-semibold min-w-[90px]">Primary Model</span><span class="font-mono" class="flex-1 text-right text-[#ccc]">${keeper.primary_model}</span></div>` : ''}
      ${keeper.active_model ? html`<div class="flex gap-2.5 py-1.5 border-b border-[var(--white-4)] text-[var(--fs-base)]"><span class="font-semibold min-w-[90px]">Active Model</span><span class="font-mono" class="flex-1 text-right text-[#ccc]">${keeper.active_model}</span></div>` : ''}
      ${keeper.next_model_hint ? html`<div class="flex gap-2.5 py-1.5 border-b border-[var(--white-4)] text-[var(--fs-base)]"><span class="font-semibold min-w-[90px]">Next Model Hint</span><span class="font-mono" class="flex-1 text-right text-[#ccc]">${keeper.next_model_hint}</span></div>` : ''}
      ${keeper.skill_primary ? html`<div class="flex gap-2.5 py-1.5 border-b border-[var(--white-4)] text-[var(--fs-base)]"><span class="font-semibold min-w-[90px]">Skill (Primary)</span><span class="flex-1 text-right text-[#ccc]">${keeper.skill_primary}</span></div>` : ''}
      ${keeper.skill_secondary ? html`<div class="flex gap-2.5 py-1.5 border-b border-[var(--white-4)] text-[var(--fs-base)]"><span class="font-semibold min-w-[90px]">Skill (Secondary)</span><span class="flex-1 text-right text-[#ccc]">${keeper.skill_secondary}</span></div>` : ''}
      ${keeper.skill_reason ? html`<div class="flex gap-2.5 py-1.5 border-b border-[var(--white-4)] text-[var(--fs-base)]"><span class="font-semibold min-w-[90px]">Skill Reason</span><span class="flex-1 text-right text-[#ccc]">${keeper.skill_reason}</span></div>` : ''}
      ${keeper.context_source ? html`<div class="flex gap-2.5 py-1.5 border-b border-[var(--white-4)] text-[var(--fs-base)]"><span class="font-semibold min-w-[90px]">Context Source</span><span class="flex-1 text-right text-[#ccc]">${keeper.context_source}</span></div>` : ''}
      ${keeper.context_tokens != null ? html`<div class="flex gap-2.5 py-1.5 border-b border-[var(--white-4)] text-[var(--fs-base)]"><span class="font-semibold min-w-[90px]">Context Tokens</span><span class="flex-1 text-right text-[#ccc]">${formatTokens(keeper.context_tokens)}</span></div>` : ''}
      ${keeper.context_max != null ? html`<div class="flex gap-2.5 py-1.5 border-b border-[var(--white-4)] text-[var(--fs-base)]"><span class="font-semibold min-w-[90px]">Context Max</span><span class="flex-1 text-right text-[#ccc]">${formatTokens(keeper.context_max)}</span></div>` : ''}
      ${keeper.memory_recent_note ? html`<div class="flex gap-2.5 py-1.5 border-b border-[var(--white-4)] text-[var(--fs-base)]"><span class="font-semibold min-w-[90px]">Memory Note</span><span class="flex-1 text-right text-[#ccc]">${keeper.memory_recent_note}</span></div>` : ''}
      ${keeper.k2k_count != null ? html`<div class="flex gap-2.5 py-1.5 border-b border-[var(--white-4)] text-[var(--fs-base)]"><span class="font-semibold min-w-[90px]">K2K Count</span><span class="flex-1 text-right text-[#ccc]">${keeper.k2k_count}</span></div>` : ''}
      ${keeper.conversation_tail_count != null ? html`<div class="flex gap-2.5 py-1.5 border-b border-[var(--white-4)] text-[var(--fs-base)]"><span class="font-semibold min-w-[90px]">Conv Tail</span><span class="flex-1 text-right text-[#ccc]">${keeper.conversation_tail_count}</span></div>` : ''}
      ${keeper.handoff_count_total != null ? html`<div class="flex gap-2.5 py-1.5 border-b border-[var(--white-4)] text-[var(--fs-base)]"><span class="font-semibold min-w-[90px]">Total Handoffs</span><span class="flex-1 text-right text-[#ccc]">${keeper.handoff_count_total}</span></div>` : ''}
      ${keeper.compaction_count != null ? html`<div class="flex gap-2.5 py-1.5 border-b border-[var(--white-4)] text-[var(--fs-base)]"><span class="font-semibold min-w-[90px]">Compactions</span><span class="flex-1 text-right text-[#ccc]">${keeper.compaction_count}</span></div>` : ''}
      ${keeper.last_compaction_saved_tokens != null ? html`<div class="flex gap-2.5 py-1.5 border-b border-[var(--white-4)] text-[var(--fs-base)]"><span class="font-semibold min-w-[90px]">Last Compact Saved</span><span class="flex-1 text-right text-[#ccc]">${formatTokens(keeper.last_compaction_saved_tokens)}</span></div>` : ''}
      ${keeper.context?.message_count != null ? html`<div class="flex gap-2.5 py-1.5 border-b border-[var(--white-4)] text-[var(--fs-base)]"><span class="font-semibold min-w-[90px]">Message Count</span><span class="flex-1 text-right text-[#ccc]">${keeper.context.message_count}</span></div>` : ''}
      ${keeper.context?.has_checkpoint != null ? html`<div class="flex gap-2.5 py-1.5 border-b border-[var(--white-4)] text-[var(--fs-base)]"><span class="font-semibold min-w-[90px]">Has Checkpoint</span><span class="flex-1 text-right text-[#ccc]">${keeper.context.has_checkpoint ? 'Yes' : 'No'}</span></div>` : ''}
    </div>
  `
}

// ── TRPG, Equipment, Relationships, Traits ───────────────

export function TrpgStats({ stats }: { stats: TrpgCharacterStats }) {
  const hpPct = stats.max_hp > 0 ? Math.round((stats.hp / stats.max_hp) * 100) : 0
  const mpPct = stats.max_mp > 0 ? Math.round((stats.mp / stats.max_mp) * 100) : 0

  return html`
    <div>
      <div class="flex gap-3 mb-2.5">
        <div class="flex-1">
          <div class="text-[11px] text-[var(--text-dim)]">HP ${stats.hp}/${stats.max_hp}</div>
          <div style="height:6px; background:rgba(255,255,255,0.06); border-radius:3px; overflow:hidden;">
            <div style="width:${hpPct}%; height:100%; background:${hpPct > 50 ? '#4ade80' : hpPct > 25 ? '#fbbf24' : '#ef4444'}; border-radius:3px;" />
          </div>
        </div>
        <div class="flex-1">
          <div class="text-[11px] text-[var(--text-dim)]">MP ${stats.mp}/${stats.max_mp}</div>
          <div style="height:6px; background:rgba(255,255,255,0.06); border-radius:3px; overflow:hidden;">
            <div style="width:${mpPct}%; height:100%; background:#818cf8; border-radius:3px;" />
          </div>
        </div>
      </div>
      <div class="grid grid-cols-3 gap-1.5">
        ${[
          { label: 'STR', value: stats.strength },
          { label: 'DEX', value: stats.dexterity },
          { label: 'CON', value: stats.constitution },
          { label: 'INT', value: stats.intelligence },
          { label: 'WIS', value: stats.wisdom },
          { label: 'CHA', value: stats.charisma },
        ].map(s => html`
          <div class="text-center p-1.5 bg-[var(--white-3)] rounded-md">
            <div class="text-[10px] text-[var(--text-dim)] uppercase">${s.label}</div>
            <div class="text-base font-bold text-[#e0e0e0]">${s.value}</div>
          </div>
        `)}
      </div>
      <div class="mt-2 text-xs text-[var(--text-dim)]">
        Level ${stats.level} — XP ${stats.xp}
      </div>
    </div>
  `
}

export function EquipmentList({ items }: { items: string[] }) {
  if (items.length === 0) return html`<div class="empty-state text-center border border-dashed border-[var(--card-border)] rounded-[10px] py-[22px] px-4 text-[color:var(--text-muted)]" class="text-[13px]">장비 없음</div>`

  return html`
    <div class="flex flex-col gap-1.5">
      ${items.map((item, i) => html`
        <div class="keeper-equipment-row rounded-md">
          <span>${item}</span>
          <span class="text-cyan text-[var(--fs-xs)]">#${i + 1}</span>
        </div>
      `)}
    </div>
  `
}

export function RelationshipList({ rels }: { rels: Record<string, string> }) {
  const entries = Object.entries(rels)
  if (entries.length === 0) return html`<div class="empty-state text-center border border-dashed border-[var(--card-border)] rounded-[10px] py-[22px] px-4 text-[color:var(--text-muted)]" class="text-[13px]">관계 없음</div>`

  return html`
    <div class="max-h-[220px] overflow-y-auto flex flex-col gap-1.5">
      ${entries.map(([name, relation]) => html`
        <div class="flex items-center gap-2 py-1.5 px-2.5 bg-[var(--white-3)] rounded-md">
          <span class="keeper-mention-chip rounded-full">${name}</span>
          <span class="font-mono text-[var(--fs-xs)] text-[var(--text-dim)]">${relation}</span>
        </div>
      `)}
    </div>
  `
}

export function TraitsList({ traits, label }: { traits: string[]; label: string }) {
  if (traits.length === 0) return null

  return html`
    <div class="mb-3">
      <div class="text-[11px] text-[var(--text-dim)] uppercase tracking-wider mb-1.5">${label}</div>
      <div class="flex flex-wrap gap-1.5">
        ${traits.map(t => html`<span class="keeper-mention-chip rounded-full">${t}</span>`)}
      </div>
    </div>
  `
}

