import { html } from 'htm/preact'
import { useSignal } from '@preact/signals'
import { useMemo } from 'preact/hooks'
import { Card } from './common/card'
import { EmptyState } from './common/empty-state'
import { LoadingState } from './common/feedback-state'
import { StatCell } from './common/stat-cell'
import { TagBadge } from './common/tag-badge'
import { ListItem } from './common/list-item'
import { ActionBar, ActionBtn } from './common/action-bar'
import { StatusChip } from './common/status-chip'
import { openAgentDetail } from './agent-detail'
import { SessionFlowCard } from './mission-session-flow'
import { CollapsibleSection } from './common/collapsible'
import { WorkerRunEvidenceRow } from './proof-sections'
import type {
  DashboardMissionSessionCard,
  DashboardMissionSessionDetailResponse,
  DashboardProofWorkerRunEvidence,
} from '../types'
import {
  toneClass,
  relativeTime,
  formatDuration,
  statusLabel,
  toggleSession,
  openActionIntervene,
  openSession,
  liveStateClass,
  dotStateBg,
} from './mission-utils'

/**
 * Pure filter for worker-run evidence rows.
 *
 * Case-insensitive substring match over the human-readable identifier
 * fields an operator would use to locate a run: `worker_run_id`,
 * `worker_name`, `status`, and `requested_model`. Null/missing values
 * are skipped safely.
 *
 * Empty/whitespace query returns the input reference unchanged so
 * callers memoising on ref equality do not re-render.
 *
 * Input is never mutated.
 */
export function filterWorkerRuns(
  runs: readonly DashboardProofWorkerRunEvidence[],
  query: string,
): readonly DashboardProofWorkerRunEvidence[] {
  const needle = query.trim().toLowerCase()
  if (needle === '') return runs
  return runs.filter(run => {
    if (run.worker_run_id.toLowerCase().includes(needle)) return true
    if (run.worker_name && run.worker_name.toLowerCase().includes(needle)) return true
    if (run.status && run.status.toLowerCase().includes(needle)) return true
    if (run.requested_model && run.requested_model.toLowerCase().includes(needle)) return true
    return false
  })
}

export function SessionBriefCard({
  brief,
  selected,
}: {
  brief: DashboardMissionSessionCard
  selected: boolean
}) {
  const members = brief.member_previews.slice(0, 4)
  const action = brief.top_recommendation ?? null
  const incident = brief.top_attention ?? null
  const liveCount = brief.active_count ?? 0
  const seenCount = brief.seen_count ?? liveCount
  const plannedCount = brief.planned_count ?? brief.member_names.length

  return html`
    <article class="mission-crew-card p-4 rounded-xl border border-[var(--white-8)] bg-[linear-gradient(180deg,var(--white-5),var(--white-3))] grid gap-3 ${toneClass(brief.top_attention?.severity ?? brief.health ?? brief.status)} ${liveStateClass(brief.status, brief.health)} ${selected ? 'is-selected' : ''}">
      <button type="button" class="w-full p-0 border-0 bg-transparent text-inherit grid gap-3 text-left cursor-pointer" onClick=${() => toggleSession(brief.session_id)}>
        <div class="flex justify-between gap-3 items-start flex-wrap">
          <div>
            <div class="flex items-center gap-2">
              <div class="mission-status-dot ${liveStateClass(brief.status, brief.health)} ${dotStateBg(liveStateClass(brief.status, brief.health))}"></div>
              <strong>${brief.goal}</strong>
            </div>
            <div class="text-[var(--text-muted)] text-[13px] mt-1">${brief.session_id}${brief.namespace ? ` · ${brief.namespace}` : ''}</div>
          </div>
          <${StatusChip} label=${statusLabel(brief.status)} tone=${toneClass(brief.top_attention?.severity ?? brief.health ?? brief.status)} />
        </div>

        <div class="grid grid-cols-2 gap-3">
          <${StatCell} label="멤버" value=${brief.member_names.length} detail=${brief.member_names.slice(0, 3).join(', ') || '없음'} />
          <${StatCell} label="가동 시간" value=${formatDuration(brief.elapsed_sec)} detail=${brief.started_at ? `${relativeTime(brief.started_at)} 시작` : '시작 시각 없음'} />
          <${StatCell} label="최근 흐름" value=${brief.last_event_at ? relativeTime(brief.last_event_at) : '기록 없음'} detail=${brief.communication_summary ?? '요약 없음'} />
          <${StatCell} label="충원 상태" value=${`${liveCount}/${brief.required_count || 1}`} detail=${`live · seen ${seenCount} · planned ${plannedCount}`} />
        </div>
      </button>

      ${brief.blocker_summary ? html`<div class="grid gap-1.5 px-1">막힘 · ${brief.blocker_summary}</div>` : null}
      ${brief.counts_basis ? html`<div class="grid gap-1.5 px-1">관측 기준 · ${brief.counts_basis}</div>` : null}

      <div class="grid gap-1.5 px-1">
        <span>최근 사건</span>
        <strong>${brief.last_event_summary ?? '최근 세션 이벤트가 없습니다.'}</strong>
        <small>${brief.last_event_at ? relativeTime(brief.last_event_at) : '시각 없음'}</small>
      </div>

      ${brief.operation_badges.length > 0
        ? html`
            <div class="flex gap-3 flex-wrap">
              ${brief.operation_badges.slice(0, 3).map(operation => html`
                <${TagBadge}>${operation.operation_id} · ${statusLabel(operation.status)}${operation.stage ? ` · ${operation.stage}` : ''}<//>
              `)}
            </div>
          `
        : null}

      ${members.length > 0
        ? html`
            <div class="grid grid-cols-2 gap-3">
              ${members.map(member => html`
                <${ListItem}
                  title=${member.agent_name}
                  subtitle=${html`${member.current_work ?? '현재 작업 없음'}${member.is_live === false ? ' · archived' : member.is_live === true ? ' · live' : ''}`}
                  detail=${member.recent_output_preview ?? member.recent_input_preview ?? '최근 입출력 없음'}
                  onClick=${() => openAgentDetail(member.agent_name)}
                />
              `)}
            </div>
          `
        : null}

      <${ActionBar}>
        <${ActionBtn} label="세션 개입 열기" onClick=${() => openSession('intervene', brief.session_id)} />
        <${ActionBtn} label="세션 개입 준비" onClick=${() => openSession('command', brief.session_id)} />
        ${action
          ? html`<${ActionBtn} label="추천 액션 열기" onClick=${() => openActionIntervene(action, incident, '상황판 세션 요약')} />`
          : null}
      <//>
    </article>
  `
}

export function SessionDetailCard({
  detail,
  loading,
  error,
}: {
  detail: DashboardMissionSessionDetailResponse | null
  loading: boolean
  error: string | null
}) {
  const workerRunsQuery = useSignal('')
  const rawRecentRuns = detail?.worker_runs?.recent_runs ?? null
  const filteredRecentRuns = useMemo(
    () => (rawRecentRuns ? filterWorkerRuns(rawRecentRuns, workerRunsQuery.value) : null),
    [rawRecentRuns, workerRunsQuery.value],
  )

  if (loading && !detail) {
    return html`
      <${Card} title="세션 상세" class="mission-list-card rounded-xl">
        <${LoadingState}>세션 상세 불러오는 중...<//>
      <//>
    `
  }

  if (error && !detail) {
    return html`
      <${Card} title="세션 상세" class="mission-list-card rounded-xl">
        <${EmptyState} message=${error} compact />
      <//>
    `
  }

  if (!detail?.session) {
    return null
  }

  const session = detail.session
  const workerRuns = detail.worker_runs ?? null
  const isFilteringWorkerRuns = workerRunsQuery.value.trim() !== ''
  return html`
    <${Card} title="세션 상세" class="mission-list-card rounded-xl">
      <div class="grid gap-1.5 mb-4">
        <h3 class="m-0 text-[var(--text-strong)] text-lg">${session.goal}</h3>
        <p class="m-0 text-[var(--text-body)] leading-normal">${session.session_id}${session.namespace ? ` · ${session.namespace}` : ''}</p>
      </div>

      ${error ? html`<div class="grid gap-1.5">${error}</div>` : null}

      <div class="mt-4">
        <${SessionFlowCard} detail=${detail} />
      </div>

      ${workerRuns
        ? html`
            <div class="border-t border-[var(--white-8)] mt-4 pt-4">
              <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)] mb-3">워커 런타임</div>
            </div>
            <div class="grid gap-4">
              <div class="flex justify-between gap-3 items-start flex-wrap">
                <strong>실행 현황</strong>
                <${StatusChip}
                  label=${`${workerRuns.completed_success_count ?? 0}/${workerRuns.requested_count ?? 0} 완료`}
                  tone=${(workerRuns.completed_failed_count ?? 0) > 0 ? 'warn' : 'ok'}
                />
              </div>

              <div class="grid grid-cols-2 gap-3">
                <${StatCell}
                  label="요청"
                  value=${workerRuns.requested_count ?? 0}
                  detail=${`in-flight ${workerRuns.in_flight_count ?? 0}`}
                />
                <${StatCell}
                  label="완료"
                  value=${workerRuns.completed_success_count ?? 0}
                  detail=${`실패 ${workerRuns.completed_failed_count ?? 0}`}
                />
                <${StatCell}
                  label="준비됨"
                  value=${workerRuns.ready_worker_count ?? 0}
                  detail=${workerRuns.ready_worker_names.join(', ') || '없음'}
                />
                <${StatCell}
                  label="보류"
                  value=${workerRuns.pending_worker_count ?? 0}
                  detail=${workerRuns.pending_worker_names.join(', ') || '없음'}
                />
              </div>

              <div class="grid grid-cols-2 gap-5">
                <div class="grid gap-3">
                  <div class="flex justify-between gap-3 items-start flex-wrap">
                    <strong>위임 준비 상태</strong>
                    <${StatusChip}
                      label=${String(workerRuns.worker_readiness.length)}
                      tone=${workerRuns.blocked_worker_names.length > 0 ? 'warn' : 'ok'}
                    />
                  </div>
                  <div class="flex flex-col gap-3">
                    ${workerRuns.worker_readiness.length > 0
                      ? workerRuns.worker_readiness.map(readiness => html`
                          <${ListItem}
                            title=${readiness.worker_name}
                            subtitle=${readiness.delegate_ready ? 'delegate ready' : readiness.blocked_reason ?? 'blocked'}
                            detail=${readiness.guidance ?? '추가 지침 없음'}
                          />
                        `)
                      : html`<${EmptyState} message="delegate readiness 기록이 없습니다." compact />`}
                  </div>
                </div>

                <div class="grid gap-3">
                  <div class="flex justify-between gap-3 items-start flex-wrap">
                    <strong>워커 상태 묶음</strong>
                    <${StatusChip}
                      label=${`${workerRuns.in_flight_actor_names.length} active`}
                      tone=${workerRuns.in_flight_actor_names.length > 0 ? 'warn' : 'ok'}
                    />
                  </div>
                  <div class="grid gap-2 text-[13px] text-[var(--text-body)]">
                    <div><span class="text-[var(--text-muted)]">실행 중</span> · ${workerRuns.in_flight_actor_names.join(', ') || '없음'}</div>
                    <div><span class="text-[var(--text-muted)]">위임 가능</span> · ${workerRuns.delegate_ready_worker_names.join(', ') || '없음'}</div>
                    <div><span class="text-[var(--text-muted)]">차단됨</span> · ${workerRuns.blocked_worker_names.join(', ') || '없음'}</div>
                  </div>
                </div>
              </div>

              <div class="grid gap-3">
                <div class="flex justify-between gap-3 items-start flex-wrap">
                  <strong>최근 워커 실행</strong>
                  <div class="flex items-center gap-2">
                    <input
                      type="search"
                      value=${workerRunsQuery.value}
                      placeholder="run / worker / status / model 필터"
                      aria-label="워커 실행 필터"
                      onInput=${(e: Event) => { workerRunsQuery.value = (e.target as HTMLInputElement).value }}
                      class="min-w-[160px] max-w-[240px] flex-1 rounded-md border border-[var(--white-10)] bg-[var(--white-4)] px-2 py-1 text-[11px] text-[var(--text-body)] placeholder:text-[var(--text-dim)] focus:outline-none focus:border-[var(--accent)]"
                    />
                    <${StatusChip}
                      label=${isFilteringWorkerRuns && filteredRecentRuns
                        ? `${filteredRecentRuns.length}/${workerRuns.recent_runs.length}`
                        : String(workerRuns.recent_runs.length)}
                    />
                  </div>
                </div>
                <div class="flex flex-col gap-3">
                  ${workerRuns.recent_runs.length === 0
                    ? html`<${EmptyState} message="최근 worker run 증거가 없습니다." compact />`
                    : filteredRecentRuns && filteredRecentRuns.length > 0
                      ? filteredRecentRuns.map(item => html`<${WorkerRunEvidenceRow} item=${item} />`)
                      : html`<div class="py-4 text-center text-[11px] text-[var(--text-dim)]">필터 결과 없음 (${workerRuns.recent_runs.length} runs)</div>`}
                </div>
              </div>
            </div>
          `
        : null}

      <div class="border-t border-[var(--white-8)] mt-4 pt-4">
        <div class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)] mb-3">타임라인 & 참여자</div>
      </div>
      <div class="grid grid-cols-2 gap-5">
        <div class="grid gap-3">
          <div class="flex justify-between gap-3 items-start flex-wrap">
            <strong>타임라인</strong>
            <${StatusChip} label=${String(detail.timeline.length)} />
          </div>
          <div class="flex flex-col gap-3">
            ${detail.timeline.length > 0
              ? detail.timeline.map(item => html`
                  <${ListItem}
                    title=${item.summary}
                    subtitle=${item.timestamp ? relativeTime(item.timestamp) : '시각 없음'}
                    detail=${html`${item.actor ? `${item.actor} · ` : ''}${item.event_type ?? '이벤트'}`}
                  />
                `)
              : html`<${EmptyState} message="표시할 세션 이벤트가 없습니다." compact />`}
          </div>
        </div>

        <div class="grid gap-3">
          <div class="flex justify-between gap-3 items-start flex-wrap">
            <strong>참여자</strong>
            <${StatusChip} label=${String(detail.participants.length)} />
          </div>
          <div class="flex flex-col gap-3">
            ${detail.participants.length > 0
              ? detail.participants.map(participant => html`
                  <${ListItem}
                    title=${participant.agent_name}
                    subtitle=${participant.current_work ?? '현재 작업 없음'}
                    detail=${html`${participant.recent_output_preview ?? participant.recent_input_preview ?? '최근 입출력 없음'}${participant.last_activity_at ? ` · ${relativeTime(participant.last_activity_at)}` : ''}`}
                    onClick=${() => openAgentDetail(participant.agent_name)}
                  />
                `)
              : html`<${EmptyState} message="세션 참여자 미리보기가 없습니다." compact />`}
          </div>
        </div>
      </div>

      <div class="mt-4">
        <${CollapsibleSection}
          title="작전 & 키퍼"
          badge=${html`<span class="text-[11px] text-[var(--text-muted)]">${detail.operations.length + detail.keepers.length}건</span>`}
        >
          <div class="grid grid-cols-2 gap-5">
            <div class="grid gap-3">
              <div class="flex justify-between gap-3 items-start flex-wrap">
                <strong>연결된 작전</strong>
                <${StatusChip} label=${String(detail.operations.length)} />
              </div>
              <div class="flex flex-col gap-3">
                ${detail.operations.length > 0
                  ? detail.operations.map(operation => html`
                      <${ListItem}
                        title=${operation.operation_id}
                        subtitle=${html`${statusLabel(operation.status)}${operation.stage ? ` · ${operation.stage}` : ''}`}
                        detail=${operation.detachment_status ?? operation.objective ?? '분견대 정보 없음'}
                        onClick=${() => openSession('command', session.session_id)}
                      />
                    `)
                  : html`<${EmptyState} message="연결된 작전이 없습니다." compact />`}
              </div>
            </div>

            <div class="grid gap-3">
              <div class="flex justify-between gap-3 items-start flex-wrap">
                <strong>연속성 관찰</strong>
                <${StatusChip} label=${String(detail.keepers.length)} />
              </div>
              <div class="flex flex-col gap-3">
                ${detail.keepers.length > 0
                  ? detail.keepers.map(keeper => html`
                      <${ListItem}
                        title=${keeper.name}
                        subtitle=${html`${statusLabel(keeper.status)}${keeper.generation != null ? ` · 세대 ${keeper.generation}` : ''}`}
                        detail=${keeper.current_work ?? '현재 작업 정보 없음'}
                      />
                    `)
                  : html`<${EmptyState} message="직접 연결된 키퍼는 없습니다." compact />`}
              </div>
            </div>
          </div>
        <//>
      </div>
    <//>
  `
}
