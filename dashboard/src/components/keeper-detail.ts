// Keeper detail overlay — full keeper info with KPIs, field dictionary,
// memory, conversations, equipment, relationships, handoff timeline
// CSS classes: .keeper-kpis, .keeper-field-dict, .keeper-memory-list, etc. (components.css)

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { Card } from './common/card'
import { StatusBadge } from './common/status-badge'
import { TimeAgo } from './common/time-ago'
import type { Keeper, TrpgCharacterStats } from '../types'

// ── Global overlay state ──────────────────────────────────

export const selectedKeeper = signal<Keeper | null>(null)

export function openKeeperDetail(k: Keeper) {
  selectedKeeper.value = k
}

export function closeKeeperDetail() {
  selectedKeeper.value = null
}

// ── Sub-components ────────────────────────────────────────

function KpiGrid({ keeper }: { keeper: Keeper }) {
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
    </div>
  `
}

function ContextChart({ keeper }: { keeper: Keeper }) {
  const ratio = keeper.context_ratio
  if (ratio == null) return null

  const pct = Math.round(ratio * 100)
  const statusClass = pct > 80 ? 'bad' : pct > 60 ? 'warn' : ''

  return html`
    <div class="keeper-chart-card">
      <div class="keeper-chart-container" style="display: flex; align-items: flex-end; gap: 2px; padding: 0 20px;">
        <div style="flex:1; background: rgba(74,222,128,0.3); height: ${Math.min(pct, 100)}%; border-radius: 4px 4px 0 0; min-height: 4px; transition: height 0.3s;" />
        <div style="flex:1; background: rgba(255,255,255,0.06); height: 100%; border-radius: 4px 4px 0 0;" />
      </div>
      <div class="keeper-chart-meta">
        Context usage: <span class=${statusClass}>${pct}%</span>
        ${pct > 70 ? html` — <span class="warn">Compaction soon</span>` : null}
        ${pct > 85 ? html` — <span class="bad">Handoff imminent</span>` : null}
      </div>
    </div>
  `
}

// Searchable field dictionary — shows all keeper properties
const fieldSearch = signal('')

function FieldDictionary({ keeper }: { keeper: Keeper }) {
  const filter = fieldSearch.value.toLowerCase()

  const fields: { title: string; key: string; value: string }[] = [
    { title: 'Name', key: 'name', value: keeper.name },
    { title: 'Emoji', key: 'emoji', value: keeper.emoji },
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

// ── Main Detail Overlay ───────────────────────────────────

export function KeeperDetailOverlay() {
  const keeper = selectedKeeper.value
  if (!keeper) return null

  return html`
    <div
      class="keeper-detail-overlay"
      style="position:fixed; inset:0; z-index:1000; background:rgba(0,0,0,0.7); display:flex; align-items:center; justify-content:center; padding:20px;"
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
        </div>
      </div>
    </div>
  `
}
