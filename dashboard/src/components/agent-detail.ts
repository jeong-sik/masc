// Agent detail overlay — main component composing sub-panels
// Sub-components: agent-detail-state, agent-detail-timeline, agent-detail-journal, agent-detail-worker

import { html } from 'htm/preact'
import { useSignal } from '@preact/signals'
import { formatPct } from '../lib/format-number'
import { useMemo, useRef } from 'preact/hooks'
import { SectionCard } from './common/card'
import { EmptyState, ErrorState } from './common/feedback-state'
import { StatusBadge } from './common/status-badge'
import { TimeAgo } from './common/time-ago'
import { resolveUnifiedStatus } from '../lib/unified-status'
import { keeperDisplayStatus } from '../lib/keeper-runtime-display'
import { isSubmitEnter } from '../lib/keyboard'
import { findKeeper } from '../lib/keeper-utils'
import { ActionButton } from './common/button'
import { TextInput } from './common/input'
import { keeperIdentityHint } from './common/keeper-identity'
import { IdPill } from './common/id-pill'
import { AgentJournalStream } from './agent-detail-journal'
import { AgentSessionReport } from './agent-detail-session-report'
import { AgentTimelineSection } from './agent-detail-timeline'
import { AgentWorkerBrief } from './agent-detail-worker'
import { AgentDetailMemory } from './agent-detail-memory'
import { CollapsibleSection } from './common/collapsible'
import { SessionTraceView } from './session-trace/session-trace-view'
import { selectedAgentName } from './agent-detail-selection'
import {
  loading,
  detailError,
  namespaceActivity,
  taskHistories,
  mentionText,
  sendingMention,
  selectedAgent,
  assignedTasks,
  missionAgentBrief,
  continuityBriefForAgent,
  closeAgentDetail,
  refreshAgentDetail,
  submitMention,
  setKeeperRedirect,
  agentFitness,
  type TaskHistoryRow,
} from './agent-detail-state'
import { openKeeperDetail } from './keeper-detail'
import { KeeperPhaseBadge } from './keeper-phase-indicator'
import { trimText } from '../lib/truncate'
import type { Task } from '../types'
import { DialogOverlay } from './common/dialog'
import { requestConfirm } from './common/confirm-dialog'
import { showToast } from './common/toast'
import { invalidateDashboardCache, refreshDashboard } from '../store'
import { purgeAgent } from '../api/actions'
import { ringFocusClasses } from './common/ring'

// Wire keeper redirect: keeper-linked agents open the keeper detail overlay
setKeeperRedirect((agentName: string) => {
  const keeper = findKeeper(agentName)
  if (keeper) {
    openKeeperDetail(keeper)
    return true
  }
  return false
})

/**
 * Pure filter for owned tasks.
 *
 * Case-insensitive substring match on `id`, `title`, `status`, and
 * `description`. Operators locate a task by its short id, a keyword from
 * the title, its lifecycle status (e.g. "done", "claimed"), or a phrase
 * from the description.
 *
 * Empty/whitespace query returns the input reference unchanged (no new
 * array allocation, preserves referential equality for memoisation).
 *
 * Input is never mutated.
 */
function filterOwnedTasks(
  tasks: readonly Task[],
  query: string,
): readonly Task[] {
  const needle = query.trim().toLowerCase()
  if (needle === '') return tasks
  return tasks.filter(task => {
    if (task.id.toLowerCase().includes(needle)) return true
    if (task.title.toLowerCase().includes(needle)) return true
    if (task.status && task.status.toLowerCase().includes(needle)) return true
    if (task.description && task.description.toLowerCase().includes(needle)) return true
    return false
  })
}

/**
 * Pure filter for task history rows.
 *
 * Case-insensitive substring match on `taskId` and `text`. A history row
 * is a rendered text blob plus the task it belongs to, so those are the
 * two searchable fields.
 *
 * Empty/whitespace query returns the input reference unchanged (no new
 * array allocation, preserves referential equality for memoisation).
 *
 * Input is never mutated.
 */
function filterTaskHistories(
  rows: readonly TaskHistoryRow[],
  query: string,
): readonly TaskHistoryRow[] {
  const needle = query.trim().toLowerCase()
  if (needle === '') return rows
  return rows.filter(row => {
    if (row.taskId.toLowerCase().includes(needle)) return true
    if (row.text && row.text.toLowerCase().includes(needle)) return true
    return false
  })
}

function TaskSummary({ task }: { task: Task }) {
  return html`
    <div class="v2-monitoring-row flex items-center gap-3 border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] hover:bg-[var(--color-bg-hover)] hover:border-[var(--color-border-strong)] transition-colors px-3 py-2.5 rounded-[var(--r-1)]">
      <${IdPill}>${task.id}<//>
      <span class="flex-1 text-sm text-[var(--color-fg-primary)] font-medium truncate">${task.title}</span>
      <${StatusBadge} status=${task.status} />
    </div>
  `
}

function TaskHistoryPanel({ row }: { row: TaskHistoryRow }) {
  return html`
    <div class="v2-monitoring-card border border-[var(--color-border-default)] rounded-[var(--r-1)] bg-[var(--color-bg-elevated)] p-4 hover:border-[var(--accent-30)] transition-colors group">
      <div class="mb-3">
        <${IdPill} class="group-hover:bg-[var(--accent-20)] transition-colors">${row.taskId}<//>
      </div>
      <pre class="m-0 whitespace-pre-wrap text-xs leading-relaxed text-[var(--color-fg-secondary)] font-mono">${row.text || '작업 이력 없음'}</pre>
    </div>
  `
}

function renderOwnedTasks(
  allTasks: readonly Task[],
  visibleTasks: readonly Task[],
  isFiltering: boolean,
) {
  if (allTasks.length === 0) {
    return html`<div class="h-full min-h-30"><${EmptyState} message="할당된 작업이 없습니다" compact /></div>`
  }
  if (isFiltering && visibleTasks.length === 0) {
    return html`<div class="py-4 text-center text-2xs text-[var(--color-fg-disabled)]">필터 결과 없음 (${allTasks.length} tasks)</div>`
  }
  return html`<div class="flex flex-col gap-3">${visibleTasks.map(t => html`<${TaskSummary} key=${t.id} task=${t} />`)}</div>`
}

function renderTaskHistories(
  allRows: readonly TaskHistoryRow[],
  visibleRows: readonly TaskHistoryRow[],
  isFiltering: boolean,
) {
  if (allRows.length === 0) {
    return html`<${EmptyState} message="작업 이력이 없습니다" compact />`
  }
  if (isFiltering && visibleRows.length === 0) {
    return html`<div class="py-4 text-center text-2xs text-[var(--color-fg-disabled)]">필터 결과 없음 (${allRows.length} rows)</div>`
  }
  return html`<div class="flex flex-col gap-3">${visibleRows.map(row => html`<${TaskHistoryPanel} key=${row.taskId} row=${row} />`)}</div>`
}

export function AgentDetailOverlay() {
  const agentName = selectedAgentName.value
  if (!agentName) return null
  const closeButtonRef = useRef<HTMLButtonElement>(null)

  const agent = selectedAgent()
  const keeper = findKeeper(agentName)
  const continuityBrief = continuityBriefForAgent(agentName)
  const missionBrief = missionAgentBrief(agentName)
  const ownedTasks = assignedTasks(agentName)
  const lines = namespaceActivity.value
  const taskQuery = useSignal('')
  const purgePending = useSignal(false)
  const historyRows = taskHistories.value
  const visibleOwnedTasks = useMemo(
    () => filterOwnedTasks(ownedTasks, taskQuery.value),
    [ownedTasks, taskQuery.value],
  )
  const visibleHistories = useMemo(
    () => filterTaskHistories(historyRows, taskQuery.value),
    [historyRows, taskQuery.value],
  )
  const isFilteringTasks = taskQuery.value.trim() !== ''
  const displayName = missionBrief?.display_name ?? keeper?.name ?? agentName
  const secondaryLabel = displayName !== agentName ? agentName : null
  const keeperStatus = keeper ? keeperDisplayStatus(keeper, agent?.status) : null
  const unified = resolveUnifiedStatus(keeperStatus, agent?.status, missionBrief?.signal_truth)
  const isArchivedParticipant = !agent && missionBrief?.is_live === false
  const lastSeenAt =
    agent?.last_seen
    ?? missionBrief?.last_activity_at
    ?? null
  const agentEmoji = agent?.emoji ?? keeper?.emoji
  const rawKoreanName = agent?.koreanName ?? keeper?.koreanName
  // Don't show koreanName if it's actually an agent runtime name, not Korean text
  const koreanName = rawKoreanName && rawKoreanName !== agentName && rawKoreanName !== displayName
    ? rawKoreanName : null
  const continuitySummary =
    trimText(continuityBrief?.continuity_summary, 160)
    ?? trimText(continuityBrief?.skill_route_summary, 160)
    ?? null
  const keeperIdentity = keeperIdentityHint(keeper?.name, keeper?.agent_name)
  // Skip secondaryLabel when keeperIdentity already shows the agent runtime name
  const showSecondaryLabel = secondaryLabel && !keeperIdentity
  const titleId = `agent-detail-title-${agentName}`

  const handlePurge = () => {
    void (async () => {
      const targetLabel = keeper ? `${displayName} 키퍼` : displayName
      const confirmed = await requestConfirm({
        title: '에이전트 완전 삭제',
        message: `${targetLabel}를 완전 삭제합니다.\n런타임 상태, 인증, metrics가 제거되고 keeper면 config/keepers TOML도 함께 삭제됩니다.`,
        tone: 'danger',
        confirmText: '완전 삭제',
      })
      if (!confirmed) return
      purgePending.value = true
      try {
        const result = await purgeAgent(agentName)
        closeAgentDetail()
        invalidateDashboardCache()
        await refreshDashboard({ force: true })
        showToast(
          result.target_kind === 'keeper'
            ? `${displayName} 완전 삭제됨`
            : `${agentName} 삭제됨`,
          'success',
        )
      } catch (err) {
        showToast(err instanceof Error ? err.message : '에이전트 삭제 실패', 'error')
      } finally {
        purgePending.value = false
      }
    })()
  }

  return html`
    <${DialogOverlay}
      labelledBy=${titleId}
      onClose=${closeAgentDetail}
      initialFocusRef=${closeButtonRef}
      overlayClass="agent-detail-overlay fixed inset-0 z-[60] bg-[var(--dialog-overlay-bg)]/60 backdrop-blur-sm isolate flex items-center justify-center p-6 animate-in fade-in duration-[var(--t-med)]"
      panelClass="v2-monitoring-detail w-[min(1080px,100%)] max-h-[90vh] overflow-y-auto rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)]/95 backdrop-blur-sm shadow-[var(--elev-6-shadow)] ring-1 ring-white/5"
    >
      <div class="p-6 flex flex-col gap-5">
        <div class="flex justify-between items-start gap-4">
          <div class="flex flex-col gap-3 flex-1">
            <div class="flex items-center gap-4">
              ${agentEmoji ? html`<div class="size-12 rounded-[var(--r-1)] bg-[var(--color-bg-elevated)] border border-[var(--color-border-default)] flex items-center justify-center text-3xl shadow-inset">${agentEmoji}</div>` : ''}
              <div>
                <h2 id=${titleId} class="m-0 flex items-baseline gap-3 text-[var(--color-fg-primary)] text-2xl font-bold tracking-tight">
                  ${displayName}
                  ${koreanName ? html`<span class="text-sm text-[var(--color-fg-muted)] font-medium tracking-normal">(${koreanName})</span>` : ''}
                  ${showSecondaryLabel ? html`<span class="font-mono text-xs text-[var(--color-fg-muted)] bg-[var(--color-bg-elevated)] px-2 py-0.5 rounded-[var(--r-1)]">${secondaryLabel}</span>` : ''}
                </h2>
                <div class="flex items-center gap-2 mt-2 flex-wrap">
                  <${StatusBadge} status=${unified.canonical} />
                  ${keeper ? html`<${KeeperPhaseBadge} phase=${keeper.phase} compact=${true} />` : null}
                  ${unified.description !== unified.label ? html`<span class="text-2xs font-medium py-1 px-2 border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] text-[var(--color-fg-secondary)] whitespace-nowrap rounded-[var(--r-1)]" title=${unified.description}>${unified.description}</span>` : null}
                  ${isArchivedParticipant ? html`<${IdPill}>이전 세션 참여자<//>` : null}
                  ${!agent && missionBrief?.archived_reason
                    ? html`<span class="text-xs text-[var(--color-fg-secondary)] italic">${missionBrief.archived_reason}</span>`
                    : null}
                </div>
              </div>
            </div>
            <div class="mt-2 flex gap-3 flex-wrap text-[var(--color-fg-secondary)] text-sm font-medium">
              ${agent?.current_task || missionBrief?.current_work
                ? html`<span class="bg-[var(--color-bg-elevated)] px-3 py-1.5 rounded-[var(--r-1)] border border-[var(--color-border-default)]">태스크: <span class="text-[var(--color-fg-primary)]">${agent?.current_task ?? missionBrief?.current_work}</span></span>`
                : null}
              ${lastSeenAt ? html`<span class="bg-[var(--color-bg-elevated)] px-3 py-1.5 rounded-[var(--r-1)] border border-[var(--color-border-default)]">마지막 확인: <span class="text-[var(--color-fg-primary)]"><${TimeAgo} timestamp=${lastSeenAt} /></span></span>` : null}
            </div>
            ${keeper || continuitySummary || missionBrief?.related_session_id
              ? html`
                  <div class="mt-1 flex gap-3 flex-wrap text-[var(--color-fg-secondary)] text-sm font-medium">
                    ${keeper
                      ? html`<span class="flex items-center gap-1.5">연결된 키퍼:
                          <button
                            type="button"
                            class=${`text-[var(--color-fg-primary)] font-semibold hover:text-[var(--color-accent-fg)] underline underline-offset-2 decoration-dotted transition-colors ${ringFocusClasses({ tone: 'accent-soft', width: 2 })} rounded-[var(--r-1)]`}
                            onClick=${() => { closeAgentDetail(); openKeeperDetail(keeper) }}
                            title="키퍼 상세 페이지 열기"
                            aria-label="${keeper.name} 키퍼 상세 보기"
                          >${keeper.name}</button>
                          <${KeeperPhaseBadge} phase=${keeper.phase} compact=${true} />
                          ${keeperIdentity ? html`<span class="text-[var(--color-fg-secondary)] text-xs"><span aria-hidden="true">· </span>${keeperIdentity}</span>` : ''}
                        </span>`
                      : null}
                    ${missionBrief?.related_session_id ? html`<span class="flex items-center gap-1.5">세션: <strong class="font-mono text-[var(--color-fg-primary)] text-xs bg-[var(--color-bg-elevated)] px-1.5 rounded-[var(--r-1)]">${missionBrief.related_session_id}</strong></span>` : null}
                    ${continuitySummary ? html`<span class="text-[var(--color-accent-fg)]/90 bg-[var(--accent-10)] px-2 py-0.5 rounded-[var(--r-1)] border border-[var(--accent-10)]">${continuitySummary}</span>` : null}
                  </div>
                `
              : null}
          </div>
          <div class="flex gap-2 shrink-0">
            <${ActionButton}
              variant="ghost"
              size="lg"
              class="px-4 py-2 text-sm rounded-[var(--r-1)] bg-[var(--color-bg-surface)]/60"
              onClick=${() => { void refreshAgentDetail() }}
              disabled=${loading.value}
            >
              ${loading.value ? '새로고침 중...' : '새로고침'}
            <//>
            <${ActionButton}
              variant="danger"
              size="lg"
              class="px-4 py-2 text-sm rounded-[var(--r-1)]"
              onClick=${handlePurge}
              disabled=${purgePending.value}
            >
              ${purgePending.value ? '삭제 중...' : '완전 삭제'}
            <//>
            <button
              ref=${closeButtonRef}
              type="button"
              class=${`v2-monitoring-action px-4 py-2 text-sm font-semibold rounded-[var(--r-1)] border border-transparent bg-[var(--color-bg-hover)] text-[var(--color-fg-primary)] hover:bg-[var(--color-bg-hover)] transition-colors duration-[var(--t-med)] ${ringFocusClasses({ tone: 'accent-medium', width: 2, offset: 2, offsetSurface: 'surface' })}`}
              onClick=${closeAgentDetail}
            >
              닫기
            </button>
          </div>
        </div>

        ${detailError.value ? html`<${ErrorState} message=${detailError.value} />` : null}

        <${AgentSessionReport} agentName=${agentName} />

        <${CollapsibleSection} title="활동 추적" badge=${html`<span class="text-3xs text-[var(--color-fg-disabled)] font-normal ml-1">통합 타임라인</span>`}>
          <${SessionTraceView} agentName=${agentName} isKeeper=${!!keeper} />
        <//>

        <div class="flex items-center justify-between gap-2">
          <div class="text-2xs uppercase tracking-wider text-[var(--color-fg-secondary)]">
            작업 필터
            ${isFilteringTasks
              ? html`<span class="ml-2 normal-case tracking-normal text-[var(--color-fg-muted)]">할당 ${visibleOwnedTasks.length}/${ownedTasks.length} · 이력 ${visibleHistories.length}/${historyRows.length}</span>`
              : null}
          </div>
          <${TextInput}
            type="search"
            class="min-w-40 max-w-70 flex-1 !px-2 !py-1 !text-2xs"
            value=${taskQuery.value}
            placeholder="id / title / status 필터"
            ariaLabel="작업 필터"
            onInput=${(e: Event) => { taskQuery.value = (e.target as HTMLInputElement).value }}
          />
        </div>

        <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
          <${SectionCard} label="할당된 작업">
            ${renderOwnedTasks(ownedTasks, visibleOwnedTasks, isFilteringTasks)}
          <//>

          ${lines.length > 0
            ? html`<${SectionCard} label="최근 활동">
              <div role="log" aria-label="최근 활동 로그" class="max-h-60 overflow-y-auto flex flex-col gap-2 pr-1 custom-scrollbar">${lines.map((line: string, idx: number) => html`<div key=${idx} class="v2-monitoring-row border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-3 py-2.5 font-mono text-xs text-[var(--color-fg-primary)] leading-relaxed rounded-[var(--r-1)] hover:bg-[var(--color-bg-hover)] hover:border-[var(--color-border-strong)] transition-colors">${line}</div>`)}</div>
            <//>`
            : null}
        </div>

        <div class="flex flex-col gap-5">
          <${AgentJournalStream} agentName=${agentName} />
          <${AgentTimelineSection} />
          <${AgentDetailMemory} agentName=${agentName} />
          <${AgentWorkerBrief} agentName=${agentName} />
          ${agentFitness.value ? html`
            <${CollapsibleSection} title="적합도 (7일)" mountWhenOpen=${true}>
              <div class="grid grid-cols-2 sm:grid-cols-4 gap-3">
                ${([
                  ['완료율', agentFitness.value.completion_rate],
                  ['신뢰도', agentFitness.value.reliability_score],
                  ['속도', agentFitness.value.speed_score],
                  ['종합', agentFitness.value.overall_fitness],
                ] as [string, number][]).map(([label, val]) => html`
                  <div class="v2-monitoring-card rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] p-3 text-center">
                    <div class="text-2xs font-semibold uppercase tracking-wider text-[var(--color-fg-secondary)] mb-1">${label}</div>
                    <div class="text-lg font-bold ${val >= 0.7 ? 'text-[var(--color-status-ok)]' : val >= 0.4 ? 'text-[var(--color-status-warn)]' : 'text-[var(--bad-light)]'}">${formatPct(val)}</div>
                  </div>
                `)}
              </div>
            <//>
          ` : null}

          <${CollapsibleSection} title=${`작업 이력 (${historyRows.length})`} mountWhenOpen=${true}>
            ${renderTaskHistories(historyRows, visibleHistories, isFilteringTasks)}
          <//>

          <${SectionCard} label="직접 멘션">
            <div class="grid grid-cols-[1fr_auto] gap-3">
              <${TextInput}
                class="px-4 py-2.5 rounded-[var(--r-1)] bg-[var(--color-bg-surface)] text-[var(--color-fg-primary)] text-sm placeholder:text-[var(--color-fg-muted)] shadow-inset"
                value=${mentionText.value}
                name="agent_direct_mention"
                ariaLabel="직접 멘션 메시지"
                autoComplete="off"
                placeholder="@멘션 메시지 입력…"
                onInput=${(e: Event) => { mentionText.value = (e.target as HTMLInputElement).value }}
                onKeyDown=${(e: KeyboardEvent) => { if (isSubmitEnter(e)) void submitMention() }}
                disabled=${sendingMention.value}
              />
              <${ActionButton}
                variant="primary"
                size="lg"
                class="px-5 py-2.5 text-sm shadow-accent-fg/20"
                onClick=${() => { void submitMention() }}
                disabled=${sendingMention.value || mentionText.value.trim() === ''}
              >
                ${sendingMention.value ? '전송 중...' : '전송하기'}
              <//>
            </div>
          <//>
        </div>
      </div>
    <//>
  `
}
