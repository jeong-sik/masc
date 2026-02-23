import { useState, useEffect } from "preact/hooks"
import { callMcpTool } from "../api"
// Keeper detail overlay — full keeper info with KPIs, field dictionary,
// memory, conversations, equipment, relationships, handoff timeline
// CSS classes: .keeper-kpis, .keeper-field-dict, .keeper-memory-list, etc. (components.css)

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { Card } from './common/card'
import { StatusBadge } from './common/status-badge'
import { TimeAgo } from './common/time-ago'
import type { Keeper, KeeperMetricPoint, TrpgCharacterStats } from '../types'

// ── Global overlay state ──────────────────────────────────

export const selectedKeeper = signal<Keeper | null>(null)

export function openKeeperDetail(k: Keeper) {
  selectedKeeper.value = k
}

export function closeKeeperDetail() {
  selectedKeeper.value = null
}

// ── Sub-components ────────────────────────────────────────

function formatTokens(n: number | undefined): string {
  if (!n) return '—'
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}K`
  return String(n)
}

function KpiGrid({ keeper }: { keeper: Keeper }) {
  const series = keeper.metrics_series ?? []
  const lastPt = series[series.length - 1] as KeeperMetricPoint | undefined
  const latestCost = lastPt?.cost_usd != null ? `$${lastPt.cost_usd.toFixed(4)}` : '—'

  const items: { label: string; value: string | number; hint?: string }[] = [
    {
      label: 'Generation',
      value: keeper.generation ?? '-',
      hint: 'Succession count',
    },
    {
      label: 'Turns',
      value: keeper.turn_count ?? '-',
      hint: 'Total loop turns',
    },
    {
      label: 'Context',
      value: keeper.context_ratio != null ? `${Math.round(keeper.context_ratio * 100)}%` : '-',
      hint: keeper.context_ratio != null && keeper.context_ratio > 0.8 ? 'Near limit' : undefined,
    },
    {
      label: 'Activity',
      value: keeper.activityLevel ?? '-',
      hint: 'Level 0–5',
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
      <div class="kpi-tile">
        <div class="kpi-value">${latestCost}</div>
        <div class="kpi-label">Cost (USD)</div>
      </div>
    </div>
  `
}

function ContextChart({ keeper }: { keeper: Keeper }) {
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

// Searchable field dictionary — shows all keeper properties
const fieldSearch = signal('')

function FieldDictionary({ keeper }: { keeper: Keeper }) {
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

function TrpgStats({ stats }: { stats: TrpgCharacterStats }) {
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
        Level ${stats.level} — XP ${stats.xp}
      </div>
    </div>
  `
}

function EquipmentList({ items }: { items: string[] }) {
  if (items.length === 0) return html`<div class="empty-state" style="font-size:13px">No equipment</div>`

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

function RelationshipList({ rels }: { rels: Record<string, string> }) {
  const entries = Object.entries(rels)
  if (entries.length === 0) return html`<div class="empty-state" style="font-size:13px">No relationships</div>`

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

function TraitsList({ traits, label }: { traits: string[]; label: string }) {
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

function formatPct(value: number | undefined): string {
  if (value == null || Number.isNaN(value)) return '-'
  return `${Math.round(value * 100)}%`
}

function RuntimeSignals({ keeper }: { keeper: Keeper }) {
  const mw = keeper.metrics_window

  const rows: Array<{ label: string; value: string | number }> = [
    { label: 'Model fallback', value: formatPct(typeof mw?.model_fallback_rate === 'number' ? mw.model_fallback_rate : undefined) },
    { label: 'Proactive fallback', value: formatPct(typeof mw?.proactive_fallback_rate === 'number' ? mw.proactive_fallback_rate : undefined) },
    { label: 'Memory pass rate', value: formatPct(typeof mw?.memory_pass_rate === 'number' ? mw.memory_pass_rate : undefined) },
    { label: 'Handoffs', value: typeof mw?.handoff_count === 'number' ? mw.handoff_count : keeper.handoff_count_total ?? '-' },
    { label: 'Compactions', value: typeof mw?.compaction_events === 'number' ? mw.compaction_events : keeper.compaction_count ?? '-' },
    { label: 'Saved tokens', value: typeof mw?.compaction_saved_tokens === 'number' ? mw.compaction_saved_tokens : keeper.last_compaction_saved_tokens ?? '-' },
    { label: 'K2K events', value: keeper.k2k_count ?? '-' },
    { label: 'Conversation tail', value: keeper.conversation_tail_count ?? '-' },
    { label: 'Tool Calls', value: typeof mw?.tool_call_count === 'number' ? mw.tool_call_count : '-' },
    { label: 'Preview Similarity', value: typeof mw?.proactive_preview_similarity_avg === 'number' ? `${(mw.proactive_preview_similarity_avg * 100).toFixed(1)}%` : '-' },
    { label: 'Memory Avg Score', value: typeof mw?.memory_avg_score === 'number' ? mw.memory_avg_score.toFixed(3) : '-' },
    { label: 'Fallback Rate', value: typeof mw?.fallback_rate === 'number' ? `${(mw.fallback_rate * 100).toFixed(1)}%` : '-' },
  ]

  return html`
    <div class="keeper-signal-list">
      ${rows.map(r => html`
        <div class="keeper-signal-row">
          <span>${r.label}</span>
          <strong>${r.value}</strong>
        </div>
      `)}
    </div>
  `
}

// ── Main Detail Overlay ───────────────────────────────────


function KeeperMonologue({ keeperName }: { keeperName: string }) {
  const [statusText, setStatusText] = useState<string>("Loading internal monologue...")
  const [chatInput, setChatInput] = useState<string>("")
  const [chatLog, setChatLog] = useState<{role: string, text: string}[]>([])
  const [isSending, setIsSending] = useState(false)
  
  const fetchStatus = async () => {
    try {
      const res = await callMcpTool("masc_keeper_status", { name: keeperName, fast: false, include_history_tail: true, include_context: true })
      if (typeof res === "string") {
        setStatusText(res)
      } else {
        setStatusText(JSON.stringify(res, null, 2))
      }
    } catch (e) {
      setStatusText("Failed to load: " + String(e))
    }
  }

  useEffect(() => {
    fetchStatus()
  }, [keeperName])

  const sendPing = async () => {
    if (!chatInput.trim()) return
    setIsSending(true)
    const msg = chatInput
    setChatInput("")
    setChatLog(prev => [...prev, {role: "You", text: msg}])
    try {
      const res = await callMcpTool("masc_keeper_msg", { name: keeperName, message: msg })
      setChatLog(prev => [...prev, {role: keeperName, text: typeof res === "string" ? res : JSON.stringify(res)}])
      fetchStatus() // refresh status after message
    } catch (e) {
      setChatLog(prev => [...prev, {role: "System", text: "Error: " + String(e)}])
    } finally {
      setIsSending(false)
    }
  }

  return html`
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Inner Monologue</h3>
      
      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <!-- Chat Area -->
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <div style="background: rgba(0,0,0,0.3); border: 1px solid var(--border); border-radius: 12px; height: 300px; overflow-y: auto; padding: 12px; display: flex; flex-direction: column; gap: 8px; font-size: 0.85rem;">
            ${chatLog.length === 0 ? html`<div style="color: var(--text-muted); font-style: italic;">No direct messages yet.</div>` : null}
            ${chatLog.map(msg => html`
              <div style="padding: 8px; border-radius: 8px; background: ${msg.role === "You" ? "rgba(0, 240, 255, 0.1)" : "rgba(255, 255, 255, 0.05)"}; border-left: 2px solid ${msg.role === "You" ? "var(--accent-cyan)" : "var(--text-muted)"};">
                <strong style="color: ${msg.role === "You" ? "var(--accent-cyan)" : "var(--text-primary)"}; display: block; margin-bottom: 4px;">${msg.role}</strong>
                <span style="white-space: pre-wrap;">${msg.text}</span>
              </div>
            `)}
          </div>
          <div style="display: flex; gap: 8px;">
            <input 
              type="text" 
              value=${chatInput} 
              onInput=${(e: any) => setChatInput(e.target.value)} 
              onKeyDown=${(e: KeyboardEvent) => e.key === "Enter" && !e.shiftKey && sendPing()}
              placeholder="Ping the agent..."
              disabled=${isSending}
              style="flex: 1; background: rgba(255,255,255,0.05); border: 1px solid var(--border); border-radius: 8px; padding: 8px 12px; color: var(--text-primary); font-family: var(--font-body);"
            />
            <button 
              onClick=${sendPing} 
              disabled=${isSending || !chatInput.trim()}
              style="background: var(--accent-cyan); color: #000; border: none; border-radius: 8px; padding: 8px 16px; font-weight: bold; cursor: pointer; opacity: ${isSending ? 0.5 : 1};"
            >
              ${isSending ? "Sending..." : "Send"}
            </button>
          </div>
        </div>

        <!-- Monologue / Status Area -->
        <div style="background: #050810; border: 1px solid var(--card-border); border-radius: 12px; padding: 12px; height: 345px; overflow-y: auto; font-family: monospace; font-size: 0.75rem; color: var(--ok); white-space: pre-wrap; box-shadow: inset 0 0 15px rgba(0,0,0,0.8);">
          ${statusText}
        </div>
        
      </div>
    </div>
  `
}

export function KeeperDetailOverlay() {
  const keeper = selectedKeeper.value
  if (!keeper) return null

  return html`
    <div
      class="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${(e: Event) => {
        if ((e.target as HTMLElement).classList.contains('keeper-detail-overlay')) {
          closeKeeperDetail()
        }
      }}
    >
      <div style="max-width:780px; width:100%; max-height:90vh; overflow-y:auto; background:#1a1a2e; border-radius:16px; border:1px solid rgba(255,255,255,0.08); padding:24px;">
        ${'' /* Header */}
        <div style="display:flex; align-items:center; justify-content:space-between; margin-bottom:20px;">
          <div style="display:flex; align-items:center; gap:12px;">
            <span style="font-size:32px;">${keeper.emoji}</span>
            <div>
              <h2 style="margin:0; font-size:20px; color:#e0e0e0;">${keeper.name}</h2>
              ${keeper.koreanName ? html`<div style="font-size:13px; color:#888;">${keeper.koreanName}</div>` : null}
            </div>
            <${StatusBadge} status=${keeper.status} />
            ${keeper.model ? html`<span class="pill">${keeper.model}</span>` : null}
          </div>
          <button
            onClick=${() => closeKeeperDetail()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${'' /* KPIs */}
        <${KpiGrid} keeper=${keeper} />

        ${'' /* Context chart */}
        <${ContextChart} keeper=${keeper} />

        ${'' /* Two-column grid for sections */}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${'' /* Left: Field Dictionary */}
          <${Card} title="Field Dictionary">
            <${FieldDictionary} keeper=${keeper} />
          <//>

          ${'' /* Right: Traits + Interests */}
          <${Card} title="Profile">
            <${TraitsList} traits=${keeper.traits ?? []} label="Traits" />
            <${TraitsList} traits=${keeper.interests ?? []} label="Interests" />
            ${keeper.primaryValue
              ? html`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${keeper.primaryValue}</span></div>`
              : null}
            ${keeper.skill_primary
              ? html`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${keeper.skill_primary}</span>
                </div>`
              : null}
            ${keeper.skill_reason
              ? html`<div style="font-size:12px; color:#888; margin-top:4px;">${keeper.skill_reason}</div>`
              : null}
            ${keeper.last_heartbeat
              ? html`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${TimeAgo} timestamp=${keeper.last_heartbeat} />
                </div>`
              : null}
          <//>

          ${'' /* TRPG Stats (if available) */}
          ${keeper.trpg_stats
            ? html`
              <${Card} title="TRPG Stats">
                <${TrpgStats} stats=${keeper.trpg_stats} />
              <//>
            `
            : null}

          ${'' /* Equipment */}
          ${keeper.inventory && keeper.inventory.length > 0
            ? html`
              <${Card} title="Equipment (${keeper.inventory.length})">
                <${EquipmentList} items=${keeper.inventory} />
              <//>
            `
            : null}

          ${'' /* Relationships */}
          ${keeper.relationships && Object.keys(keeper.relationships).length > 0
            ? html`
              <${Card} title="Relationships (${Object.keys(keeper.relationships).length})">
                <${RelationshipList} rels=${keeper.relationships} />
              <//>
            `
            : null}

          <${Card} title="Runtime Signals">
            <${RuntimeSignals} keeper=${keeper} />
          <//>

          <${Card} title="Memory & Context">
            <div class="keeper-signal-list">
              <div class="keeper-signal-row">
                <span>Context source</span>
                <strong>${keeper.context_source ?? keeper.context?.source ?? '-'}</strong>
              </div>
              <div class="keeper-signal-row">
                <span>Context tokens</span>
                <strong>
                  ${keeper.context_tokens ?? keeper.context?.context_tokens ?? '-'}
                  /
                  ${keeper.context_max ?? keeper.context?.context_max ?? '-'}
                </strong>
              </div>
              ${keeper.memory_recent_note
                ? html`
                  <div class="keeper-memory-note">
                    ${keeper.memory_recent_note}
                  </div>
                `
                : html`<div class="empty-state" style="font-size:12px;">No recent memory note</div>`}
            </div>
          <//>
        </div>
        <${KeeperMonologue} keeperName=${keeper.name} />
      </div>
    </div>
  `
}
