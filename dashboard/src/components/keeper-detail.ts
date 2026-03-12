// Keeper detail overlay — focused keeper profile, continuity, and direct comms.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { currentDashboardActor, runOperatorAction } from '../api'
import { Card } from './common/card'
import { StatusBadge } from './common/status-badge'
import { TimeAgo } from './common/time-ago'
import type { Keeper, KeeperMetricPoint, TrpgCharacterStats } from '../types'
import { invalidateDashboardCache, refreshDashboard } from '../store'
import { normalizeLodgeTickResult, selectKeeper } from '../keeper-runtime'
import {
  KeeperConversationPanel,
  KeeperDiagnosticSummary,
  KeeperRuntimeActions,
} from './keeper-shared'
import { showToast } from './common/toast'

export const selectedKeeper = signal<Keeper | null>(null)

export function openKeeperDetail(k: Keeper) {
  selectedKeeper.value = k
  selectKeeper(k.name)
}

export function closeKeeperDetail() {
  selectedKeeper.value = null
}

function contextPressureLabel(value?: number | null): string {
  if (typeof value !== 'number' || Number.isNaN(value)) return '확인 필요'
  if (value >= 0.85) return '높음'
  if (value >= 0.7) return '상승 중'
  return '안정'
}

function ContextChart({ keeper }: { keeper: Keeper }) {
  const series = keeper.metrics_series ?? []
  if (series.length < 2) {
    const pct = ((keeper.context?.context_ratio ?? keeper.context_ratio ?? 0) * 100)
    const color = pct > 85 ? '#ef4444' : pct > 70 ? '#f59e0b' : '#22c55e'
    return html`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${pct.toFixed(1)}%;background:${color}"></div>
        </div>
        <span class="chart-pct">${pct.toFixed(1)}%</span>
      </div>`
  }

  const W = 200
  const H = 60
  const pad = 2
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
        <line x1="${pad}" y1="${(H - pad - 0.7 * (H - 2 * pad)).toFixed(1)}" x2="${W - pad}" y2="${(H - pad - 0.7 * (H - 2 * pad)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${pad}" y1="${(H - pad - 0.85 * (H - 2 * pad)).toFixed(1)}" x2="${W - pad}" y2="${(H - pad - 0.85 * (H - 2 * pad)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${pts.filter(({ p }) => p.is_handoff).map(({ x }) => html`
          <line x1="${x.toFixed(1)}" y1="${pad}" x2="${x.toFixed(1)}" y2="${H - pad}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${polyline}" fill="none" stroke="${lineColor}" stroke-width="1.5"/>
      </svg>
      <span class="chart-pct">${lastRatio.toFixed(1)}%</span>
    </div>`
}

function TrpgStats({ stats }: { stats: TrpgCharacterStats }) {
  const hpPct = stats.max_hp > 0 ? Math.round((stats.hp / stats.max_hp) * 100) : 0
  const mpPct = stats.max_mp > 0 ? Math.round((stats.mp / stats.max_mp) * 100) : 0

  return html`
    <div>
      <div style="display:flex; gap:12px; margin-bottom:10px;">
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
        Level ${stats.level} · XP ${stats.xp}
      </div>
    </div>
  `
}

function EquipmentList({ items }: { items: string[] }) {
  if (items.length === 0) return html`<div class="empty-state" style="font-size:13px;">No equipment</div>`

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
  if (entries.length === 0) return html`<div class="empty-state" style="font-size:13px;">No relationships</div>`

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
    <div style="margin-bottom:12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${label}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${traits.map(t => html`<span class="keeper-mention-chip">${t}</span>`)}
      </div>
    </div>
  `
}

async function pokeLodgeNow(): Promise<void> {
  try {
    const response = await runOperatorAction({
      actor: currentDashboardActor(),
      action_type: 'lodge_tick',
      target_type: 'room',
      payload: {},
    })
    const result = normalizeLodgeTickResult(response.result)
    invalidateDashboardCache()
    await refreshDashboard()
    if (result?.skipped_reason) {
      showToast(result.skipped_reason, 'warning')
    } else {
      showToast(
        result ? `Poke finished: ${result.acted}/${result.checked} acted` : 'Poke finished',
        result && result.acted > 0 ? 'success' : 'warning',
      )
    }
  } catch (err) {
    const message = err instanceof Error ? err.message : 'Failed to run Lodge poke'
    showToast(message, 'error')
  }
}

function KeeperCommsPanel({ keeper }: { keeper: Keeper }) {
  return html`
    <div style="margin-top:24px; border-top:1px solid rgba(255,255,255,0.1); padding-top:24px;">
      <h3 style="margin:0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Runtime Diagnostics</h3>

      <div style="display:grid; grid-template-columns:1fr 1fr; gap:20px;">
        <div style="display:flex; flex-direction:column; gap:12px;">
          <${KeeperDiagnosticSummary} keeper=${keeper} />
          <${KeeperRuntimeActions}
            actor=${currentDashboardActor()}
            keeper=${keeper}
            onPokeLodge=${() => { void pokeLodgeNow() }}
          />
        </div>

        <div style="min-height:345px;">
          <${KeeperConversationPanel}
            keeperName=${keeper.name}
            placeholder="Direct prompt for this keeper"
          />
        </div>
      </div>
    </div>
  `
}

export function KeeperDetailOverlay() {
  const keeper = selectedKeeper.value
  if (!keeper) return null

  const profileItems = (keeper.traits?.length ?? 0) > 0 || (keeper.interests?.length ?? 0) > 0 || Boolean(keeper.skill_primary) || Boolean(keeper.last_heartbeat)

  return html`
    <div
      class="keeper-detail-overlay"
      data-testid="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${(e: Event) => {
        if ((e.target as HTMLElement).classList.contains('keeper-detail-overlay')) {
          closeKeeperDetail()
        }
      }}
    >
      <div style="max-width:780px; width:100%; max-height:90vh; overflow-y:auto; background:#1a1a2e; border-radius:16px; border:1px solid rgba(255,255,255,0.08); padding:24px;">
        <div style="display:flex; align-items:center; justify-content:space-between; margin-bottom:20px;">
          <div style="display:flex; align-items:center; gap:12px;">
            <span style="font-size:32px;">${keeper.emoji}</span>
            <div>
              <h2 style="margin:0; font-size:20px; color:#e0e0e0;">${keeper.name}</h2>
              ${keeper.koreanName ? html`<div style="font-size:13px; color:#888;">${keeper.koreanName}</div>` : null}
            </div>
            <${StatusBadge} status=${keeper.status} />
          </div>
          <button
            onClick=${() => closeKeeperDetail()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        <${ContextChart} keeper=${keeper} />

        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">
          ${profileItems
            ? html`
                <${Card} title="Profile">
                  <${TraitsList} traits=${keeper.traits ?? []} label="Traits" />
                  <${TraitsList} traits=${keeper.interests ?? []} label="Interests" />
                  ${keeper.skill_primary
                    ? html`<div style="font-size:12px; color:#888; margin-top:6px;">Skill route: <span style="color:#22d3ee;">${keeper.skill_primary}</span></div>`
                    : null}
                  ${keeper.last_heartbeat
                    ? html`<div style="font-size:12px; color:#888; margin-top:6px;">Last heartbeat: <${TimeAgo} timestamp=${keeper.last_heartbeat} /></div>`
                    : null}
                <//>
              `
            : null}

          ${keeper.trpg_stats
            ? html`
                <${Card} title="TRPG Stats">
                  <${TrpgStats} stats=${keeper.trpg_stats} />
                <//>
              `
            : null}

          ${keeper.inventory && keeper.inventory.length > 0
            ? html`
                <${Card} title="Equipment (${keeper.inventory.length})">
                  <${EquipmentList} items=${keeper.inventory} />
                <//>
              `
            : null}

          ${keeper.relationships && Object.keys(keeper.relationships).length > 0
            ? html`
                <${Card} title="Relationships (${Object.keys(keeper.relationships).length})">
                  <${RelationshipList} rels=${keeper.relationships} />
                <//>
              `
            : null}

          <${Card} title="Memory & Context">
            <div class="keeper-signal-list">
              <div class="keeper-signal-row">
                <span>Context pressure</span>
                <strong>${contextPressureLabel(keeper.context?.context_ratio ?? keeper.context_ratio ?? null)}</strong>
              </div>
              <div class="keeper-signal-row">
                <span>Current ratio</span>
                <strong>
                  ${typeof (keeper.context?.context_ratio ?? keeper.context_ratio) === 'number'
                    ? `${Math.round((keeper.context?.context_ratio ?? keeper.context_ratio ?? 0) * 100)}%`
                    : '-'}
                </strong>
              </div>
              ${keeper.memory_recent_note
                ? html`<div class="keeper-memory-note">${keeper.memory_recent_note}</div>`
                : html`<div class="empty-state" style="font-size:12px;">No recent memory note</div>`}
            </div>
          <//>
        </div>

        <${KeeperCommsPanel} keeper=${keeper} />
      </div>
    </div>
  `
}
