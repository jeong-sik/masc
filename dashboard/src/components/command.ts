import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import type {
  CommandPlaneAlert,
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
  CommandPlaneSwarmTimelineEvent,
  CommandPlaneTraceEvent,
  CommandPlaneTreeNode,
  Task,
} from '../types'
import {
  approveCommandPlaneDecision,
  commandPlaneActionBusy,
  commandPlaneActionError,
  commandPlaneError,
  commandPlaneHelp,
  commandPlaneHelpError,
  commandPlaneHelpLoading,
  commandPlaneLoading,
  commandPlaneSnapshot,
  commandPlaneSurface,
  denyCommandPlaneDecision,
  pauseCommandPlaneOperation,
  recallCommandPlaneOperation,
  refreshCommandPlaneHelp,
  refreshCommandPlaneSnapshot,
  runCommandPlaneDispatchTick,
  resumeCommandPlaneOperation,
  setCommandPlaneSurface,
  toggleCommandPlaneFreeze,
  toggleCommandPlaneKillSwitch,
} from '../command-store'
import { agents, serverStatus, tasks } from '../store'

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

function dashboardActorName(): string | null {
  if (typeof window === 'undefined') return null
  const params = new URLSearchParams(window.location.search)
  const value = params.get('agent') ?? params.get('agent_name')
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
  const snapshot = commandPlaneSnapshot.value
  const topology = snapshot?.topology.summary
  const ops = snapshot?.operations.summary
  const decisions = snapshot?.decisions.summary
  const alerts = snapshot?.alerts.summary
  return html`
    <div class="command-summary-grid">
      <div class="monitor-stat-card"><span>Units</span><strong>${topology?.total_units ?? 0}</strong><small>${topology?.managed_unit_count ?? 0} managed</small></div>
      <div class="monitor-stat-card"><span>Ops</span><strong>${ops?.active ?? 0}</strong><small>${snapshot?.detachments.summary?.active ?? 0} detachments</small></div>
      <div class="monitor-stat-card"><span>Approvals</span><strong>${decisions?.pending ?? 0}</strong><small>${decisions?.total ?? 0} tracked</small></div>
      <div class="monitor-stat-card"><span>Alerts</span><strong>${alerts?.bad ?? 0}</strong><small>${alerts?.warn ?? 0} warn</small></div>
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

function SwarmPanel() {
  const swarm = commandPlaneSnapshot.value?.swarm_status
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
  const surfaces: CommandPlaneSurface[] = ['operations', 'topology', 'alerts', 'trace', 'control']
  return html`
    <div class="command-surface-tabs">
      ${surfaces.map(surface => html`
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
  const snapshot = commandPlaneSnapshot.value
  const status = serverStatus.value
  const actorName = dashboardActorName()
  const actor = actorName ? agents.value.find(item => item.name === actorName) ?? null : null
  const actorTasks = actorName ? tasks.value.filter(task => task.assignee === actorName && isActiveTask(task)) : []
  const activeOps = snapshot?.operations.summary?.active ?? 0
  const detachments = snapshot?.detachments.summary?.total ?? 0
  const pendingDecisions = snapshot?.decisions.summary?.pending ?? 0
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
    !snapshot || (snapshot.topology.summary?.managed_unit_count ?? 0) === 0
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
            detail: `${snapshot.topology.summary?.managed_unit_count ?? 0} managed units are ready, but there is no active operation.`,
            tool: 'masc_operation_start',
          }
        : {
            title: 'Operation readiness',
            tone: 'ok',
            detail: `${activeOps} active operation(s) across ${snapshot.topology.summary?.managed_unit_count ?? 0} managed unit(s).`,
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
              detail: `Dispatch needs reconciliation${stalledDetachment ? ` · detachment ${stalledDetachment.detachment.detachment_id} is stalled` : ''}${badAlert ? ` · alert ${badAlert.title ?? badAlert.alert_id}` : ''}.`,
              tool: pendingDecisions > 0 ? 'masc_policy_approve' : 'masc_dispatch_tick',
            }
          : {
              title: 'Dispatch readiness',
              tone: 'ok',
              detail: `${detachments} detachment(s) visible and no strict approval backlog.`,
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
              : !snapshot || (snapshot.topology.summary?.managed_unit_count ?? 0) === 0
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
    <div class="command-guide-grid">
      <section class="card command-section">
        <div class="card-title">Readiness</div>
        <div class="command-guide-readiness">
          ${readiness.map(item => html`
            <article class="command-guide-card ${toneClass(item.tone)}">
              <div class="command-guide-head">
                <strong>${item.title}</strong>
                <span class="command-chip ${toneClass(item.tone)}">${item.tone}</span>
              </div>
              <p>${item.detail}</p>
              <div class="command-card-foot">Next tool: ${item.tool}</div>
            </article>
          `)}
        </div>
      </section>

      <section class="card command-section">
        <div class="card-title">Next Step</div>
        <article class="command-guide-card highlight">
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
          ${pitfalls.length > 0
            ? html`<div class="command-guide-list">
                ${pitfalls.map(pitfall => html`
                  <article class="command-guide-inline">
                    <strong>${pitfall.title}</strong>
                    <div>${pitfall.symptom}</div>
                    <div class="command-card-sub">Fix with ${pitfall.fix_tool}: ${pitfall.fix_summary}</div>
                  </article>
                `)}
              </div>`
            : null}
        </article>
      </section>

      <section class="card command-section">
        <div class="card-title">How It Works</div>
        ${commandPlaneHelpLoading.value
          ? html`<div class="empty-state">Loading CPv2 runbook…</div>`
          : commandPlaneHelpError.value
            ? html`<div class="empty-state error">${commandPlaneHelpError.value}</div>`
            : html`
                <div class="command-guide-paths">
                  ${renderedPaths.map(path => html`
                    <article class="command-guide-card">
                      <div class="command-guide-head">
                        <strong>${path.title}</strong>
                        <span class="command-chip">${path.id}</span>
                      </div>
                      <p>${path.summary}</p>
                      <div class="command-card-sub">${path.when_to_use}</div>
                      <div class="command-step-list">
                        ${path.steps.map(step => html`
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

function OperationCard({ card }: { card: CommandPlaneOperationCard }) {
  const op = card.operation
  const pauseKey = `pause:${op.operation_id}`
  const resumeKey = `resume:${op.operation_id}`
  const recallKey = `recall:${op.operation_id}`
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
      ${op.checkpoint_ref
        ? html`<div class="command-card-foot">Checkpoint ${op.checkpoint_ref}</div>`
        : null}
      <div class="command-action-row">
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
  switch (commandPlaneSurface.value) {
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
    void refreshCommandPlaneHelp()
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
          <button class="control-btn ghost" onClick=${() => { void refreshCommandPlaneSnapshot() }} disabled=${commandPlaneLoading.value}>
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

      <${SummaryCards} />
      <${SwarmPanel} />
      <${GuidedPanel} />
      <${SurfaceTabs} />
      <${SurfaceBody} />
    </section>
  `
}
