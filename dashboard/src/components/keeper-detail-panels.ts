// Keeper detail sub-components — KPIs, charts, field dictionary,
// TRPG stats, equipment, relationships, autonomy, traits
// Redesigned: individual KPI cards, clean table, proper spacing.

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
    <div class="flex flex-col gap-2">
      <div>
        <div class="flex justify-between items-center mb-1.5">
          <span class="text-[13px] font-semibold" style="color:${info.color};">${info.label}</span>
          <span class="text-[11px] text-[var(--text-muted)]">${idx + 1} / ${AUTONOMY_LEVELS.length}</span>
        </div>
        <div class="w-full h-1.5 bg-[var(--white-6)] rounded-full overflow-hidden">
          <div class="h-full rounded-full transition-all duration-300" style="width:${pct}%; background:${info.color};"></div>
        </div>
        <div class="flex justify-between mt-1.5">
          ${AUTONOMY_LEVELS.map((a, i) => html`
            <span class="size-2 rounded-full inline-block transition-colors" style="background:${i <= idx ? a.color : 'var(--white-10)'};"></span>
          `)}
        </div>
      </div>
      <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]">
        <span class="text-xs text-[var(--text-muted)]">Autonomous actions</span>
        <span class="text-xs font-medium text-[var(--text-strong)]">${keeper.autonomous_action_count ?? 0}</span>
      </div>
      ${keeper.last_autonomous_action_at
        ? html`<div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]">
            <span class="text-xs text-[var(--text-muted)]">Last autonomous action</span>
            <span class="text-xs font-medium text-[var(--text-strong)]"><${TimeAgo} timestamp=${keeper.last_autonomous_action_at} /></span>
          </div>`
        : null}
      ${keeper.active_goal_ids && keeper.active_goal_ids.length > 0
        ? html`<div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]">
            <span class="text-xs text-[var(--text-muted)]">Active goals</span>
            <span class="text-xs font-medium text-[var(--text-strong)]">${keeper.active_goal_ids.length}</span>
          </div>`
        : null}
    </div>
  `
}

// ── Utility functions ────────────────────────────────────

export function formatTokens(n: number | undefined): string {
  if (!n) return '-'
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}K`
  return String(n)
}


// ── KPI Card ─────────────────────────────────────────────

type KpiTone = 'default' | 'ok' | 'warn' | 'bad'

const KPI_TONE: Record<KpiTone, string> = {
  default: 'border-[var(--card-border)] bg-[var(--white-3)]',
  ok: 'border-[rgba(74,222,128,0.2)] bg-[rgba(74,222,128,0.06)]',
  warn: 'border-[rgba(251,191,36,0.2)] bg-[rgba(251,191,36,0.06)]',
  bad: 'border-[rgba(239,68,68,0.2)] bg-[rgba(239,68,68,0.06)]',
}

const KPI_VALUE_TONE: Record<KpiTone, string> = {
  default: 'text-[var(--text-strong)]',
  ok: 'text-[#4ade80]',
  warn: 'text-[#fbbf24]',
  bad: 'text-[#ef4444]',
}

const KPI_ICON: Record<string, string> = {
  Generation: '🔄',
  Turns: '↻',
  Context: '📊',
  Activity: '⚡',
  Tokens: '🔤',
  Handoffs: '🤝',
  Compactions: '📦',
  'Cost (USD)': '💰',
}

function KpiCard({ label, value, hint, tone = 'default', progress }: {
  label: string
  value: string | number
  hint?: string
  tone?: KpiTone
  /** 0-100 progress bar */
  progress?: number
}) {
  const icon = KPI_ICON[label] ?? ''
  return html`
    <div class="p-3.5 rounded-xl border ${KPI_TONE[tone]} flex flex-col gap-1.5 transition-colors">
      <div class="flex items-center justify-between">
        <span class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)]">${label}</span>
        ${icon ? html`<span class="text-[11px] opacity-60">${icon}</span>` : null}
      </div>
      <div class="text-2xl font-bold ${KPI_VALUE_TONE[tone]} tabular-nums leading-none">${value}</div>
      ${progress != null ? html`
        <div class="w-full h-1 bg-[var(--white-6)] rounded-full overflow-hidden mt-0.5">
          <div class="h-full rounded-full transition-all duration-500" style="width:${Math.min(progress, 100)}%;background:${progress > 85 ? '#ef4444' : progress > 70 ? '#fbbf24' : '#4ade80'}"></div>
        </div>
      ` : null}
      ${hint ? html`<div class="text-[10px] text-[var(--text-dim)] leading-snug">${hint}</div>` : null}
    </div>
  `
}

// ── KPI Grid ─────────────────────────────────────────────

export function KpiGrid({ keeper }: { keeper: Keeper }) {
  const series = keeper.metrics_series ?? []
  const lastPt = series[series.length - 1] as KeeperMetricPoint | undefined
  const latestCost =
    lastPt && Number.isFinite(lastPt.cost_usd)
      ? `$${lastPt.cost_usd.toFixed(4)}`
      : null

  const ctxPct = keeper.context_ratio != null ? Math.round(keeper.context_ratio * 100) : null
  const ctxTone: KpiTone = ctxPct == null ? 'default' : ctxPct > 85 ? 'bad' : ctxPct > 70 ? 'warn' : ctxPct > 0 ? 'ok' : 'default'
  const ctxHint = ctxPct != null && ctxPct > 80 ? 'Approaching limit' : undefined

  const actLevel = typeof keeper.activityLevel === 'number' ? keeper.activityLevel : null
  const actTone: KpiTone = actLevel == null ? 'default' : actLevel >= 4 ? 'ok' : actLevel >= 2 ? 'warn' : 'default'

  return html`
    <div class="flex flex-col gap-3 mb-5">
      ${'' /* Primary KPIs — 4 cols */}
      <div class="grid grid-cols-2 sm:grid-cols-4 gap-3">
        <${KpiCard}
          label="Generation"
          value=${keeper.generation ?? '-'}
          hint="Succession count"
        />
        <${KpiCard}
          label="Turns"
          value=${keeper.turn_count ?? '-'}
          hint="Total loop turns"
        />
        <${KpiCard}
          label="Context"
          value=${ctxPct != null ? `${ctxPct}%` : '-'}
          hint=${ctxHint}
          tone=${ctxTone}
          progress=${ctxPct ?? undefined}
        />
        <${KpiCard}
          label="Activity"
          value=${keeper.activityLevel ?? '-'}
          hint="Level 0-5"
          tone=${actTone}
        />
      </div>
      ${'' /* Secondary KPIs — 3-4 cols, smaller feel */}
      <div class="grid grid-cols-3 sm:grid-cols-4 gap-2">
        <${KpiCard}
          label="Tokens"
          value=${formatTokens(keeper.context_tokens)}
        />
        <${KpiCard}
          label="Handoffs"
          value=${keeper.handoff_count_total ?? '-'}
        />
        <${KpiCard}
          label="Compactions"
          value=${keeper.compaction_count ?? '-'}
        />
        ${latestCost
          ? html`<${KpiCard} label="Cost (USD)" value=${latestCost} />`
          : null}
      </div>
    </div>
  `
}

// ── Context Chart ────────────────────────────────────────

export function ContextChart({ keeper }: { keeper: Keeper }) {
  const series = keeper.metrics_series ?? []
  if (series.length < 2) {
    const pct = ((keeper.context?.context_ratio ?? 0) * 100)
    const color = pct > 85 ? '#ef4444' : pct > 70 ? '#f59e0b' : '#22c55e'
    return html`
      <div class="flex items-center gap-3 mb-5 p-3 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)]">
        <div class="flex-1 h-2 bg-[var(--white-6)] rounded-full overflow-hidden">
          <div class="h-full rounded-full transition-all duration-300" style="width:${pct.toFixed(1)}%;background:${color}"></div>
        </div>
        <span class="text-sm font-semibold tabular-nums text-[var(--text-strong)]">${pct.toFixed(1)}%</span>
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
    <div class="flex items-center gap-3 mb-5 p-3 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)]">
      <svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" class="rounded" style="background:#0b1220;">
        <line x1="${pad}" y1="${(H - pad - 0.5 * (H - 2 * pad)).toFixed(1)}" x2="${W - pad}" y2="${(H - pad - 0.5 * (H - 2 * pad)).toFixed(1)}" stroke="#444" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${pad}" y1="${(H - pad - 0.7 * (H - 2 * pad)).toFixed(1)}" x2="${W - pad}" y2="${(H - pad - 0.7 * (H - 2 * pad)).toFixed(1)}" stroke="#444" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${pad}" y1="${(H - pad - 0.85 * (H - 2 * pad)).toFixed(1)}" x2="${W - pad}" y2="${(H - pad - 0.85 * (H - 2 * pad)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${pts.filter(({ p }) => p.is_handoff).map(({ x }) => html`
          <line x1="${x.toFixed(1)}" y1="${pad}" x2="${x.toFixed(1)}" y2="${H - pad}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${polyline}" fill="none" stroke="${lineColor}" stroke-width="1.5"/>
        ${pts.filter(({ p }) => p.is_compaction).map(({ x, y }) => html`
          <circle cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="text-sm font-semibold tabular-nums text-[var(--text-strong)]">${lastRatio.toFixed(1)}%</span>
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

  // Extra fields from keeper object
  const extras: { title: string; value: string; mono?: boolean }[] = []
  if (keeper.trace_id) extras.push({ title: 'Trace ID', value: keeper.trace_id, mono: true })
  if (keeper.agent_name) extras.push({ title: 'Agent', value: keeper.agent_name })
  if (keeper.primary_model) extras.push({ title: 'Primary Model', value: keeper.primary_model, mono: true })
  if (keeper.active_model) extras.push({ title: 'Active Model', value: keeper.active_model, mono: true })
  if (keeper.next_model_hint) extras.push({ title: 'Next Model Hint', value: keeper.next_model_hint, mono: true })
  if (keeper.skill_primary) extras.push({ title: 'Skill (Primary)', value: keeper.skill_primary })
  if (keeper.skill_secondary?.length) extras.push({ title: 'Skill (Secondary)', value: keeper.skill_secondary.join(', ') })
  if (keeper.skill_reason) extras.push({ title: 'Skill Reason', value: keeper.skill_reason })
  if (keeper.context_source) extras.push({ title: 'Context Source', value: keeper.context_source })
  if (keeper.context_tokens != null) extras.push({ title: 'Context Tokens', value: formatTokens(keeper.context_tokens) })
  if (keeper.context_max != null) extras.push({ title: 'Context Max', value: formatTokens(keeper.context_max) })
  if (keeper.memory_recent_note) extras.push({ title: 'Memory Note', value: keeper.memory_recent_note })
  if (keeper.k2k_count != null) extras.push({ title: 'K2K Count', value: String(keeper.k2k_count) })
  if (keeper.conversation_tail_count != null) extras.push({ title: 'Conv Tail', value: String(keeper.conversation_tail_count) })
  if (keeper.handoff_count_total != null) extras.push({ title: 'Total Handoffs', value: String(keeper.handoff_count_total) })
  if (keeper.compaction_count != null) extras.push({ title: 'Compactions', value: String(keeper.compaction_count) })
  if (keeper.last_compaction_saved_tokens != null) extras.push({ title: 'Last Compact Saved', value: formatTokens(keeper.last_compaction_saved_tokens) })
  if (keeper.context?.message_count != null) extras.push({ title: 'Message Count', value: String(keeper.context.message_count) })
  if (keeper.context?.has_checkpoint != null) extras.push({ title: 'Has Checkpoint', value: keeper.context.has_checkpoint ? 'Yes' : 'No' })

  const filtered = filter
    ? fields.filter(f => f.title.toLowerCase().includes(filter) || f.key.includes(filter) || f.value.toLowerCase().includes(filter))
    : fields

  return html`
    <div class="max-h-[460px] overflow-y-auto">
      <input
        class="w-full py-2 px-3 mb-3 rounded-lg border border-[var(--card-border)] bg-[var(--white-3)] text-xs text-[var(--text-body)] placeholder:text-[var(--text-muted)] focus:outline-none focus:border-[var(--ok-40)]"
        type="text"
        placeholder="Search fields..."
        value=${fieldSearch.value}
        onInput=${(e: Event) => { fieldSearch.value = (e.target as HTMLInputElement).value }}
      />
      <div class="flex flex-col">
        ${filtered.map((f, i) => html`
          <div class="grid grid-cols-[100px_80px_1fr] gap-2 py-2 px-2 text-xs rounded-md ${i % 2 === 0 ? 'bg-[var(--white-2)]' : ''}">
            <span class="font-semibold text-[var(--text-body)] truncate">${f.title}</span>
            <span class="font-mono text-[var(--cyan)] text-[11px] truncate">${f.key}</span>
            <span class="text-right text-[var(--text-body)] truncate">${f.value}</span>
          </div>
        `)}
        ${extras.map((f, i) => html`
          <div class="grid grid-cols-[100px_1fr] gap-2 py-2 px-2 text-xs rounded-md ${(filtered.length + i) % 2 === 0 ? 'bg-[var(--white-2)]' : ''}">
            <span class="font-semibold text-[var(--text-body)] truncate">${f.title}</span>
            <span class="text-right text-[var(--text-body)] truncate ${f.mono ? 'font-mono' : ''}">${f.value}</span>
          </div>
        `)}
      </div>
    </div>
  `
}

// ── TRPG, Equipment, Relationships, Traits ───────────────

export function TrpgStats({ stats }: { stats: TrpgCharacterStats }) {
  const hpPct = stats.max_hp > 0 ? Math.round((stats.hp / stats.max_hp) * 100) : 0
  const mpPct = stats.max_mp > 0 ? Math.round((stats.mp / stats.max_mp) * 100) : 0

  return html`
    <div>
      <div class="flex gap-3 mb-3">
        <div class="flex-1">
          <div class="flex justify-between text-[11px] text-[var(--text-muted)] mb-1">
            <span>HP</span>
            <span>${stats.hp}/${stats.max_hp}</span>
          </div>
          <div class="h-2 bg-[var(--white-6)] rounded-full overflow-hidden">
            <div class="h-full rounded-full transition-all" style="width:${hpPct}%; background:${hpPct > 50 ? '#4ade80' : hpPct > 25 ? '#fbbf24' : '#ef4444'};" />
          </div>
        </div>
        <div class="flex-1">
          <div class="flex justify-between text-[11px] text-[var(--text-muted)] mb-1">
            <span>MP</span>
            <span>${stats.mp}/${stats.max_mp}</span>
          </div>
          <div class="h-2 bg-[var(--white-6)] rounded-full overflow-hidden">
            <div class="h-full rounded-full" style="width:${mpPct}%; background:#818cf8;" />
          </div>
        </div>
      </div>
      <div class="grid grid-cols-3 gap-2">
        ${[
          { label: 'STR', value: stats.strength },
          { label: 'DEX', value: stats.dexterity },
          { label: 'CON', value: stats.constitution },
          { label: 'INT', value: stats.intelligence },
          { label: 'WIS', value: stats.wisdom },
          { label: 'CHA', value: stats.charisma },
        ].map(s => html`
          <div class="text-center py-2 px-1.5 bg-[var(--white-3)] rounded-lg border border-[var(--card-border)]">
            <div class="text-[10px] text-[var(--text-muted)] uppercase tracking-wider">${s.label}</div>
            <div class="text-lg font-bold text-[var(--text-strong)] mt-0.5">${s.value}</div>
          </div>
        `)}
      </div>
      <div class="mt-3 text-xs text-[var(--text-muted)]">
        Level ${stats.level} -- XP ${stats.xp}
      </div>
    </div>
  `
}

export function EquipmentList({ items }: { items: string[] }) {
  if (items.length === 0) return html`<div class="py-2 px-3 text-xs text-[var(--text-muted)] italic">No equipment</div>`

  return html`
    <div class="flex flex-col gap-1.5">
      ${items.map((item, i) => html`
        <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]">
          <span class="text-xs text-[var(--text-body)]">${item}</span>
          <span class="text-[10px] text-[var(--cyan)] font-mono">#${i + 1}</span>
        </div>
      `)}
    </div>
  `
}

export function RelationshipList({ rels }: { rels: Record<string, string> }) {
  const entries = Object.entries(rels)
  if (entries.length === 0) return html`<div class="py-2 px-3 text-xs text-[var(--text-muted)] italic">No relationships</div>`

  return html`
    <div class="max-h-[220px] overflow-y-auto flex flex-col gap-1.5">
      ${entries.map(([name, relation]) => html`
        <div class="flex items-center gap-2 py-2 px-3 bg-[var(--white-3)] rounded-lg">
          <span class="inline-flex items-center py-0.5 px-2 rounded-full text-[11px] font-medium bg-[var(--accent-12)] text-[#9ad9ff] border border-[rgba(71,184,255,0.25)]">${name}</span>
          <span class="text-[11px] text-[var(--text-muted)] font-mono">${relation}</span>
        </div>
      `)}
    </div>
  `
}

export function TraitsList({ traits, label }: { traits: string[]; label: string }) {
  if (traits.length === 0) return null

  return html`
    <div class="mb-3">
      <div class="text-[10px] text-[var(--text-muted)] uppercase tracking-wider font-semibold mb-2">${label}</div>
      <div class="flex flex-wrap gap-1.5">
        ${traits.map(t => html`<span class="inline-flex items-center py-0.5 px-2.5 rounded-full text-[11px] font-medium bg-[var(--accent-12)] text-[#9ad9ff] border border-[rgba(71,184,255,0.25)]">${t}</span>`)}
      </div>
    </div>
  `
}
