// Keeper detail sub-components — KPIs, charts, field dictionary,
// equipment, relationships, traits
// Redesigned: individual KPI cards, clean table, proper spacing.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { formatPct } from '../lib/format-number'
import { TextInput } from './common/input'
import type { Keeper, KeeperMetricPoint } from '../types'

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
  const ctxHint = ctxPct != null && ctxPct > 80 ? '한계 접근 중' : undefined

  // Provider-model call statistics from metrics_series
  const modelCounts: Record<string, number> = {}
  for (const pt of series) {
    if (pt.model_used) {
      modelCounts[pt.model_used] = (modelCounts[pt.model_used] ?? 0) + 1
    }
  }
  const modelEntries = Object.entries(modelCounts).sort((a, b) => b[1] - a[1])
  const totalCalls = modelEntries.reduce((s, [, c]) => s + c, 0)

  return html`
    <div class="flex flex-col gap-3 mb-5">
      ${'' /* Primary KPIs — 3 cols (activityLevel removed) */}
      <div class="grid grid-cols-3 gap-3">
        <${KpiCard}
          label="Generation"
          value=${keeper.generation ?? '-'}
          hint="승계 횟수"
        />
        <${KpiCard}
          label="Turns"
          value=${keeper.turn_count ?? '-'}
          hint="총 루프 회차"
        />
        <${KpiCard}
          label="Context"
          value=${ctxPct != null ? `${ctxPct}%` : '-'}
          hint=${ctxHint}
          tone=${ctxTone}
          progress=${ctxPct ?? undefined}
        />
      </div>
      ${'' /* Model usage distribution */}
      ${totalCalls > 0 ? html`
        <div class="rounded-xl border border-[var(--card-border)] bg-[var(--white-2)] p-3">
          <div class="mb-2 text-[10px] font-semibold tracking-[0.08em] uppercase text-[var(--text-muted)]">Provider-Model 호출 분포</div>
          <div class="flex flex-col gap-1.5">
            ${modelEntries.slice(0, 4).map(([model, count]) => {
              const pct = Math.round((count / totalCalls) * 100)
              return html`
                <div class="flex items-center gap-2 text-xs">
                  <span class="shrink-0 w-[140px] truncate font-mono text-[11px] text-[#9ad9ff]" title=${model}>${model}</span>
                  <div class="flex-1 h-1.5 bg-[var(--white-6)] rounded-full overflow-hidden">
                    <div class="h-full rounded-full bg-[var(--accent)]" style="width:${pct}%"></div>
                  </div>
                  <span class="shrink-0 w-10 text-right text-[var(--text-muted)]">${count}회</span>
                </div>
              `
            })}
          </div>
          ${modelEntries.length > 4 ? html`
            <div class="mt-1 text-[10px] text-[var(--text-muted)]">외 ${modelEntries.length - 4}개 모델</div>
          ` : null}
        </div>
      ` : null}
      ${'' /* Secondary KPIs — 3-4 cols, smaller feel */}
      <div class="grid grid-cols-3 sm:grid-cols-4 gap-2">
        <${KpiCard}
          label="Tokens"
          value=${formatTokens(keeper.context_tokens)}
          hint=${keeper.context_max ? `/ ${formatTokens(keeper.context_max)}` : undefined}
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

// ── Raw Data (Debug) ─────────────────────────────────────
// Collapsed-by-default debug dump of all keeper fields.
// Primary display is handled by Header, KpiGrid, Profile, and Config sections.

const fieldSearch = signal('')

export function RawDataDebug({ keeper }: { keeper: Keeper }) {
  const filter = fieldSearch.value.toLowerCase()

  const fields: { title: string; key: string; value: string }[] = [
    { title: 'Name', key: 'name', value: keeper.name },
    { title: 'Emoji', key: 'emoji', value: keeper.emoji ?? '-' },
    { title: 'Korean', key: 'koreanName', value: keeper.koreanName ?? '-' },
    { title: 'Model', key: 'model', value: keeper.model ?? '-' },
    { title: 'Status', key: 'status', value: keeper.status },
    { title: 'Primary', key: 'primaryValue', value: keeper.primaryValue ?? '-' },
    { title: 'Gen', key: 'generation', value: String(keeper.generation ?? '-') },
    { title: 'Turns', key: 'turn_count', value: String(keeper.turn_count ?? '-') },
    { title: 'Context', key: 'context_ratio', value: formatPct(keeper.context_ratio) },
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
      <${TextInput}
        placeholder="필드 검색..."
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

// ── Equipment, Relationships, Traits ───────────────

export function EquipmentList({ items }: { items: string[] }) {
  if (items.length === 0) return html`<div class="py-2 px-3 text-xs text-[var(--text-muted)] italic">장비 없음</div>`

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
  if (entries.length === 0) return html`<div class="py-2 px-3 text-xs text-[var(--text-muted)] italic">관계 없음</div>`

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
