// Keeper detail overlay — full keeper info with KPIs, field dictionary,
// memory, conversations, equipment, relationships, handoff timeline
// Redesigned: professional dashboard-grade layout with Tailwind inline styles.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { runOperatorAction } from '../api'
import { TimeAgo } from './common/time-ago'
import { StatusBadge } from './common/status-badge'
import type { Keeper, Task } from '../types'
import { invalidateDashboardCache, refreshDashboard, tasks } from '../store'
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

// ── Helpers ───────────────────────────────────────────────

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

// ── Status Badge (colored pill) ──────────────────────────

function statusColor(status: string): { bg: string; text: string; dot: string } {
  switch (status.trim().toLowerCase()) {
    case 'active':
    case 'running':
      return { bg: 'bg-[rgba(74,222,128,0.12)]', text: 'text-[#4ade80]', dot: 'bg-[#4ade80]' }
    case 'working':
      return { bg: 'bg-[rgba(74,222,128,0.12)]', text: 'text-[#7ae09a]', dot: 'bg-[#7ae09a]' }
    case 'idle':
    case 'quiet':
      return { bg: 'bg-[rgba(251,191,36,0.12)]', text: 'text-[#fbbf24]', dot: 'bg-[#fbbf24]' }
    case 'offline':
    case 'inactive':
      return { bg: 'bg-[rgba(148,163,184,0.12)]', text: 'text-[#94a3b8]', dot: 'bg-[#64748b]' }
    case 'error':
    case 'critical':
      return { bg: 'bg-[rgba(239,68,68,0.12)]', text: 'text-[#ef4444]', dot: 'bg-[#ef4444]' }
    default:
      return { bg: 'bg-[rgba(138,163,211,0.1)]', text: 'text-[#86a0cf]', dot: 'bg-[#86a0cf]' }
  }
}

function KeeperStatusPill({ status }: { status: string }) {
  const c = statusColor(status)
  return html`
    <span class="inline-flex items-center gap-1.5 py-1 px-3 rounded-full text-xs font-medium ${c.bg} ${c.text}">
      <span class="size-2 rounded-full ${c.dot}"></span>
      ${status}
    </span>
  `
}

// ── Comms Panel ──────────────────────────────────────────

function KeeperCommsPanel({ keeper }: { keeper: Keeper }) {
  return html`
    <div class="border-t border-[var(--border-slate-12)] pt-5">
      <h3 class="m-0 mb-3 text-[13px] font-semibold text-[var(--text-strong)] uppercase tracking-[0.06em]">Direct Comms</h3>

      <div class="flex flex-col gap-4">
        <div class="w-full">
          <${KeeperConversationPanel}
            keeperName=${keeper.name}
            placeholder="Send a direct prompt to this keeper"
          />
        </div>

        <details class="group">
          <summary class="cursor-pointer py-2.5 px-4 text-xs text-[var(--text-muted)] tracking-wider uppercase list-none select-none rounded-lg hover:bg-[var(--white-3)] transition-colors">Runtime diagnostics</summary>
          <div class="flex flex-col gap-3 px-4 pb-4 pt-2">
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

// ── Section Card (detail page variant) ───────────────────

function SectionCard({ title, children }: { title: string; children: preact.ComponentChildren }) {
  return html`
    <div class="p-5 rounded-2xl border border-card-border bg-card/40 backdrop-blur-md shadow-sm hover:border-accent/30 hover:shadow-md transition-all duration-200">
      <div class="text-[11px] font-semibold uppercase tracking-widest text-text-muted mb-4 flex items-center gap-2">
        <span class="w-1.5 h-1.5 rounded-full bg-accent/50"></span>
        ${title}
      </div>
      ${children}
    </div>
  `
}

// ── Main Detail Overlay ─────────────────────────────────

export function KeeperDetailOverlay() {
  const keeper = selectedKeeper.value
  if (!keeper) return null

  return html`
    <div
      class="keeper-detail-overlay fixed inset-0 z-[60] bg-black/60 backdrop-blur-sm isolate flex items-center justify-center p-6 animate-in fade-in duration-200"
      data-testid="keeper-detail-overlay"
      onClick=${(e: Event) => {
        if ((e.target as HTMLElement).classList.contains('keeper-detail-overlay')) {
          closeKeeperDetail()
        }
      }}
    >
      <div class="w-full max-w-[1100px] max-h-[90vh] overflow-y-auto bg-[#0d1526] rounded-2xl border border-[var(--card-border)] shadow-[0_24px_64px_rgba(0,0,0,0.5)]">

        ${'' /* ── Sticky Header ── */}
        <div class="sticky top-0 z-10 flex items-center justify-between px-6 py-4 border-b border-[var(--card-border)] bg-[rgba(13,21,38,0.97)] backdrop-blur-md rounded-t-2xl">
          <div class="flex items-center gap-4">
            <div class="size-12 rounded-xl bg-[var(--white-5)] border border-[var(--white-8)] flex items-center justify-center text-2xl">${keeper.emoji}</div>
            <div class="flex flex-col gap-0.5">
              <div class="flex items-center gap-2.5">
                <h2 class="m-0 text-lg font-semibold text-[var(--text-strong)]">${keeper.name}</h2>
                <${KeeperStatusPill} status=${keeper.status} />
                ${keeper.model ? html`
                  <span class="inline-flex items-center py-0.5 px-2 rounded text-[10px] font-mono bg-[var(--accent-12)] text-[#9ad9ff] border border-[rgba(71,184,255,0.2)]">${keeper.model}</span>
                ` : null}
              </div>
              ${keeper.koreanName ? html`<span class="text-xs text-[var(--text-muted)]">${keeper.koreanName}</span>` : null}
            </div>
          </div>
          <button
            onClick=${() => closeKeeperDetail()}
            class="flex items-center justify-center size-8 rounded-lg border border-[var(--card-border)] bg-[var(--white-3)] text-[var(--text-muted)] hover:text-[var(--text-strong)] hover:bg-[var(--white-8)] transition-colors cursor-pointer text-sm"
            aria-label="Close"
          >
            <svg width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><line x1="2" y1="2" x2="12" y2="12"/><line x1="12" y1="2" x2="2" y2="12"/></svg>
          </button>
        </div>

        ${'' /* ── Body ── */}
        <div class="p-6 flex flex-col gap-6">

        ${'' /* ── Pipeline stage indicator ── */}
        <${PipelineStageBar} stage=${keeper.pipeline_stage} />

        ${'' /* ── Assigned tasks (keeper = agent, may have claimed tasks) ── */}
        ${(() => {
          const agentName = keeper.agent_name ?? keeper.name
          const ownedTasks: Task[] = tasks.value.filter(
            (t: Task) => t.assignee === agentName || t.assignee === keeper.name
          )
          return ownedTasks.length > 0 ? html`
            <${SectionCard} title="할당된 작업 (${ownedTasks.length})">
              <div class="flex flex-col gap-2">
                ${ownedTasks.map((t: Task) => html`
                  <div key=${t.id} class="flex items-center gap-3 px-3 py-2.5 rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] hover:bg-[var(--white-5)] transition-colors">
                    <span class="text-[10px] font-medium py-1 px-2.5 border border-[rgba(71,184,255,0.2)] bg-[rgba(71,184,255,0.08)] text-[#9ad9ff] whitespace-nowrap rounded-md">${t.id}</span>
                    <span class="flex-1 text-[13px] text-[var(--text-strong)] font-medium truncate">${t.title}</span>
                    <${StatusBadge} status=${t.status} />
                  </div>
                `)}
              </div>
            <//>
          ` : null
        })()}

        ${'' /* ── KPIs ── */}
        <${KpiGrid} keeper=${keeper} />

        ${'' /* ── Context chart ── */}
        <${ContextChart} keeper=${keeper} />

        ${'' /* ── Direct conversation ── */}
        <${KeeperCommsPanel} keeper=${keeper} />

        ${'' /* ── Detail sections grid ── */}
        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">

          <${SectionCard} title="Field Dictionary">
            <${FieldDictionary} keeper=${keeper} />
          <//>

          <${SectionCard} title="Profile">
            <${TraitsList} traits=${keeper.traits ?? []} label="Traits" />
            <${TraitsList} traits=${keeper.interests ?? []} label="Interests" />
            ${keeper.primaryValue
              ? html`<div class="flex items-center gap-2 mt-3 text-xs text-[var(--text-muted)]">
                  <span class="text-[var(--text-muted)]">Core value:</span>
                  <span class="font-medium text-[var(--ok)]">${keeper.primaryValue}</span>
                </div>`
              : null}
            ${keeper.skill_primary
              ? html`<div class="flex items-center gap-2 mt-2 text-xs text-[var(--text-muted)]">
                  <span>Skill path:</span>
                  <span class="font-medium text-[var(--cyan)]">${keeper.skill_primary}</span>
                </div>`
              : null}
            ${keeper.skill_reason
              ? html`<div class="text-[11px] text-[var(--text-muted)] mt-1 leading-relaxed">${keeper.skill_reason}</div>`
              : null}
            ${keeper.last_heartbeat
              ? html`<div class="flex items-center gap-2 mt-2 text-xs text-[var(--text-muted)]">
                  <span>Last heartbeat:</span>
                  <${TimeAgo} timestamp=${keeper.last_heartbeat} />
                </div>`
              : null}
          <//>

          ${keeper.autonomy_level
            ? html`
              <${SectionCard} title="Autonomy">
                <${AutonomyMeter} keeper=${keeper} />
              <//>
            `
            : null}

          ${keeper.trpg_stats
            ? html`
              <${SectionCard} title="TRPG Stats">
                <${TrpgStats} stats=${keeper.trpg_stats} />
              <//>
            `
            : null}

          ${keeper.inventory && keeper.inventory.length > 0
            ? html`
              <${SectionCard} title="Equipment (${keeper.inventory.length})">
                <${EquipmentList} items=${keeper.inventory} />
              <//>
            `
            : null}

          ${keeper.relationships && Object.keys(keeper.relationships).length > 0
            ? html`
              <${SectionCard} title="Relationships (${Object.keys(keeper.relationships).length})">
                <${RelationshipList} rels=${keeper.relationships} />
              <//>
            `
            : null}

          <${SectionCard} title="Runtime Signals">
            <${RuntimeSignals} keeper=${keeper} />
          <//>

          <${SectionCard} title="Neighborhood & Tool Audit">
            <${KeeperNeighborhood} keeper=${keeper} />
          <//>

          <${SectionCard} title="Config">
            <${KeeperConfigPanel} keeperName=${keeper.name} />
          <//>

          <${SectionCard} title="Memory & Context">
            <div class="flex flex-col gap-2">
              <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]">
                <span class="text-xs text-[var(--text-muted)]">Context source</span>
                <span class="text-xs font-medium text-[var(--text-strong)]">${keeper.context_source ?? keeper.context?.source ?? '-'}</span>
              </div>
              <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]">
                <span class="text-xs text-[var(--text-muted)]">Context tokens</span>
                <span class="text-xs font-medium text-[var(--text-strong)]">
                  ${keeper.context_tokens ?? keeper.context?.context_tokens ?? '-'}
                  /
                  ${keeper.context_max ?? keeper.context?.context_max ?? '-'}
                </span>
              </div>
              ${keeper.memory_recent_note
                ? html`
                  <div class="py-2 px-3 rounded-lg bg-[rgba(167,139,250,0.06)] border border-[rgba(167,139,250,0.12)] text-xs text-[var(--text-body)] leading-relaxed">
                    ${keeper.memory_recent_note}
                  </div>
                `
                : html`<div class="py-2 px-3 text-xs text-[var(--text-muted)] italic">No recent memory note</div>`}
            </div>
          <//>
        </div>
        </div>
      </div>
    </div>
  `
}
