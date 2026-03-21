// Keeper detail overlay — full keeper info with KPIs, field dictionary,
// memory, conversations, equipment, relationships, handoff timeline
// CSS classes: .keeper-kpis, .keeper-field-dict, .keeper-memory-list, etc. (components.css)

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { runOperatorAction } from '../api'
import { Card } from './common/card'
import { StatusBadge } from './common/status-badge'
import { TimeAgo } from './common/time-ago'
import type { Keeper } from '../types'
import { invalidateDashboardCache, refreshDashboard } from '../store'
import { selectKeeper } from '../keeper-runtime'
import {
  KeeperConversationPanel,
  KeeperDiagnosticSummary,
  KeeperRuntimeActions,
} from './keeper-shared'
import { showToast } from './common/toast'
import {
  AutonomyMeter,
  ContextChart,
  EquipmentList,
  FieldDictionary,
  KpiGrid,
  RelationshipList,
  TraitsList,
  TrpgStats,
} from './keeper-detail-panels'
import {
  KeeperNeighborhood,
  RuntimeSignals,
} from './keeper-detail-runtime'
import { KeeperConfigPanel, resetKeeperConfig } from './keeper-config-panel'

// ── Global overlay state ──────────────────────────────────

export const selectedKeeper = signal<Keeper | null>(null)

export function openKeeperDetail(k: Keeper) {
  selectedKeeper.value = k
  selectKeeper(k.name)
}

export function closeKeeperDetail() {
  selectedKeeper.value = null
  resetKeeperConfig()
}

// ── Main Detail Overlay ───────────────────────────────────

function currentOperatorActor(): string {
  const q = new URLSearchParams(window.location.search)
  const queryActor = q.get('agent') ?? q.get('agent_name')
  const storedActor = localStorage.getItem('masc_dashboard_agent_name')
  const actor = (queryActor ?? storedActor ?? 'dashboard').trim()
  return actor || 'dashboard'
}

async function runSocialSweep(): Promise<void> {
  try {
    await runOperatorAction({
      actor: currentOperatorActor(),
      action_type: 'social_sweep',
      target_type: 'room',
      payload: {},
    })
    invalidateDashboardCache()
    await refreshDashboard()
    showToast('Social sweep finished', 'success')
  } catch (err) {
    const message = err instanceof Error ? err.message : 'Failed to run social sweep'
    showToast(message, 'error')
  }
}

function KeeperCommsPanel({ keeper }: { keeper: Keeper }) {
  return html`
    <div class="keeper-comms-section">
      <h3 class="keeper-comms-heading">Direct Comms</h3>

      <div class="keeper-comms-layout">
        ${'' /* Chat takes full width — the primary interaction surface */}
        <div class="keeper-comms-chat">
          <${KeeperConversationPanel}
            keeperName=${keeper.name}
            placeholder="이 키퍼에게 직접 프롬프트"
          />
        </div>

        ${'' /* Diagnostics and actions in a collapsible panel below */}
        <details class="keeper-comms-diagnostics">
          <summary class="keeper-comms-diagnostics-toggle">런타임 진단 및 액션</summary>
          <div class="keeper-comms-diagnostics-body">
            <${KeeperDiagnosticSummary} keeper=${keeper} />
            <${KeeperRuntimeActions}
              actor=${currentOperatorActor()}
              keeper=${keeper}
              onSocialSweep=${() => { void runSocialSweep() }}
            />
          </div>
        </details>
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
      data-testid="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${(e: Event) => {
        if ((e.target as HTMLElement).classList.contains('keeper-detail-overlay')) {
          closeKeeperDetail()
        }
      }}
    >
      <div style="max-width:1100px; width:100%; max-height:90vh; overflow-y:auto; background:#1a1a2e; border-radius:16px; border:1px solid rgba(255,255,255,0.08); padding:24px;">
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

        ${'' /* Direct conversation — placed prominently before detail cards */}
        <${KeeperCommsPanel} keeper=${keeper} />

        ${'' /* Two-column grid for sections */}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${'' /* Left: Field Dictionary */}
          <${Card} title="필드 사전">
            <${FieldDictionary} keeper=${keeper} />
          <//>

          ${'' /* Right: Traits + Interests */}
          <${Card} title="프로필">
            <${TraitsList} traits=${keeper.traits ?? []} label="특성" />
            <${TraitsList} traits=${keeper.interests ?? []} label="관심사" />
            ${keeper.primaryValue
              ? html`<div style="font-size:12px; color:#888;">핵심 가치: <span style="color:#4ade80;">${keeper.primaryValue}</span></div>`
              : null}
            ${keeper.skill_primary
              ? html`<div style="font-size:12px; color:#888; margin-top:6px;">
                  스킬 경로: <span style="color:#22d3ee;">${keeper.skill_primary}</span>
                </div>`
              : null}
            ${keeper.skill_reason
              ? html`<div style="font-size:12px; color:#888; margin-top:4px;">${keeper.skill_reason}</div>`
              : null}
            ${keeper.last_heartbeat
              ? html`<div style="font-size:12px; color:#888; margin-top:6px;">
                  마지막 하트비트: <${TimeAgo} timestamp=${keeper.last_heartbeat} />
                </div>`
              : null}
          <//>

          ${'' /* Autonomy Level (if available) */}
          ${keeper.autonomy_level
            ? html`
              <${Card} title="자율성">
                <${AutonomyMeter} keeper=${keeper} />
              <//>
            `
            : null}

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

          <${Card} title="런타임 신호">
            <${RuntimeSignals} keeper=${keeper} />
          <//>

          <${Card} title="이웃 관계 및 도구 감사">
            <${KeeperNeighborhood} keeper=${keeper} />
          <//>

          <${Card} title="Config">
            <${KeeperConfigPanel} keeperName=${keeper.name} />
          <//>

          <${Card} title="메모리 및 컨텍스트">
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
      </div>
    </div>
  `
}
