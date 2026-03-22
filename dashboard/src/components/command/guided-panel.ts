import { html } from 'htm/preact'
import type { CommandPlaneHelpPath } from '../../types'
import {
  commandPlaneDetailError,
  commandPlaneDetailLoading,
  commandPlaneHelp,
  commandPlaneHelpError,
  commandPlaneHelpLoading,
  commandPlaneSnapshot,
} from '../../command-store'
import { agents, serverStatus, tasks } from '../../store'
import {
  currentCommandPlaneSummary,
  dashboardActorName,
  findHelpPath,
  findHelpStep,
  isActiveTask,
  lastSeenAgeSeconds,
  relevantPitfalls,
  toneClass,
} from './helpers'
import { SummaryCards, SummaryHero } from './summary-hero'

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
          title: 'Room 준비도',
          tone: 'ok',
          detail: `${status?.room ?? status?.project ?? 'unknown'} · base ${status?.room_base_path ?? 'n/a'}`,
          tool: 'masc_status',
        }
      : {
          title: 'Room 준비도',
          tone: 'bad',
          detail: '아직 room snapshot이 없습니다. 조인 전에 room을 repo root로 맞추세요.',
          tool: 'masc_set_room',
        },
    !actorName
      ? {
          title: 'Task 준비도',
          tone: 'warn',
          detail: '?agent= 쿼리가 없습니다. room health는 보이지만 agent 단위 다음 단계는 비어 있습니다.',
          tool: 'masc_join',
        }
      : !actor
        ? {
            title: 'Task 준비도',
            tone: 'bad',
            detail: `${actorName} 이 room roster에 보이지 않습니다.`,
            tool: 'masc_join',
          }
        : actorTasks.length === 0
          ? {
              title: 'Task 준비도',
              tone: 'warn',
              detail: `${actorName} 에게 배정된 claimed task가 없습니다. backlog에 task가 있으면 masc_transition(action=claim)으로 집고, 없으면 새 task를 만들어야 합니다.`,
              tool: tasks.value.length > 0 ? 'masc_transition' : 'masc_add_task',
            }
          : !currentTask
            ? {
                title: 'Task 준비도',
                tone: 'bad',
                detail: `${actorName} 에 claimed task는 있지만 session current_task binding이 없습니다.`,
                tool: 'masc_plan_set_task',
              }
            : heartbeatFresh === false
              ? {
                  title: 'Task 준비도',
                  tone: 'warn',
                  detail: `${actorName} current_task=${currentTask} 이지만 heartbeat가 stale 합니다 (${lastSeenAge}s).`,
                  tool: 'masc_heartbeat',
                }
              : {
                  title: 'Task 준비도',
                  tone: 'ok',
                  detail: `${actorName} current_task=${currentTask}${lastSeenAge != null ? ` · 마지막 활동 ${lastSeenAge}s 전` : ''}`,
                  tool: 'masc_plan_get_task',
                },
    !summary || (summary.topology.summary?.managed_unit_count ?? 0) === 0
      ? {
          title: '작전 준비도',
          tone: 'warn',
          detail: '관리 단위가 아직 정의되지 않았습니다. hierarchy가 있어야 CPv2 benchmark를 시작할 수 있습니다.',
          tool: 'masc_unit_define',
        }
      : activeOps === 0
        ? {
            title: '작전 준비도',
            tone: 'warn',
            detail: `${summary.topology.summary?.managed_unit_count ?? 0}개 관리 단위는 준비됐지만 활성 작전은 없습니다.`,
            tool: 'masc_operation_start',
          }
        : {
            title: '작전 준비도',
            tone: 'ok',
            detail: `${summary.topology.summary?.managed_unit_count ?? 0}개 관리 단위 위에서 ${activeOps}개 활성 작전이 돌고 있습니다.`,
            tool: 'masc_observe_operations',
          },
    pendingDecisions > 0
      ? {
          title: '디스패치 준비도',
          tone: 'warn',
          detail: `${pendingDecisions}개의 pending approval이 strict action을 막고 있습니다.`,
          tool: 'masc_policy_approve',
        }
      : activeOps > 0 && detachments === 0
        ? {
            title: '디스패치 준비도',
            tone: 'bad',
            detail: 'active operation은 있지만 detachment가 아직 materialize 되지 않았습니다.',
            tool: 'masc_dispatch_tick',
          }
        : stalledDetachment || badAlert
          ? {
              title: '디스패치 준비도',
              tone: 'warn',
              detail: `dispatch 재정렬이 필요합니다${stalledDetachment ? ` · detachment ${stalledDetachment.detachment.detachment_id} 가 stalled 상태입니다` : ''}${badAlert ? ` · alert ${badAlert.title ?? badAlert.alert_id}` : ''}${!snapshot && !stalledDetachment && !badAlert ? ' · 정확한 원인은 detail 탭에서 확인하세요.' : ''}.`,
              tool: pendingDecisions > 0 ? 'masc_policy_approve' : 'masc_dispatch_tick',
            }
          : {
              title: '디스패치 준비도',
              tone: 'ok',
              detail: `${detachments}개 detachment가 보이고 strict approval backlog도 없습니다${!snapshot ? ' · detail pane은 열릴 때만 로드됩니다.' : ''}.`,
              tool: 'masc_detachment_list',
            },
  ]

  const nextTool =
    !roomReady
      ? 'masc_set_room'
      : !actorName || !actor
        ? 'masc_join'
        : actorTasks.length === 0
          ? (tasks.value.length > 0 ? 'masc_transition' : 'masc_add_task')
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
    <div class="grid grid-cols-[minmax(0,1.06fr)_minmax(0,0.94fr)] gap-4">
      <section class="card rounded-xl min-h-[240px]">
        <div class="card rounded-xl-title-row">
          <div class="card rounded-xl-title">즉시 조치</div>
        </div>
        <div class="bg-[var(--white-4)] border border-[var(--white-8)] p-3.5 rounded-xl cmd-guide-card highlight mb-3">
          <div class="flex justify-between gap-2.5 items-start">
            <strong>${nextStep?.title ?? nextTool}</strong>
            <span class="cmd-chip rounded-full ok">${nextTool}</span>
          </div>
          <p>${nextStep?.summary ?? '지금 막고 있는 병목을 풀기 위해 canonical flow의 다음 tool부터 실행합니다.'}</p>
          ${nextStep?.success_signals?.length
            ? html`<div class="cmd-tag rounded-full-row">
                ${nextStep.success_signals.map(signal => html`<span class="cmd-tag rounded-full ok">${signal}</span>`)}
              </div>`
            : null}
        </div>

        <div class="flex flex-col gap-2.5">
          ${readiness.map(item => html`
            <article class="flex flex-col gap-2.5 p-3.5 border border-[var(--white-8)] bg-[var(--white-3)] rounded-xl cmd-readiness-row ${toneClass(item.tone)}">
              <div>
                <div class="flex justify-between gap-2.5 items-start">
                  <strong>${item.title}</strong>
                  <span class="cmd-chip rounded-full ${toneClass(item.tone)}">${item.tone}</span>
                </div>
                <p>${item.detail}</p>
              </div>
              <div class="cmd-card rounded-xl-foot">Next tool: ${item.tool}</div>
            </article>
          `)}
        </div>

        ${pitfalls.length > 0
          ? html`
              <div class="bg-[var(--white-4)] border border-[var(--white-8)] p-3.5 rounded-xl cmd-guide-card warn">
                <div class="flex justify-between gap-2.5 items-start">
                  <strong>자주 막히는 지점</strong>
                  <span class="cmd-chip rounded-full warn">${pitfalls.length}</span>
                </div>
                <div class="flex flex-col gap-3">
                  ${pitfalls.map(pitfall => html`
                    <article class="p-3 rounded-[10px] bg-[rgba(9,12,20,0.5)] border border-solid border-[var(--white-6)] break-words [overflow-wrap:anywhere]">
                      <strong>${pitfall.title}</strong>
                      <div>${pitfall.symptom}</div>
                      <div class="cmd-card rounded-xl-sub">${pitfall.fix_tool} 로 해결: ${pitfall.fix_summary}</div>
                    </article>
                  `)}
                </div>
              </div>
            `
          : null}
      </section>

      <section class="card rounded-xl min-h-[240px]">
        <div class="card rounded-xl-title-row">
          <div class="card rounded-xl-title">운영 경로</div>
        </div>
        ${commandPlaneHelpLoading.value
          ? html`<div class="empty-state text-center border border-dashed border-[var(--card-border)] rounded-[10px] py-[22px] px-4 text-[color:var(--text-muted)]">CPv2 runbook 불러오는 중…</div>`
          : commandPlaneHelpError.value
            ? html`<div class="empty-state error text-center border border-dashed border-[var(--card-border)] rounded-[10px] py-[22px] px-4 text-[color:var(--text-muted)]">${commandPlaneHelpError.value}</div>`
            : html`
                <div class="grid gap-3">
                  ${renderedPaths.map(path => html`
                    <article class="bg-[var(--white-4)] border border-[var(--white-8)] p-3.5 rounded-xl cmd-guide-card">
                      <div class="flex justify-between gap-2.5 items-start">
                        <strong>${path.title}</strong>
                        <span class="cmd-chip rounded-full">${path.id}</span>
                      </div>
                      <p>${path.summary}</p>
                      <div class="cmd-card rounded-xl-sub">${path.when_to_use}</div>
                      <div class="flex flex-col gap-1.5 mt-3">
                        ${path.steps.slice(0, 4).map(step => html`
                          <div class="flex gap-2.5 flex-wrap items-baseline">
                            <span class="font-mono text-[#67e8f9] text-[length:var(--fs-sm)]">${step.tool}</span>
                            <span>${step.title}</span>
                          </div>
                        `)}
                      </div>
                    </article>
                  `)}
                </div>
                ${docs.length > 0
                  ? html`<div class="flex flex-wrap gap-2 mt-3">
                      ${docs.map(doc => html`<span class="cmd-tag rounded-full">${doc.title}: ${doc.path}</span>`)}
                    </div>`
                  : null}
              `}
      </section>
    </div>
  `
}

export function SummarySurface() {
  return html`
    <${SummaryHero} />
    <${SummaryCards} />
    <${GuidedPanel} />
  `
}

export function DetailLoadingState() {
  if (commandPlaneDetailLoading.value) {
    return html`<div class="empty-state text-center border border-dashed border-[var(--card-border)] rounded-[10px] py-[22px] px-4 text-[color:var(--text-muted)]">command-plane detail 불러오는 중…</div>`
  }
  if (commandPlaneDetailError.value) {
    return html`<div class="empty-state error text-center border border-dashed border-[var(--card-border)] rounded-[10px] py-[22px] px-4 text-[color:var(--text-muted)]">${commandPlaneDetailError.value}</div>`
  }
  return html`<div class="empty-state text-center border border-dashed border-[var(--card-border)] rounded-[10px] py-[22px] px-4 text-[color:var(--text-muted)]">surface를 선택하면 command-plane detail을 로드합니다.</div>`
}
