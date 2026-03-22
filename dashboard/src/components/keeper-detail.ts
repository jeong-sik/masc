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
import { PipelineStageBar } from './keeper-pipeline-stage'

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
    <div class="mt-5 border-t border-[var(--white-10)] pt-5">
      <h3 class="m-0 mb-3.5 text-cyan text-[var(--fs-lg)]">Direct Comms</h3>

      <div class="flex flex-col gap-3.5">
        ${'' /* Chat takes full width — the primary interaction surface */}
        <div class="w-full">
          <${KeeperConversationPanel}
            keeperName=${keeper.name}
            placeholder="이 키퍼에게 직접 프롬프트"
          />
        </div>

        ${'' /* Diagnostics and actions in a collapsible panel below */}
        <details class="keeper-comms-diagnostics">
          <summary class="keeper-comms-diagnostics-toggle cursor-pointer py-2.5 px-3.5 text-[var(--fs-sm)] text-text-muted tracking-[0.03em] list-none select-none">런타임 진단 및 액션</summary>
          <div class="flex flex-col gap-3 px-3.5 pb-3.5">
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
      class="flex items-center justify-center p-5"
      onClick=${(e: Event) => {
        if ((e.target as HTMLElement).classList.contains('keeper-detail-overlay')) {
          closeKeeperDetail()
        }
      }}
    >
      <div style="max-width:1100px; width:100%; max-height:90vh; overflow-y:auto; background:#1a1a2e; border-radius:16px; border:1px solid rgba(255,255,255,0.08); padding:24px;">
        ${'' /* Header */}
        <div class="flex items-center justify-between mb-5">
          <div class="flex items-center gap-3">
            <span class="text-[32px]">${keeper.emoji}</span>
            <div>
              <h2 class="m-0 text-xl text-[#e0e0e0]">${keeper.name}</h2>
              ${keeper.koreanName ? html`<div class="text-[13px] text-[var(--text-dim)]">${keeper.koreanName}</div>` : null}
            </div>
            <${StatusBadge} status=${keeper.status} />
            ${keeper.model ? html`<span class="text-[length:var(--fs-2xs)] py-0.5 px-2 border border-solid border-[rgba(71,184,255,0.36)] bg-[var(--accent-12)] text-[#9ad9ff] whitespace-nowrap rounded-full">${keeper.model}</span>` : null}
          </div>
          <button
            onClick=${() => closeKeeperDetail()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${'' /* Pipeline stage indicator */}
        <${PipelineStageBar} stage=${keeper.pipeline_stage} />

        ${'' /* KPIs */}
        <${KpiGrid} keeper=${keeper} />

        ${'' /* Context chart */}
        <${ContextChart} keeper=${keeper} />

        ${'' /* Direct conversation — placed prominently before detail cards */}
        <${KeeperCommsPanel} keeper=${keeper} />

        ${'' /* Two-column grid for sections */}
        <div class="grid grid-cols-2 gap-4 mt-4">

          ${'' /* Left: Field Dictionary */}
          <${Card} title="필드 사전">
            <${FieldDictionary} keeper=${keeper} />
          <//>

          ${'' /* Right: Traits + Interests */}
          <${Card} title="프로필">
            <${TraitsList} traits=${keeper.traits ?? []} label="특성" />
            <${TraitsList} traits=${keeper.interests ?? []} label="관심사" />
            ${keeper.primaryValue
              ? html`<div class="text-xs text-[var(--text-dim)]">핵심 가치: <span class="text-[var(--ok)]">${keeper.primaryValue}</span></div>`
              : null}
            ${keeper.skill_primary
              ? html`<div class="text-xs text-[var(--text-dim)] mt-1.5">
                  스킬 경로: <span class="text-[var(--cyan)]">${keeper.skill_primary}</span>
                </div>`
              : null}
            ${keeper.skill_reason
              ? html`<div class="text-xs text-[var(--text-dim)] mt-1">${keeper.skill_reason}</div>`
              : null}
            ${keeper.last_heartbeat
              ? html`<div class="text-xs text-[var(--text-dim)] mt-1.5">
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
            <div class="flex flex-col gap-1.5">
              <div class="keeper-signal-row rounded-lg">
                <span>Context source</span>
                <strong>${keeper.context_source ?? keeper.context?.source ?? '-'}</strong>
              </div>
              <div class="keeper-signal-row rounded-lg">
                <span>Context tokens</span>
                <strong>
                  ${keeper.context_tokens ?? keeper.context?.context_tokens ?? '-'}
                  /
                  ${keeper.context_max ?? keeper.context?.context_max ?? '-'}
                </strong>
              </div>
              ${keeper.memory_recent_note
                ? html`
                  <div class="keeper-memory-note rounded-lg">
                    ${keeper.memory_recent_note}
                  </div>
                `
                : html`<div class="empty-state text-center border border-dashed border-[var(--card-border)] rounded-[10px] py-[22px] px-4 text-[color:var(--text-muted)] text-xs">No recent memory note</div>`}
            </div>
          <//>
        </div>
      </div>
    </div>
  `
}
