import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import type {
  ChainHistoryEventSummary,
  CommandPlaneAlert,
  CommandPlaneChainOverlay,
  CommandPlaneChainRunNode,
  CommandPlaneCapacityRow,
  CommandPlaneDecisionRecord,
  CommandPlaneDetachmentCard,
  CommandPlaneHelpPath,
  CommandPlaneHelpPitfall,
  CommandPlaneHelpStep,
  CommandPlaneOperationCard,
  CommandPlaneSurface,
  CommandPlaneSwarmFlag,
  CommandPlaneSwarmGap,
  CommandPlaneSwarmLane,
  CommandPlaneSwarmProof,
  CommandPlaneSwarmTimelineEvent,
  CommandPlaneSwarmBlocker,
  CommandPlaneSwarmChecklistItem,
  CommandPlaneSwarmWorker,
  CommandPlaneTraceEvent,
  CommandPlaneTreeNode,
  Task,
} from '../types'
import {
  approveCommandPlaneDecision,
  commandPlaneActionBusy,
  commandPlaneActionError,
  clearCommandPlaneChainRun,
  commandPlaneChainError,
  commandPlaneChainFocusOperationId,
  commandPlaneChainLoading,
  commandPlaneChainRun,
  commandPlaneChainRunError,
  commandPlaneChainRunLoading,
  commandPlaneChainSummary,
  commandPlaneError,
  commandPlaneDetailError,
  commandPlaneDetailLoading,
  commandPlaneHelp,
  commandPlaneHelpError,
  commandPlaneHelpLoading,
  commandPlaneLoading,
  commandPlaneSummary,
  commandPlaneSnapshot,
  commandPlaneSwarm,
  commandPlaneSwarmError,
  commandPlaneSwarmLoading,
  commandPlaneSurface,
  denyCommandPlaneDecision,
  focusCommandPlaneChainOperation,
  loadCommandPlaneChainRun,
  pauseCommandPlaneOperation,
  recallCommandPlaneOperation,
  refreshCommandPlaneCurrentSurface,
  refreshCommandPlaneChainSummary,
  refreshCommandPlaneHelp,
  refreshCommandPlaneSwarm,
  runCommandPlaneDispatchTick,
  resumeCommandPlaneOperation,
  setCommandPlaneSurface,
  toggleCommandPlaneFreeze,
  toggleCommandPlaneKillSwitch,
} from '../command-store'
import { agents, serverStatus, tasks } from '../store'
import { navigate, route } from '../router'

function prettyJson(value: unknown): string {
  if (value === null || value === undefined) return ''
  if (typeof value === 'string') return value
  try {
    return JSON.stringify(value, null, 2)
  } catch {
    return String(value)
  }
}

function relativeTime(iso?: string | null): string {
  if (!iso) return 'n/a'
  const ts = Date.parse(iso)
  if (Number.isNaN(ts)) return iso
  const deltaSec = Math.max(0, Math.round((Date.now() - ts) / 1000))
  if (deltaSec < 60) return `${deltaSec}s ago`
  if (deltaSec < 3600) return `${Math.round(deltaSec / 60)}m ago`
  if (deltaSec < 86400) return `${Math.round(deltaSec / 3600)}h ago`
  return `${Math.round(deltaSec / 86400)}d ago`
}

function expiryTone(iso?: string | null): string {
  if (!iso) return 'warn'
  const ts = Date.parse(iso)
  if (Number.isNaN(ts)) return 'warn'
  return ts <= Date.now() ? 'bad' : 'ok'
}

function deadlineLabel(iso?: string | null): string {
  if (!iso) return 'n/a'
  const ts = Date.parse(iso)
  if (Number.isNaN(ts)) return iso
  const deltaSec = Math.round((ts - Date.now()) / 1000)
  if (deltaSec <= 0) return 'expired'
  if (deltaSec < 60) return `in ${deltaSec}s`
  if (deltaSec < 3600) return `in ${Math.round(deltaSec / 60)}m`
  if (deltaSec < 86400) return `in ${Math.round(deltaSec / 3600)}h`
  return `in ${Math.round(deltaSec / 86400)}d`
}

function toneClass(tone?: string | null): string {
  if (tone === 'bad') return 'bad'
  if (tone === 'warn' || tone === 'pending') return 'warn'
  return 'ok'
}

type MermaidApi = typeof import('mermaid')['default']

let mermaidConfigured = false
let mermaidRenderCount = 0
let mermaidPromise: Promise<MermaidApi> | null = null

async function getMermaid(): Promise<MermaidApi> {
  if (!mermaidPromise) {
    mermaidPromise = import('mermaid').then(module => module.default)
  }
  const mermaid = await mermaidPromise
  if (mermaidConfigured) return mermaid
  mermaid.initialize({
    startOnLoad: false,
    theme: 'dark',
    securityLevel: 'loose',
  })
  mermaidConfigured = true
  return mermaid
}

function chainStatusTone(status?: string | null): string {
  if (!status) return 'warn'
  const lowered = status.toLowerCase()
  if (
    lowered.includes('failed')
    || lowered.includes('error')
    || lowered.includes('disconnected')
    || lowered.includes('stopped')
  ) {
    return 'bad'
  }
  if (
    lowered.includes('running')
    || lowered.includes('active')
    || lowered.includes('degraded')
    || lowered.includes('pending')
  ) {
    return 'warn'
  }
  return 'ok'
}

function formatPercent(value?: number | null): string {
  if (typeof value !== 'number' || !Number.isFinite(value)) return 'n/a'
  return `${Math.round(value * 100)}%`
}

function formatElapsed(value?: number | null): string {
  if (typeof value !== 'number' || !Number.isFinite(value)) return 'n/a'
  if (value < 60) return `${Math.round(value)}s`
  if (value < 3600) return `${Math.round(value / 60)}m`
  return `${Math.round(value / 3600)}h`
}

function historySummary(history?: ChainHistoryEventSummary | null): string {
  if (!history) return 'No recent chain history'
  const pieces = [history.event]
  if (typeof history.duration_ms === 'number') pieces.push(`${history.duration_ms}ms`)
  if (typeof history.tokens === 'number') pieces.push(`${history.tokens} tokens`)
  if (history.message) pieces.push(history.message)
  return pieces.join(' · ')
}

const COMMAND_SURFACES: CommandPlaneSurface[] = ['operations', 'chains', 'topology', 'alerts', 'trace', 'control']
const CHAIN_SSE_EVENT_TYPES = ['chain_start', 'node_start', 'node_complete', 'chain_complete', 'chain_error']

function isCommandSurface(value: string | undefined): value is CommandPlaneSurface {
  return !!value && COMMAND_SURFACES.includes(value as CommandPlaneSurface)
}

function chainEventsUrl(): string {
  const query = new URLSearchParams(window.location.search)
  const params = new URLSearchParams()
  const agent = query.get('agent') ?? query.get('agent_name')
  const token = query.get('token')
  if (agent) params.set('agent', agent)
  if (token) params.set('token', token)
  return params.toString() ? `/api/v1/chains/events?${params.toString()}` : '/api/v1/chains/events'
}

function unitKindLabel(kind: string): string {
  switch (kind) {
    case 'company':
      return '중대 / Company'
    case 'platoon':
      return '소대 / Platoon'
    case 'squad':
      return '분대 / Squad'
    case 'agent':
      return '에이전트 / Agent'
    default:
      return kind
  }
}

function actionDisabled(key: string): boolean {
  return commandPlaneActionBusy.value === key
}

function currentCommandPlaneSummary() {
  return commandPlaneSummary.value
}

function dashboardActorName(): string | null {
  if (typeof window === 'undefined') return null
  const params = new URLSearchParams(window.location.search)
  const value = params.get('agent') ?? params.get('agent_name')
  if (!value) return null
  const trimmed = value.trim()
  return trimmed === '' ? null : trimmed
}

function dashboardSwarmRunId(): string | null {
  if (typeof window === 'undefined') return null
  const params = new URLSearchParams(window.location.search)
  const value = params.get('run_id')
  if (!value) return null
  const trimmed = value.trim()
  return trimmed === '' ? null : trimmed
}

function lastSeenAgeSeconds(iso?: string | null): number | null {
  if (!iso) return null
  const ts = Date.parse(iso)
  if (Number.isNaN(ts)) return null
  return Math.max(0, Math.round((Date.now() - ts) / 1000))
}

function isActiveTask(task: Task): boolean {
  return task.status === 'claimed' || task.status === 'in_progress'
}

function findHelpStep(toolName: string): CommandPlaneHelpStep | null {
  const help = commandPlaneHelp.value
  if (!help) return null
  for (const path of help.golden_paths) {
    const matched = path.steps.find(step => step.tool === toolName)
    if (matched) return matched
  }
  return null
}

function findHelpPath(pathId: string): CommandPlaneHelpPath | null {
  return commandPlaneHelp.value?.golden_paths.find(path => path.id === pathId) ?? null
}

function relevantPitfalls(ids: string[]): CommandPlaneHelpPitfall[] {
  const help = commandPlaneHelp.value
  if (!help) return []
  const wanted = new Set(ids)
  return help.pitfalls.filter(pitfall => wanted.has(pitfall.id))
}

async function fire(action: () => Promise<void>) {
  try {
    await action()
  } catch {
    // Error state is already captured in the store.
  }
}

function SummaryCards() {
  const summary = currentCommandPlaneSummary()
  const chainSummary = commandPlaneChainSummary.value
  const topology = summary?.topology.summary
  const ops = summary?.operations.summary
  const microarch = summary?.operations.microarch
  const decisions = summary?.decisions.summary
  const alerts = summary?.alerts.summary
  const routing = microarch?.signals?.routing_confidence
  const issuePressure = microarch?.signals?.issue_pressure
  const search = microarch?.search_fabric
  const cache = microarch?.cache
  return html`
    <div class="command-summary-grid">
      <div class="monitor-stat-card"><span>Units</span><strong>${topology?.total_units ?? 0}</strong><small>${topology?.managed_unit_count ?? 0} managed</small></div>
      <div class="monitor-stat-card"><span>Ops</span><strong>${ops?.active ?? 0}</strong><small>${summary?.detachments.summary?.active ?? 0} detachments</small></div>
      <div class="monitor-stat-card"><span>Approvals</span><strong>${decisions?.pending ?? 0}</strong><small>${decisions?.total ?? 0} tracked</small></div>
      <div class="monitor-stat-card"><span>Alerts</span><strong>${alerts?.bad ?? 0}</strong><small>${alerts?.warn ?? 0} warn</small></div>
      <div class="monitor-stat-card"><span>Chains</span><strong>${chainSummary?.summary?.active_chains ?? 0}</strong><small>${chainSummary?.summary?.linked_operations ?? 0} linked</small></div>
      <div class="monitor-stat-card"><span>Routing</span><strong>${search?.best_first_operations ?? 0}</strong><small>${routing?.tone ?? 'n/a'} · score ${search?.avg_best_score?.toFixed(1) ?? '0.0'}</small></div>
      <div class="monitor-stat-card"><span>Microarch</span><strong>${issuePressure?.pending_ops ?? 0}</strong><small>${cache?.l1_hit_rate != null ? `${formatPercent(cache.l1_hit_rate)} L1 hit` : 'no cache data'} · ${issuePressure?.tone ?? 'n/a'}</small></div>
    </div>
  `
}

function swarmLaneTone(lane: CommandPlaneSwarmLane): string {
  if (lane.motion_state === 'stalled') return 'bad'
  if (lane.hard_flags.some(flag => flag.severity === 'bad')) return 'bad'
  if (lane.motion_state === 'waiting') return 'warn'
  if (lane.hard_flags.some(flag => flag.severity === 'warn')) return 'warn'
  return 'ok'
}

function SwarmLaneCard({ lane }: { lane: CommandPlaneSwarmLane }) {
  const counts = lane.counts ?? {}
  const tone = swarmLaneTone(lane)
  return html`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${lane.label}</strong>
          <div class="command-card-sub">${lane.source_of_truth}</div>
        </div>
        <div class="command-tag-row">
          <span class="command-chip ${toneClass(tone)}">${lane.phase}</span>
          <span class="command-chip ${toneClass(tone)}">${lane.motion_state}</span>
          <span class="command-chip">${relativeTime(lane.last_movement_at)}</span>
        </div>
      </div>
      <div class="command-card-grid">
        <span>Movement</span><span>${lane.movement_reason}</span>
        <span>Step</span><span>${lane.current_step}</span>
        <span>Counts</span><span>${counts.operations ?? 0} ops · ${counts.detachments ?? 0} dets · ${counts.workers ?? 0} workers · ${counts.approvals ?? 0} approvals · ${counts.alerts ?? 0} alerts</span>
      </div>
      ${lane.blockers.length > 0
        ? html`<div class="command-card-foot">Blockers: ${lane.blockers.join(' · ')}</div>`
        : null}
      ${lane.hard_flags.length > 0
        ? html`
            <div class="command-tag-row">
              ${lane.hard_flags.map((flag: CommandPlaneSwarmFlag) => html`<span class="command-tag ${toneClass(flag.severity)}">${flag.code}</span>`)}
            </div>
          `
        : null}
    </article>
  `
}

function SwarmTimelineRow({ event }: { event: CommandPlaneSwarmTimelineEvent }) {
  return html`
    <div class="command-trace-row">
      <div class="command-trace-head">
        <strong>${event.title}</strong>
        <span class="command-chip ${toneClass(event.tone)}">${event.lane_id}</span>
        <span class="command-chip">${event.kind}</span>
        <span class="command-chip">${relativeTime(event.timestamp)}</span>
      </div>
      <div class="command-card-sub">${event.source}</div>
      <div class="command-card-foot">${event.detail}</div>
    </div>
  `
}

function SwarmGapRow({ gap }: { gap: CommandPlaneSwarmGap }) {
  return html`
    <div class="command-guide-inline">
      <div class="command-guide-head">
        <strong>${gap.code}</strong>
        <span class="command-chip ${toneClass(gap.severity)}">${gap.count}</span>
      </div>
      <p>${gap.summary}</p>
      ${gap.lane_ids.length > 0
        ? html`<div class="command-tag-row">${gap.lane_ids.map(laneId => html`<span class="command-tag">${laneId}</span>`)}</div>`
        : null}
    </div>
  `
}

function SwarmProofPanel({ proof }: { proof?: CommandPlaneSwarmProof }) {
  const tone =
    proof?.status === 'missing'
      ? 'warn'
      : proof?.pass === false
        ? 'bad'
        : proof?.pass === true
          ? 'ok'
          : 'warn'
  return html`
    <div class="command-guide-card ${toneClass(tone)}">
      <div class="command-guide-head">
        <strong>Hot Proof</strong>
        <span class="command-chip ${toneClass(tone)}">${proof?.status ?? 'missing'}</span>
      </div>
      ${proof
        ? html`
            <div class="command-card-grid">
              <span>Source</span><span>${proof.source}</span>
              <span>Run</span><span>${proof.run_id ?? 'n/a'}</span>
              <span>Captured</span><span>${relativeTime(proof.captured_at)}</span>
              <span>Pass</span><span>${proof.pass == null ? 'n/a' : proof.pass ? 'yes' : 'no'}</span>
              <span>Peak Hot Slots</span><span>${proof.peak_hot_slots ?? 'n/a'}</span>
              <span>Ctx / Slot</span><span>${proof.ctx_per_slot ?? 'n/a'}</span>
              <span>Workers</span><span>${proof.workers.expected ?? 'n/a'} expected · ${proof.workers.done ?? 'n/a'} done · ${proof.workers.final ?? 'n/a'} final</span>
            </div>
            ${proof.artifact_ref
              ? html`<div class="command-card-foot">${proof.artifact_ref}</div>`
              : null}
            ${proof.missing_reason
              ? html`<p>${proof.missing_reason}</p>`
              : null}
          `
        : html`<p>No swarm proof is available yet.</p>`}
    </div>
  `
}

function SwarmPanel() {
  const summary = currentCommandPlaneSummary()
  const swarm = summary?.swarm_status
  const proof = summary?.swarm_proof
  const lanes = swarm?.lanes.filter(lane => lane.present) ?? []
  const gaps = swarm?.gaps.items ?? []
  const timeline = swarm?.timeline.slice(0, 6) ?? []
  const overview = swarm?.overview
  const recommendation = swarm?.recommended_next_action

  return html`
    <section class="card command-section">
      <div class="card-title">Swarm</div>
      ${swarm
        ? html`
            <div class="command-summary-grid command-swarm-summary">
              <div class="monitor-stat-card"><span>Active Lanes</span><strong>${overview?.active_lanes ?? 0}</strong><small>${overview?.moving_lanes ?? 0} moving</small></div>
              <div class="monitor-stat-card"><span>Stalled</span><strong>${overview?.stalled_lanes ?? 0}</strong><small>${overview?.projected_lanes ?? 0} projected</small></div>
              <div class="monitor-stat-card"><span>Last Movement</span><strong>${relativeTime(overview?.last_movement_at)}</strong><small>${swarm.generated_at ? `snapshot ${relativeTime(swarm.generated_at)}` : 'snapshot now'}</small></div>
              <div class="monitor-stat-card"><span>Next Action</span><strong>${recommendation?.label ?? 'Observe operator state'}</strong><small>${recommendation?.tool ?? 'masc_operator_snapshot'}</small></div>
            </div>

            <div class="command-swarm-layout">
              <div class="command-card-stack">
                ${lanes.length > 0
                  ? lanes.map(lane => html`<${SwarmLaneCard} lane=${lane} />`)
                  : html`<div class="empty-state">No active swarm lanes.</div>`}
              </div>

              <div class="command-card-stack">
                <div class="command-guide-card highlight">
                  <div class="command-guide-head">
                    <strong>${recommendation?.label ?? 'Observe operator state'}</strong>
                    <span class="command-chip">${recommendation?.lane_id ?? 'global'}</span>
                  </div>
                  <p>${recommendation?.reason ?? 'No active swarm lane is visible yet.'}</p>
                  <div class="command-card-foot">${recommendation?.tool ?? 'masc_operator_snapshot'}</div>
                </div>

                <${SwarmProofPanel} proof=${proof} />

                <div class="command-guide-card ${gaps.length > 0 ? 'warn' : 'ok'}">
                  <div class="command-guide-head">
                    <strong>Hard Gaps</strong>
                    <span class="command-chip ${toneClass(gaps.some(gap => gap.severity === 'bad') ? 'bad' : gaps.length > 0 ? 'warn' : 'ok')}">${gaps.length}</span>
                  </div>
                  ${gaps.length > 0
                    ? html`<div class="command-card-stack">${gaps.slice(0, 4).map(gap => html`<${SwarmGapRow} gap=${gap} />`)}</div>`
                    : html`<p>No hard gaps are currently visible.</p>`}
                </div>

                <div class="command-guide-card">
                  <div class="command-guide-head">
                    <strong>Movement Timeline</strong>
                    <span class="command-chip">${timeline.length}</span>
                  </div>
                  ${timeline.length > 0
                    ? html`<div class="command-card-stack">${timeline.map(event => html`<${SwarmTimelineRow} event=${event} />`)}</div>`
                    : html`<p>No recent movement events are attached yet.</p>`}
                </div>
              </div>
            </div>
          `
        : html`<div class="empty-state">Swarm status is unavailable.</div>`}
    </section>
  `
}

function SurfaceTabs() {
  return html`
    <div class="command-surface-tabs">
      ${COMMAND_SURFACES.map(surface => html`
        <button
          class="command-surface-tab ${commandPlaneSurface.value === surface ? 'active' : ''}"
          onClick=${() => setCommandPlaneSurface(surface)}
        >
          ${surface}
        </button>
      `)}
    </div>
  `
}

function GuidedPanel() {
  const summary = currentCommandPlaneSummary()
  const snapshot = commandPlaneSnapshot.value
  const status = serverStatus.value
  const actorName = dashboardActorName()
  const actor = actorName ? agents.value.find(item => item.name === actorName) ?? null : null
  const actorTasks = actorName ? tasks.value.filter(task => task.assignee === actorName && isActiveTask(task)) : []
  const activeOps = summary?.operations.summary?.active ?? 0
  const detachments = summary?.detachments.summary?.total ?? 0
  const pendingDecisions = summary?.decisions.summary?.pending ?? 0
  const stalledDetachment = snapshot?.detachments.detachments.find(card => {
    const heartbeatDeadline = card.detachment.heartbeat_deadline
    const deadlineTs = heartbeatDeadline ? Date.parse(heartbeatDeadline) : Number.NaN
    return card.detachment.status === 'stalled' || (!Number.isNaN(deadlineTs) && deadlineTs <= Date.now())
  })
  const badAlert = snapshot?.alerts.alerts.find(alert => alert.severity === 'bad')
  const roomReady = Boolean(status?.room || status?.project)
  const currentTask = actor?.current_task ?? null
  const lastSeenAge = lastSeenAgeSeconds(actor?.last_seen)
  const heartbeatFresh = lastSeenAge != null ? lastSeenAge <= 120 : null

  const readiness = [
    roomReady
      ? {
          title: 'Room readiness',
          tone: 'ok',
          detail: `${status?.room ?? status?.project ?? 'unknown'} · base ${status?.room_base_path ?? 'n/a'}`,
          tool: 'masc_status',
        }
      : {
          title: 'Room readiness',
          tone: 'bad',
          detail: 'No room snapshot yet. Set room to repo root before joining.',
          tool: 'masc_set_room',
        },
    !actorName
      ? {
          title: 'Task readiness',
          tone: 'warn',
          detail: 'No ?agent= query param. Dashboard can show room health but not agent-specific next steps.',
          tool: 'masc_join',
        }
      : !actor
        ? {
            title: 'Task readiness',
            tone: 'bad',
            detail: `${actorName} is not visible in the room roster.`,
            tool: 'masc_join',
          }
        : actorTasks.length === 0
          ? {
              title: 'Task readiness',
              tone: 'warn',
              detail: `${actorName} has no claimed task. Claim one or create one first.`,
              tool: tasks.value.length > 0 ? 'masc_claim' : 'masc_add_task',
            }
          : !currentTask
            ? {
                title: 'Task readiness',
                tone: 'bad',
                detail: `${actorName} has a claimed task but no session current_task binding.`,
                tool: 'masc_plan_set_task',
              }
            : heartbeatFresh === false
              ? {
                  title: 'Task readiness',
                  tone: 'warn',
                  detail: `${actorName} current_task=${currentTask}, but heartbeat is stale (${lastSeenAge}s).`,
                  tool: 'masc_heartbeat',
                }
              : {
                  title: 'Task readiness',
                  tone: 'ok',
                  detail: `${actorName} current_task=${currentTask}${lastSeenAge != null ? ` · last seen ${lastSeenAge}s ago` : ''}`,
                  tool: 'masc_plan_get_task',
                },
    !summary || (summary.topology.summary?.managed_unit_count ?? 0) === 0
      ? {
          title: 'Operation readiness',
          tone: 'warn',
          detail: 'No managed units defined yet. CPv2 benchmark cannot start before hierarchy exists.',
          tool: 'masc_unit_define',
        }
      : activeOps === 0
        ? {
            title: 'Operation readiness',
            tone: 'warn',
            detail: `${summary.topology.summary?.managed_unit_count ?? 0} managed units are ready, but there is no active operation.`,
            tool: 'masc_operation_start',
          }
        : {
            title: 'Operation readiness',
            tone: 'ok',
            detail: `${activeOps} active operation(s) across ${summary.topology.summary?.managed_unit_count ?? 0} managed unit(s).`,
            tool: 'masc_observe_operations',
          },
    pendingDecisions > 0
      ? {
          title: 'Dispatch readiness',
          tone: 'warn',
          detail: `${pendingDecisions} pending approval(s) are blocking strict actions.`,
          tool: 'masc_policy_approve',
        }
      : activeOps > 0 && detachments === 0
        ? {
            title: 'Dispatch readiness',
            tone: 'bad',
            detail: 'Active operation exists but no detachment has been materialized yet.',
            tool: 'masc_dispatch_tick',
          }
        : stalledDetachment || badAlert
          ? {
              title: 'Dispatch readiness',
              tone: 'warn',
              detail: `Dispatch needs reconciliation${stalledDetachment ? ` · detachment ${stalledDetachment.detachment.detachment_id} is stalled` : ''}${badAlert ? ` · alert ${badAlert.title ?? badAlert.alert_id}` : ''}${!snapshot && !stalledDetachment && !badAlert ? ' · open a detail tab to inspect the exact source.' : ''}.`,
              tool: pendingDecisions > 0 ? 'masc_policy_approve' : 'masc_dispatch_tick',
            }
          : {
              title: 'Dispatch readiness',
              tone: 'ok',
              detail: `${detachments} detachment(s) visible and no strict approval backlog${!snapshot ? ' · detail panes stay lazy until opened.' : ''}.`,
              tool: 'masc_detachment_list',
            },
  ]

  const nextTool =
    !roomReady
      ? 'masc_set_room'
      : !actorName || !actor
        ? 'masc_join'
        : actorTasks.length === 0
          ? (tasks.value.length > 0 ? 'masc_claim' : 'masc_add_task')
          : !currentTask
            ? 'masc_plan_set_task'
            : heartbeatFresh === false
              ? 'masc_heartbeat'
              : !summary || (summary.topology.summary?.managed_unit_count ?? 0) === 0
                ? 'masc_unit_define'
                : activeOps === 0
                  ? 'masc_operation_start'
                  : pendingDecisions > 0
                    ? 'masc_policy_approve'
                    : activeOps > 0 && detachments === 0
                      ? 'masc_dispatch_tick'
                      : stalledDetachment || badAlert
                        ? 'masc_dispatch_tick'
                        : 'masc_observe_traces'
  const nextStep = findHelpStep(nextTool)
  const pitfallIds =
    nextTool === 'masc_set_room'
      ? ['repo-root-room']
      : nextTool === 'masc_plan_set_task'
        ? ['claimed-not-current']
        : nextTool === 'masc_heartbeat'
          ? ['heartbeat-stale']
          : nextTool === 'masc_dispatch_tick'
            ? ['no-detachments']
            : nextTool === 'masc_policy_approve'
              ? ['pending-approval']
              : ['repo-root-room', 'claimed-not-current', 'heartbeat-stale']
  const pitfalls = relevantPitfalls(pitfallIds).slice(0, 2)
  const roomPath = findHelpPath('room_task_hygiene')
  const benchmarkPath = findHelpPath('cpv2_benchmark')
  const supervisorPath = findHelpPath('supervisor_session')
  const docs = commandPlaneHelp.value?.docs ?? []
  const renderedPaths = [roomPath, benchmarkPath, supervisorPath].filter(
    (item): item is CommandPlaneHelpPath => item !== null,
  )

  return html`
    <div class="command-guided-layout">
      <section class="card command-section">
        <div class="card-title">Immediate Actions</div>
        <div class="command-guide-card highlight command-next-step-card">
          <div class="command-guide-head">
            <strong>${nextStep?.title ?? nextTool}</strong>
            <span class="command-chip ok">${nextTool}</span>
          </div>
          <p>${nextStep?.summary ?? 'Use the next tool in the canonical flow to remove the current blocker.'}</p>
          ${nextStep?.success_signals?.length
            ? html`<div class="command-tag-row">
                ${nextStep.success_signals.map(signal => html`<span class="command-tag ok">${signal}</span>`)}
              </div>`
            : null}
        </div>

        <div class="command-readiness-list">
          ${readiness.map(item => html`
            <article class="command-readiness-row ${toneClass(item.tone)}">
              <div>
                <div class="command-readiness-title-row">
                  <strong>${item.title}</strong>
                  <span class="command-chip ${toneClass(item.tone)}">${item.tone}</span>
                </div>
                <p>${item.detail}</p>
              </div>
              <div class="command-card-foot">Next tool: ${item.tool}</div>
            </article>
          `)}
        </div>

        ${pitfalls.length > 0
          ? html`
              <div class="command-guide-card warn">
                <div class="command-guide-head">
                  <strong>Common Pitfalls</strong>
                  <span class="command-chip warn">${pitfalls.length}</span>
                </div>
                <div class="command-guide-list">
                  ${pitfalls.map(pitfall => html`
                    <article class="command-guide-inline">
                      <strong>${pitfall.title}</strong>
                      <div>${pitfall.symptom}</div>
                      <div class="command-card-sub">Fix with ${pitfall.fix_tool}: ${pitfall.fix_summary}</div>
                    </article>
                  `)}
                </div>
              </div>
            `
          : null}
      </section>

      <section class="card command-section">
        <div class="card-title">Operating Paths</div>
        ${commandPlaneHelpLoading.value
          ? html`<div class="empty-state">Loading CPv2 runbook…</div>`
          : commandPlaneHelpError.value
            ? html`<div class="empty-state error">${commandPlaneHelpError.value}</div>`
            : html`
                <div class="command-path-grid">
                  ${renderedPaths.map(path => html`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${path.title}</strong>
                        <span class="command-chip">${path.id}</span>
                      </div>
                      <p>${path.summary}</p>
                      <div class="command-card-sub">${path.when_to_use}</div>
                      <div class="command-step-list compact">
                        ${path.steps.slice(0, 4).map(step => html`
                          <div class="command-step-row">
                            <span class="command-step-tool">${step.tool}</span>
                            <span>${step.title}</span>
                          </div>
                        `)}
                      </div>
                    </article>
                  `)}
                </div>
                ${docs.length > 0
                  ? html`<div class="command-doc-links">
                      ${docs.map(doc => html`<span class="command-tag">${doc.title}: ${doc.path}</span>`)}
                    </div>`
                  : null}
              `}
      </section>
    </div>
  `
}

function SummarySurface() {
  return html`
    <${SummaryCards} />
    <div class="command-primary-layout">
      <${SwarmPanel} />
      <${GuidedPanel} />
    </div>
  `
}

function DetailLoadingState() {
  if (commandPlaneDetailLoading.value) {
    return html`<div class="empty-state">Loading command-plane detail…</div>`
  }
  if (commandPlaneDetailError.value) {
    return html`<div class="empty-state error">${commandPlaneDetailError.value}</div>`
  }
  return html`<div class="empty-state">Select a surface to load command-plane detail.</div>`
}

function TopologyNode({ node, depth = 0 }: { node: CommandPlaneTreeNode; depth?: number }) {
  const rosterLive = node.roster_live ?? 0
  const rosterTotal = node.roster_total ?? node.unit.roster.length
  const activeOps = node.active_operation_count ?? 0
  const policy = node.unit.policy
  return html`
    <div class="command-tree-node depth-${Math.min(depth, 3)}">
      <div class="command-tree-head">
        <div>
          <div class="command-tree-title-row">
            <strong>${node.unit.label}</strong>
            <span class="command-chip">${unitKindLabel(node.unit.kind)}</span>
            <span class="command-chip ${toneClass(node.health)}">${node.health ?? 'ok'}</span>
            ${policy?.frozen ? html`<span class="command-chip warn">frozen</span>` : null}
            ${policy?.kill_switch ? html`<span class="command-chip bad">kill-switch</span>` : null}
          </div>
          <div class="command-tree-meta">
            <span>ID ${node.unit.unit_id}</span>
            <span>Leader ${node.unit.leader_id ?? 'unassigned'} / ${node.leader_status ?? 'unknown'}</span>
            <span>Roster ${rosterLive}/${rosterTotal}</span>
            <span>Ops ${activeOps}</span>
            <span>Autonomy ${policy?.autonomy_level ?? 'n/a'}</span>
          </div>
          ${node.reasons && node.reasons.length > 0
            ? html`<div class="command-tag-row">
                ${node.reasons.map(reason => html`<span class="command-tag warn">${reason}</span>`)}
              </div>`
            : null}
        </div>
      </div>
      ${node.children.length > 0
        ? html`<div class="command-tree-children">
            ${node.children.map(child => html`<${TopologyNode} node=${child} depth=${depth + 1} />`)}
          </div>`
        : null}
    </div>
  `
}

function MermaidGraph({ source }: { source: string }) {
  const hostRef = useRef<HTMLDivElement | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    const host = hostRef.current
    if (!host) return undefined
    host.innerHTML = ''
    setError(null)

    const render = async () => {
      try {
        const mermaid = await getMermaid()
        const { svg } = await mermaid.render(`command-chain-${++mermaidRenderCount}`, source)
        if (cancelled || !hostRef.current) return
        hostRef.current.innerHTML = svg
      } catch (err) {
        if (cancelled) return
        setError(err instanceof Error ? err.message : 'Mermaid render failed')
      }
    }

    void render()
    return () => {
      cancelled = true
      if (hostRef.current) hostRef.current.innerHTML = ''
    }
  }, [source])

  return html`
    <div class="command-chain-graph-shell">
      ${error ? html`<div class="empty-state error">${error}</div>` : null}
      <div class="command-chain-graph" ref=${hostRef}></div>
    </div>
  `
}

function ChainOperationListItem(
  { overlay, selected, onSelect }: { overlay: CommandPlaneChainOverlay; selected: boolean; onSelect: () => void },
) {
  const chain = overlay.operation.chain
  const runtime = overlay.runtime
  return html`
    <button class="command-chain-item ${selected ? 'selected' : ''}" onClick=${onSelect}>
      <div class="command-card-head">
        <div>
          <strong>${overlay.operation.objective}</strong>
          <div class="command-card-sub">${overlay.operation.operation_id}</div>
        </div>
        <span class="command-chip ${chainStatusTone(chain?.status)}">${chain?.status ?? overlay.operation.status}</span>
      </div>
      <div class="command-tag-row">
        <span class="command-tag">${chain?.kind ?? 'chain_dsl'}</span>
        ${chain?.chain_id ? html`<span class="command-tag">${chain.chain_id}</span>` : null}
        ${runtime ? html`<span class="command-tag ${chainStatusTone(chain?.status)}">${formatPercent(runtime.progress)} progress</span>` : null}
      </div>
      <div class="command-card-sub">${historySummary(overlay.history)}</div>
    </button>
  `
}

function ChainHistoryRow({ item }: { item: ChainHistoryEventSummary }) {
  return html`
    <article class="command-chain-history-row">
      <div class="command-guide-head">
        <strong>${item.chain_id ?? 'unknown-chain'}</strong>
        <span class="command-chip ${chainStatusTone(item.event)}">${item.event}</span>
      </div>
      <div class="command-card-sub">${relativeTime(item.timestamp)}</div>
      <div class="command-card-sub">${historySummary(item)}</div>
    </article>
  `
}

function ChainRunNodeRow({ node }: { node: CommandPlaneChainRunNode }) {
  return html`
    <article class="command-chain-node-row">
      <div class="command-guide-head">
        <strong>${node.id}</strong>
        <span class="command-chip ${chainStatusTone(node.status)}">${node.status ?? 'unknown'}</span>
      </div>
      <div class="command-card-sub">
        ${node.type ?? 'node'}
        ${typeof node.duration_ms === 'number' ? ` · ${node.duration_ms}ms` : ''}
      </div>
      ${node.error ? html`<div class="command-card-sub error-text">${node.error}</div>` : null}
    </article>
  `
}

function OperationCard({ card }: { card: CommandPlaneOperationCard }) {
  const op = card.operation
  const pauseKey = `pause:${op.operation_id}`
  const resumeKey = `resume:${op.operation_id}`
  const recallKey = `recall:${op.operation_id}`
  const chain = op.chain
  return html`
    <article class="command-card">
      <div class="command-card-head">
        <div>
          <strong>${op.objective}</strong>
          <div class="command-card-sub">${op.operation_id}</div>
        </div>
        <span class="command-chip ${toneClass(op.status === 'active' ? 'ok' : op.status === 'paused' ? 'warn' : op.status === 'failed' ? 'bad' : 'ok')}">${op.status}</span>
      </div>
      <div class="command-card-grid">
        <span>Unit</span><span>${card.assigned_unit_label ?? op.assigned_unit_id}</span>
        <span>Trace</span><span class="mono">${op.trace_id}</span>
        <span>Autonomy</span><span>${op.autonomy_level ?? 'n/a'}</span>
        <span>Budget</span><span>${op.budget_class ?? 'standard'}</span>
        <span>Source</span><span>${op.source ?? 'managed'}</span>
        <span>Updated</span><span>${relativeTime(op.updated_at)}</span>
      </div>
      ${chain
        ? html`
            <div class="command-tag-row">
              <span class="command-tag">${chain.kind}</span>
              <span class="command-tag ${chainStatusTone(chain.status)}">${chain.status}</span>
              ${chain.chain_id ? html`<span class="command-tag">${chain.chain_id}</span>` : null}
              ${chain.run_id ? html`<span class="command-tag">run ${chain.run_id}</span>` : null}
            </div>
          `
        : null}
      ${op.checkpoint_ref
        ? html`<div class="command-card-foot">Checkpoint ${op.checkpoint_ref}</div>`
        : null}
      <div class="command-action-row">
        ${chain
          ? html`
              <button
                class="control-btn ghost"
                onClick=${() => {
                  focusCommandPlaneChainOperation(op.operation_id)
                  setCommandPlaneSurface('chains')
                  navigate('command', { surface: 'chains', operation: op.operation_id })
                }}
              >
                Open Chain
              </button>
            `
          : null}
        ${op.source === 'managed' && op.status === 'active'
          ? html`
              <button class="control-btn ghost" disabled=${actionDisabled(pauseKey)} onClick=${() => fire(() => pauseCommandPlaneOperation(op.operation_id))}>
                ${actionDisabled(pauseKey) ? 'Pausing…' : 'Pause'}
              </button>
              <button class="control-btn ghost" disabled=${actionDisabled(recallKey)} onClick=${() => fire(() => recallCommandPlaneOperation(op.operation_id))}>
                ${actionDisabled(recallKey) ? 'Recalling…' : 'Recall'}
              </button>
            `
          : null}
        ${op.source === 'managed' && op.status === 'paused'
          ? html`
              <button class="control-btn ghost" disabled=${actionDisabled(resumeKey)} onClick=${() => fire(() => resumeCommandPlaneOperation(op.operation_id))}>
                ${actionDisabled(resumeKey) ? 'Resuming…' : 'Resume'}
              </button>
            `
          : null}
      </div>
    </article>
  `
}

function DetachmentCard({ card }: { card: CommandPlaneDetachmentCard }) {
  const detachment = card.detachment
  return html`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${detachment.detachment_id}</strong>
          <div class="command-card-sub">${card.operation?.objective ?? detachment.operation_id}</div>
        </div>
        <span class="command-chip ${toneClass(detachment.status)}">${detachment.status ?? 'active'}</span>
      </div>
      <div class="command-card-grid">
        <span>Unit</span><span>${card.assigned_unit_label ?? detachment.assigned_unit_id}</span>
        <span>Leader</span><span>${detachment.leader_id ?? 'unassigned'}</span>
        <span>Roster</span><span>${detachment.roster.length}</span>
        <span>Session</span><span>${detachment.session_id ?? 'none'}</span>
        <span>Runtime</span><span>${detachment.runtime_kind ?? 'managed'}</span>
        <span>Runtime Ref</span><span>${detachment.runtime_ref ?? 'n/a'}</span>
        <span>Progress</span><span>${relativeTime(detachment.last_progress_at)}</span>
        <span>Heartbeat</span><span>${deadlineLabel(detachment.heartbeat_deadline)}</span>
        <span>Updated</span><span>${relativeTime(detachment.updated_at)}</span>
      </div>
      <div class="command-tag-row">
        ${detachment.heartbeat_deadline
          ? html`<span class="command-tag ${expiryTone(detachment.heartbeat_deadline)}">
              deadline ${detachment.heartbeat_deadline}
            </span>`
          : null}
      </div>
    </article>
  `
}

function AlertCard({ alert }: { alert: CommandPlaneAlert }) {
  return html`
    <article class="command-alert ${toneClass(alert.severity)}">
      <div class="command-card-head">
        <strong>${alert.title ?? alert.kind ?? alert.alert_id}</strong>
        <span class="command-chip ${toneClass(alert.severity)}">${alert.severity ?? 'warn'}</span>
      </div>
      <div class="command-alert-meta">
        <span>${alert.scope_type ?? 'scope'}:${alert.scope_id ?? 'n/a'}</span>
        <span>${relativeTime(alert.timestamp)}</span>
      </div>
      ${alert.detail ? html`<p>${alert.detail}</p>` : null}
    </article>
  `
}

function TraceRow({ event }: { event: CommandPlaneTraceEvent }) {
  return html`
    <article class="command-trace-row">
      <div class="command-trace-main">
        <div class="command-trace-head">
          <strong>${event.event_type}</strong>
          <span class="command-chip">${event.source ?? 'control_plane'}</span>
          <span class="command-chip">${relativeTime(event.timestamp)}</span>
        </div>
        <div class="command-card-sub">
          ${event.operation_id ?? event.trace_id}
          ${event.unit_id ? ` · ${event.unit_id}` : ''}
          ${event.actor ? ` · ${event.actor}` : ''}
        </div>
      </div>
      <pre class="command-trace-detail">${prettyJson(event.detail)}</pre>
    </article>
  `
}

function DecisionCard({ decision }: { decision: CommandPlaneDecisionRecord }) {
  const approveKey = `approve:${decision.decision_id}`
  const denyKey = `deny:${decision.decision_id}`
  const isLegacy = decision.source === 'projected_operator'
  return html`
    <article class="command-card ${toneClass(decision.status)}">
      <div class="command-card-head">
        <div>
          <strong>${decision.requested_action}</strong>
          <div class="command-card-sub">${decision.scope_type}:${decision.scope_id}</div>
        </div>
        <span class="command-chip ${toneClass(decision.status)}">${decision.status ?? 'pending'}</span>
      </div>
      <div class="command-card-grid">
        <span>Decision</span><span>${decision.decision_id}</span>
        <span>By</span><span>${decision.requested_by ?? 'unknown'}</span>
        <span>Source</span><span>${decision.source ?? 'managed'}</span>
        <span>Trace</span><span class="mono">${decision.trace_id}</span>
        <span>Created</span><span>${relativeTime(decision.created_at)}</span>
        <span>Reason</span><span>${decision.reason ?? 'n/a'}</span>
      </div>
      ${decision.status === 'pending' && !isLegacy
        ? html`
            <div class="command-action-row">
              <button class="control-btn ghost" disabled=${actionDisabled(approveKey)} onClick=${() => fire(() => approveCommandPlaneDecision(decision.decision_id))}>
                ${actionDisabled(approveKey) ? 'Approving…' : 'Approve'}
              </button>
              <button class="control-btn ghost" disabled=${actionDisabled(denyKey)} onClick=${() => fire(() => denyCommandPlaneDecision(decision.decision_id))}>
                ${actionDisabled(denyKey) ? 'Denying…' : 'Deny'}
              </button>
            </div>
          `
        : null}
      ${isLegacy ? html`<div class="command-card-foot">Legacy operator approval. Use operator control for execution.</div>` : null}
    </article>
  `
}

function CapacityRowCard({ row }: { row: CommandPlaneCapacityRow }) {
  const unit = row.unit
  const freezeKey = `freeze:${unit.unit_id}`
  const killKey = `kill:${unit.unit_id}`
  const frozen = !!unit.policy?.frozen
  const killSwitch = !!unit.policy?.kill_switch
  const utilization = Math.round((row.utilization ?? 0) * 100)
  return html`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${unit.label}</strong>
          <div class="command-card-sub">${unit.unit_id}</div>
        </div>
        <span class="command-chip ${toneClass(utilization > 100 ? 'bad' : utilization > 70 ? 'warn' : 'ok')}">${utilization}%</span>
      </div>
      <div class="command-card-grid">
        <span>Roster</span><span>${row.roster_live ?? 0}/${row.roster_total ?? 0}</span>
        <span>Headcount Cap</span><span>${row.headcount_cap ?? 0}</span>
        <span>Ops</span><span>${row.active_operations ?? 0}/${row.active_operation_cap ?? 0}</span>
        <span>Autonomy</span><span>${unit.policy?.autonomy_level ?? 'n/a'}</span>
        <span>Frozen</span><span>${frozen ? 'yes' : 'no'}</span>
        <span>Kill Switch</span><span>${killSwitch ? 'on' : 'off'}</span>
      </div>
      <div class="command-action-row">
        <button class="control-btn ghost" disabled=${actionDisabled(freezeKey)} onClick=${() => fire(() => toggleCommandPlaneFreeze(unit.unit_id, !frozen))}>
          ${actionDisabled(freezeKey) ? 'Applying…' : frozen ? 'Unfreeze' : 'Freeze'}
        </button>
        <button class="control-btn ghost" disabled=${actionDisabled(killKey)} onClick=${() => fire(() => toggleCommandPlaneKillSwitch(unit.unit_id, !killSwitch))}>
          ${actionDisabled(killKey) ? 'Applying…' : killSwitch ? 'Clear Kill Switch' : 'Enable Kill Switch'}
        </button>
      </div>
    </article>
  `
}

function SwarmChecklistCard({ item }: { item: CommandPlaneSwarmChecklistItem }) {
  return html`
    <article class="command-guide-card ${toneClass(item.status)}">
      <div class="command-guide-head">
        <strong>${item.title}</strong>
        <span class="command-chip ${toneClass(item.status)}">${item.status}</span>
      </div>
      <p>${item.detail}</p>
      <div class="command-card-foot">Next tool: ${item.next_tool}</div>
    </article>
  `
}

function SwarmBlockerCard({ blocker }: { blocker: CommandPlaneSwarmBlocker }) {
  return html`
    <article class="command-alert ${toneClass(blocker.severity)}">
      <div class="command-card-head">
        <strong>${blocker.title}</strong>
        <span class="command-chip ${toneClass(blocker.severity)}">${blocker.severity}</span>
      </div>
      <div class="command-alert-meta">
        <span>${blocker.code}</span>
        <span>next ${blocker.next_tool}</span>
      </div>
      <p>${blocker.detail}</p>
    </article>
  `
}

function SwarmWorkerCard({ worker }: { worker: CommandPlaneSwarmWorker }) {
  return html`
    <article class="command-card compact">
      <div class="command-card-head">
        <div>
          <strong>${worker.name}</strong>
          <div class="command-card-sub">${worker.role} · ${worker.lane}</div>
        </div>
        <span class="command-chip ${toneClass(worker.joined ? (worker.heartbeat_fresh ? 'ok' : 'warn') : 'bad')}">
          ${worker.status}
        </span>
      </div>
      <div class="command-card-grid">
        <span>Joined</span><span>${worker.joined ? 'yes' : 'no'}</span>
        <span>Live</span><span>${worker.live_presence ? 'yes' : 'no'}</span>
        <span>Completed</span><span>${worker.completed ? 'yes' : 'no'}</span>
        <span>Task</span><span>${worker.current_task ?? worker.bound_task_id ?? 'none'}</span>
        <span>Task Title</span><span>${worker.bound_task_title ?? 'n/a'}</span>
        <span>Task Status</span><span>${worker.bound_task_status ?? 'n/a'}</span>
        <span>Heartbeat</span><span>${worker.heartbeat_age_sec != null ? `${Math.round(worker.heartbeat_age_sec)}s` : worker.heartbeat_fresh ? 'completed-cleanly' : 'n/a'}</span>
        <span>Squad</span><span>${worker.squad_member ? 'yes' : 'no'}</span>
        <span>Detachment</span><span>${worker.detachment_member ? 'yes' : 'no'}</span>
      </div>
      <div class="command-tag-row">
        <span class="command-tag">${worker.lane}</span>
        <span class="command-tag ${worker.current_task_matches_run ? 'ok' : 'warn'}">current_task</span>
        <span class="command-tag ${worker.claim_marker_seen ? 'ok' : 'warn'}">claim</span>
        <span class="command-tag ${worker.done_marker_seen ? 'ok' : 'warn'}">done</span>
        <span class="command-tag ${worker.final_marker_seen ? 'ok' : 'warn'}">final</span>
      </div>
      ${worker.last_message
        ? html`<div class="command-card-foot">${relativeTime(worker.last_message.timestamp)} · ${worker.last_message.content}</div>`
        : null}
    </article>
  `
}

function SwarmSurface() {
  const swarm = commandPlaneSwarm.value
  const runId = dashboardSwarmRunId()
  return html`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title">Swarm Live Run</div>
        ${commandPlaneSwarmLoading.value
          ? html`<div class="empty-state">Loading swarm live state…</div>`
          : commandPlaneSwarmError.value
            ? html`<div class="empty-state error">${commandPlaneSwarmError.value}</div>`
            : swarm
              ? html`
                  <div class="command-summary-grid">
                    <div class="monitor-stat-card"><span>Run</span><strong>${swarm.run_id ?? runId ?? 'swarm-live'}</strong><small>${swarm.room_id ?? 'room n/a'}</small></div>
                    <div class="monitor-stat-card"><span>Workers</span><strong>${swarm.summary?.joined_workers ?? 0}/${swarm.summary?.expected_workers ?? 0}</strong><small>${swarm.summary?.live_workers ?? 0} live · ${swarm.summary?.completed_workers ?? 0} completed</small></div>
                    <div class="monitor-stat-card"><span>Runtime</span><strong>${swarm.provider?.active_slots_now ?? 0}/${swarm.provider?.total_slots ?? 0}</strong><small>peak ${swarm.summary?.peak_hot_slots ?? 0} · ctx ${swarm.provider?.ctx_per_slot ?? 0}</small></div>
                    <div class="monitor-stat-card"><span>Hot 10+</span><strong>${swarm.summary?.pass_hot_concurrency ? 'pass' : 'check'}</strong><small>${swarm.provider?.slot_url ?? 'slot n/a'}</small></div>
                    <div class="monitor-stat-card"><span>End to End</span><strong>${swarm.summary?.pass_end_to_end ? 'pass' : 'check'}</strong><small>${swarm.recommended_next_tool ?? 'masc_observe_traces'}</small></div>
                  </div>
                  <div class="command-card-grid">
                    <span>Operation</span><span>${swarm.operation?.operation_id ?? 'none'}</span>
                    <span>Squad</span><span>${swarm.squad?.label ?? 'none'}</span>
                    <span>Detachment</span><span>${swarm.detachment?.detachment_id ?? 'none'}</span>
                    <span>Expected</span><span>${swarm.summary?.expected_workers ?? 0} workers</span>
                    <span>Final Markers</span><span>${swarm.summary?.final_markers_seen ?? 0}</span>
                    <span>Recommended</span><span>${swarm.recommended_next_tool ?? 'masc_observe_traces'}</span>
                  </div>
                  ${swarm.truth_notes.length > 0
                    ? html`<div class="command-tag-row">
                        ${swarm.truth_notes.map(note => html`<span class="command-tag">${note}</span>`)}
                      </div>`
                    : null}
                `
              : html`<div class="empty-state">No swarm read-model yet.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title">Checklist</div>
        ${swarm && swarm.checklist.length > 0
          ? html`<div class="command-card-stack">
              ${swarm.checklist.map(item => html`<${SwarmChecklistCard} item=${item} />`)}
            </div>`
          : html`<div class="empty-state">No checklist yet.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title">Workers</div>
        ${swarm && swarm.workers.length > 0
          ? html`<div class="command-card-stack">
              ${swarm.workers.map(worker => html`<${SwarmWorkerCard} worker=${worker} />`)}
            </div>`
          : html`<div class="empty-state">No worker rows yet.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title">Runtime</div>
        ${swarm?.provider
          ? html`
              <div class="command-card-grid">
                <span>Slot URL</span><span>${swarm.provider.slot_url ?? 'n/a'}</span>
                <span>Total Slots</span><span>${swarm.provider.total_slots ?? 0}</span>
                <span>Active Now</span><span>${swarm.provider.active_slots_now ?? 0}</span>
                <span>Peak Active</span><span>${swarm.provider.peak_active_slots ?? 0}</span>
                <span>Sample Count</span><span>${swarm.provider.sample_count ?? 0}</span>
                <span>Last Sample</span><span>${swarm.provider.last_sample_at ? relativeTime(swarm.provider.last_sample_at) : 'n/a'}</span>
              </div>
              ${swarm.provider.timeline.length > 0
                ? html`<div class="command-trace-stack">
                    ${swarm.provider.timeline.slice(-12).map(sample => html`
                      <article class="command-trace-row">
                        <div class="command-trace-main">
                          <div class="command-trace-head">
                            <strong>${sample.active_slots} active</strong>
                            <span class="command-chip">${relativeTime(sample.timestamp)}</span>
                          </div>
                          <div class="command-card-sub">slots ${sample.active_slot_ids.join(', ') || 'none'}</div>
                        </div>
                      </article>
                    `)}
                  </div>`
                : html`<div class="empty-state">No slot telemetry captured yet.</div>`}
            `
          : html`<div class="empty-state">No runtime telemetry yet.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title">Blockers</div>
        ${swarm && swarm.blockers.length > 0
          ? html`<div class="command-card-stack">
              ${swarm.blockers.map(blocker => html`<${SwarmBlockerCard} blocker=${blocker} />`)}
            </div>`
          : html`<div class="empty-state">No blockers. Use ${swarm?.recommended_next_tool ?? 'masc_observe_traces'} for the next action.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title">Recent Messages</div>
        ${swarm && swarm.recent_messages.length > 0
          ? html`<div class="command-trace-stack">
              ${swarm.recent_messages.map(message => html`
                <article class="command-trace-row">
                  <div class="command-trace-main">
                    <div class="command-trace-head">
                      <strong>${message.from}</strong>
                      <span class="command-chip">${relativeTime(message.timestamp)}</span>
                    </div>
                    <div class="command-card-sub">seq ${message.seq}</div>
                  </div>
                  <pre class="command-trace-detail">${message.content}</pre>
                </article>
              `)}
            </div>`
          : html`<div class="empty-state">No run-scoped broadcasts captured yet.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title">Recent Trace Events</div>
        ${swarm && swarm.recent_trace_events.length > 0
          ? html`<div class="command-trace-stack">
              ${swarm.recent_trace_events.map(event => html`<${TraceRow} event=${event} />`)}
            </div>`
          : html`<div class="empty-state">No run-scoped trace events captured yet.</div>`}
      </section>
    </div>
  `
}

function OperationsSurface() {
  const snapshot = commandPlaneSnapshot.value
  return html`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title">Operations</div>
        ${snapshot && snapshot.operations.operations.length > 0
          ? html`<div class="command-card-stack">
              ${snapshot.operations.operations.map(card => html`<${OperationCard} card=${card} />`)}
            </div>`
          : html`<div class="empty-state">No managed or projected operations.</div>`}
      </section>
      <section class="card command-section">
        <div class="card-title">Detachments</div>
        ${snapshot && snapshot.detachments.detachments.length > 0
          ? html`<div class="command-card-stack">
              ${snapshot.detachments.detachments.map(card => html`<${DetachmentCard} card=${card} />`)}
            </div>`
          : html`<div class="empty-state">No detachments projected.</div>`}
      </section>
    </div>
  `
}

function ChainsSurface() {
  const summary = commandPlaneChainSummary.value
  const overlays = summary?.operations ?? []
  const focusedOperationId = commandPlaneChainFocusOperationId.value
  const selectedOverlay =
    overlays.find(item => item.operation.operation_id === focusedOperationId)
    ?? overlays[0]
    ?? null
  const selectedRunId = selectedOverlay?.operation.chain?.run_id ?? null
  const run = commandPlaneChainRun.value?.run ?? selectedOverlay?.preview_run ?? null
  const isPreviewRun = !commandPlaneChainRun.value?.run && !!selectedOverlay?.preview_run

  useEffect(() => {
    if (selectedRunId) {
      void loadCommandPlaneChainRun(selectedRunId)
    } else {
      clearCommandPlaneChainRun()
    }
  }, [selectedRunId])

  return html`
    <div class="command-grid">
      <section class="card command-section">
        <div class="card-title">Chains</div>
        <article class="command-guide-card ${chainStatusTone(summary?.connection.status)}">
          <div class="command-guide-head">
            <strong>llm-mcp connection</strong>
            <span class="command-chip ${chainStatusTone(summary?.connection.status)}">${summary?.connection.status ?? 'disconnected'}</span>
          </div>
          <p>${summary?.connection.message ?? 'Chain summary is aggregated through the MASC proxy.'}</p>
          <div class="command-card-grid">
            <span>Base URL</span><span>${summary?.connection.base_url ?? 'n/a'}</span>
            <span>Linked Ops</span><span>${summary?.summary?.linked_operations ?? 0}</span>
            <span>Active Chains</span><span>${summary?.summary?.active_chains ?? 0}</span>
            <span>Recent Failures</span><span>${summary?.summary?.recent_failures ?? 0}</span>
            <span>Last Event</span><span>${relativeTime(summary?.summary?.last_history_event_at)}</span>
          </div>
        </article>

        ${commandPlaneChainError.value
          ? html`<div class="empty-state error">${commandPlaneChainError.value}</div>`
          : null}

        ${commandPlaneChainLoading.value && !summary
          ? html`<div class="empty-state">Loading chain overlays…</div>`
          : overlays.length > 0
            ? html`
                <div class="command-chain-list">
                  ${overlays.map(overlay => html`
                    <${ChainOperationListItem}
                      overlay=${overlay}
                      selected=${selectedOverlay?.operation.operation_id === overlay.operation.operation_id}
                      onSelect=${() => focusCommandPlaneChainOperation(overlay.operation.operation_id)}
                    />
                  `)}
                </div>
              `
            : html`<div class="empty-state">No chain-backed operations yet.</div>`}

        <div class="command-chain-history">
          <div class="command-guide-head">
            <strong>Recent history</strong>
            <span class="command-chip">${summary?.recent_history.length ?? 0}</span>
          </div>
          ${summary && summary.recent_history.length > 0
            ? html`
                <div class="command-card-stack">
                  ${summary.recent_history.slice(0, 6).map(item => html`<${ChainHistoryRow} item=${item} />`)}
                </div>
              `
            : html`<div class="empty-state">No recent chain history.</div>`}
        </div>
      </section>

      <section class="card command-section">
        <div class="card-title">Chain Detail</div>
        ${selectedOverlay
          ? html`
              <article class="command-card">
                <div class="command-card-head">
                  <div>
                    <strong>${selectedOverlay.operation.objective}</strong>
                    <div class="command-card-sub">${selectedOverlay.operation.operation_id}</div>
                  </div>
                  <span class="command-chip ${chainStatusTone(selectedOverlay.operation.chain?.status)}">
                    ${selectedOverlay.operation.chain?.status ?? selectedOverlay.operation.status}
                  </span>
                </div>
                <div class="command-card-grid">
                  <span>Kind</span><span>${selectedOverlay.operation.chain?.kind ?? 'chain_dsl'}</span>
                  <span>Chain ID</span><span>${selectedOverlay.operation.chain?.chain_id ?? 'goal-driven'}</span>
                  <span>Run ID</span><span>${selectedRunId ?? 'not materialized'}</span>
                  <span>Progress</span><span>${formatPercent(selectedOverlay.runtime?.progress)}</span>
                  <span>Elapsed</span><span>${formatElapsed(selectedOverlay.runtime?.elapsed_sec)}</span>
                  <span>Updated</span><span>${relativeTime(selectedOverlay.operation.chain?.last_sync_at ?? selectedOverlay.operation.updated_at)}</span>
                </div>
                ${selectedOverlay.operation.chain?.goal
                  ? html`<div class="command-card-foot">${selectedOverlay.operation.chain.goal}</div>`
                  : null}
              </article>

              ${selectedOverlay.mermaid
                ? html`
                    <div class="command-chain-panel">
                      <div class="command-guide-head">
                        <strong>Mermaid</strong>
                        <span class="command-chip">${selectedOverlay.operation.chain?.chain_id ?? 'graph'}</span>
                      </div>
                      <${MermaidGraph} source=${selectedOverlay.mermaid} />
                    </div>
                  `
                : html`<div class="empty-state">No Mermaid graph captured yet.</div>`}

              <div class="command-chain-panel">
                <div class="command-guide-head">
                  <strong>Run detail</strong>
                  <span class="command-chip ${run?.success === false ? 'bad' : 'ok'}">
                    ${run
                      ? (run.success === false ? 'failed' : isPreviewRun ? 'preview' : 'captured')
                      : 'pending'}
                  </span>
                </div>
                ${commandPlaneChainRunLoading.value
                  ? html`<div class="empty-state">Loading run detail…</div>`
                  : commandPlaneChainRunError.value
                    ? html`<div class="empty-state error">${commandPlaneChainRunError.value}</div>`
                    : run && run.nodes.length > 0
                      ? html`
                          <div class="command-card-grid">
                            <span>Chain</span><span>${run.chain_id}</span>
                            <span>Run</span><span>${run.run_id ?? 'preview only'}</span>
                            <span>Duration</span><span>${run.duration_ms != null ? `${run.duration_ms}ms` : 'n/a'}</span>
                            <span>Nodes</span><span>${run.nodes.length}</span>
                          </div>
                          ${isPreviewRun
                            ? html`<div class="command-card-foot">Preview generated from the designed chain before run-store materialization.</div>`
                            : null}
                          <div class="command-card-stack">
                            ${run.nodes.map(node => html`<${ChainRunNodeRow} node=${node} />`)}
                          </div>
                        `
                      : html`<div class="empty-state">Run store detail is not available yet for this operation.</div>`}
              </div>
            `
          : html`<div class="empty-state">Select a chain-backed operation to inspect its graph and run detail.</div>`}
      </section>
    </div>
  `
}

function TopologySurface() {
  const snapshot = commandPlaneSnapshot.value
  return html`
    <section class="card command-section">
      <div class="card-title">Topology</div>
      ${snapshot && snapshot.topology.units.length > 0
        ? html`${snapshot.topology.units.map(node => html`<${TopologyNode} node=${node} />`)}`
        : html`<div class="empty-state">No command topology projected yet.</div>`}
    </section>
  `
}

function AlertsSurface() {
  const snapshot = commandPlaneSnapshot.value
  return html`
    <section class="card command-section">
      <div class="card-title">Alerts</div>
      ${snapshot && snapshot.alerts.alerts.length > 0
        ? html`<div class="command-card-stack">
            ${snapshot.alerts.alerts.map(alert => html`<${AlertCard} alert=${alert} />`)}
          </div>`
        : html`<div class="empty-state">No command-plane alerts right now.</div>`}
    </section>
  `
}

function TraceSurface() {
  const snapshot = commandPlaneSnapshot.value
  return html`
    <section class="card command-section">
      <div class="card-title">Trace</div>
      ${snapshot && snapshot.traces.events.length > 0
        ? html`<div class="command-trace-stack">
            ${snapshot.traces.events.map(event => html`<${TraceRow} event=${event} />`)}
          </div>`
        : html`<div class="empty-state">No recent trace events.</div>`}
    </section>
  `
}

function ControlSurface() {
  const snapshot = commandPlaneSnapshot.value
  return html`
    <div class="command-surface-grid">
      <section class="card command-section">
        <div class="card-title">Approval Queue</div>
        ${snapshot && snapshot.decisions.decisions.length > 0
          ? html`<div class="command-card-stack">
              ${snapshot.decisions.decisions.map(decision => html`<${DecisionCard} decision=${decision} />`)}
            </div>`
          : html`<div class="empty-state">No approval queue items.</div>`}
      </section>

      <section class="card command-section">
        <div class="card-title">Unit Controls</div>
        ${snapshot && snapshot.capacity.capacity.length > 0
          ? html`<div class="command-card-stack">
              ${snapshot.capacity.capacity.map(row => html`<${CapacityRowCard} row=${row} />`)}
            </div>`
          : html`<div class="empty-state">No capacity rows projected.</div>`}
      </section>
    </div>
  `
}

function SurfaceBody() {
  if (commandPlaneSurface.value === 'summary') {
    return html`<${SummarySurface} />`
  }
  if (!commandPlaneSnapshot.value) {
    return html`<${DetailLoadingState} />`
  }
  switch (commandPlaneSurface.value) {
    case 'swarm':
      return html`<${SwarmSurface} />`
    case 'chains':
      return html`<${ChainsSurface} />`
    case 'topology':
      return html`<${TopologySurface} />`
    case 'alerts':
      return html`<${AlertsSurface} />`
    case 'trace':
      return html`<${TraceSurface} />`
    case 'control':
      return html`<${ControlSurface} />`
    case 'operations':
    default:
      return html`<${OperationsSurface} />`
  }
}

export function Command() {
  useEffect(() => {
    void refreshCommandPlaneCurrentSurface()
    void refreshCommandPlaneChainSummary()
    void refreshCommandPlaneHelp()
    void refreshCommandPlaneSwarm()
  }, [])

  useEffect(() => {
    if (route.value.tab !== 'command') return
    const requestedSurface = route.value.params.surface
    const requestedOperation = route.value.params.operation
    if (isCommandSurface(requestedSurface)) {
      setCommandPlaneSurface(requestedSurface)
    }
    if (requestedOperation) {
      focusCommandPlaneChainOperation(requestedOperation)
    }
  }, [route.value.tab, route.value.params.surface, route.value.params.operation])

  useEffect(() => {
    let refreshTimer: ReturnType<typeof window.setTimeout> | null = null
    const scheduleRefresh = () => {
      if (refreshTimer) return
      refreshTimer = window.setTimeout(() => {
        refreshTimer = null
        void refreshCommandPlaneCurrentSurface()
        void refreshCommandPlaneChainSummary()
      }, 250)
    }

    const es = new EventSource(chainEventsUrl())
    const listeners = CHAIN_SSE_EVENT_TYPES.map(type => {
      const handler = () => scheduleRefresh()
      es.addEventListener(type, handler)
      return { type, handler }
    })
    es.onerror = () => {
      scheduleRefresh()
    }

    return () => {
      listeners.forEach(({ type, handler }) => {
        es.removeEventListener(type, handler)
      })
      es.close()
      if (refreshTimer) {
        window.clearTimeout(refreshTimer)
      }
    }
  }, [])

  return html`
    <section class="dashboard-panel command-plane-view">
      <div class="panel-header">
        <div>
          <h2>Command Plane</h2>
          <p>Operations-first command surface for company → platoon → squad → agent orchestration, approvals, alerts, and traceability.</p>
        </div>
        <div class="panel-actions">
          <button
            class="control-btn ghost"
            onClick=${() => {
              void fire(() => runCommandPlaneDispatchTick())
            }}
            disabled=${actionDisabled('dispatch:tick')}
          >
            ${actionDisabled('dispatch:tick') ? 'Reconciling…' : 'Run Tick'}
          </button>
          <button class="control-btn ghost" onClick=${() => { void refreshCommandPlaneCurrentSurface(); void refreshCommandPlaneChainSummary() }} disabled=${commandPlaneLoading.value}>
            ${commandPlaneLoading.value ? 'Refreshing…' : 'Refresh'}
          </button>
        </div>
      </div>

      ${commandPlaneError.value
        ? html`<div class="empty-state error">${commandPlaneError.value}</div>`
        : null}
      ${commandPlaneActionError.value
        ? html`<div class="empty-state error">${commandPlaneActionError.value}</div>`
        : null}
      <${SurfaceTabs} />
      <${SurfaceBody} />
    </section>
  `
}
