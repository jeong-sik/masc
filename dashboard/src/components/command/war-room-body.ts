import { html } from 'htm/preact'
import { EmptyState } from '../common/empty-state'
import type {
  CommandPlaneChainOverlay,
  CommandPlaneSwarmBlocker,
  CommandPlaneSwarmLane,
  CommandPlaneSwarmResponse,
  OperatorLinkedAutoresearch,
  OperatorSessionSnapshot,
  PendingConfirmation,
} from '../../types'
import {
  deadlineLabel,
  displayStatus,
  formatElapsed,
  relativeTime,
  sessionStatusTone,
  toneClass,
} from './helpers'
import {
  SwarmBlockerCard,
  SwarmHealthBar,
  SwarmRunResolutionCard,
  SwarmStoryboard,
} from './swarm'
import { TraceRow } from './topology'
import {
  WarRoomFeedCard,
  WarRoomPresenceCard,
  WarRoomWorkerCard,
} from './war-room-panels'
import type {
  WarRoomFeedItem,
  WarRoomPresenceView,
  WarRoomWorkerView,
} from './war-room-panels'
import { WarRoomOrchestrationRail } from './war-room-metrics'

type WarRoomBodyProps = {
  wallboard: boolean
  liveLanes: CommandPlaneSwarmLane[]
  selectedSession: OperatorSessionSnapshot | null
  chainOverlay: CommandPlaneChainOverlay | null
  linkedAutoresearch?: OperatorLinkedAutoresearch | null
  workers: WarRoomWorkerView[]
  feedItems: WarRoomFeedItem[]
  swarm?: CommandPlaneSwarmResponse | null
  agentViews: WarRoomPresenceView[]
  keeperViews: WarRoomPresenceView[]
  swarmHasEvidence: boolean
  blockers: CommandPlaneSwarmBlocker[]
  pendingApprovals: number
  pendingConfirmTotal: number
  pendingConfirmVisible: number
  pendingConfirmHidden: number
  pendingConfirms: PendingConfirmation[]
  activeLane: CommandPlaneSwarmLane | null
}

export function WarRoomBodyGrid({
  wallboard,
  liveLanes,
  selectedSession,
  chainOverlay,
  linkedAutoresearch,
  workers,
  feedItems,
  swarm,
  agentViews,
  keeperViews,
  swarmHasEvidence,
  blockers,
  pendingApprovals,
  pendingConfirmTotal,
  pendingConfirmVisible,
  pendingConfirmHidden,
  pendingConfirms,
  activeLane,
}: WarRoomBodyProps) {
  return html`
    <div class="grid gap-4 items-start cmd-warroom-grid ${wallboard ? 'wallboard' : ''}">
      <div class="flex flex-col gap-4 min-w-0">
        <section class="card rounded-xl min-h-[240px]">
          <div class="card rounded-xl-title-row">
            <div class="card rounded-xl-title">실행 흐름</div>
          </div>
          ${liveLanes.length > 0
            ? html`
                <${SwarmStoryboard} lanes=${liveLanes} />
                <${SwarmHealthBar} lanes=${liveLanes} />
              `
            : selectedSession
              ? html`
                  <article class="bg-[var(--white-4)] border border-[var(--white-8)] p-3.5 rounded-xl cmd-guide-card">
                    <div class="flex justify-between gap-2.5 items-start">
                      <strong>${selectedSession.session_id}</strong>
                      <span class="cmd-chip rounded-full ${toneClass(sessionStatusTone(selectedSession.status))}">${displayStatus(selectedSession.status)}</span>
                    </div>
                    <p>스웜 실시간 증거는 아직 약합니다. 이 카드는 세션 요약과 워커 기록을 기준으로 유지합니다.</p>
                    <div class="cmd-card rounded-xl-grid">
                      <span>진행률</span><span>${selectedSession.progress_pct != null ? `${selectedSession.progress_pct}%` : '정보 없음'}</span>
                      <span>경과</span><span>${formatElapsed(selectedSession.elapsed_sec)}</span>
                      <span>남은 시간</span><span>${formatElapsed(selectedSession.remaining_sec)}</span>
                    </div>
                  </article>
                `
              : html`<${EmptyState} message="보이는 레인이 아직 없습니다." compact />`}
        </section>

        <section class="card rounded-xl min-h-[240px]">
          <div class="card rounded-xl-title-row">
            <div class="card rounded-xl-title">오케스트레이션</div>
          </div>
          <${WarRoomOrchestrationRail} chainOverlay=${chainOverlay} linkedAutoresearch=${linkedAutoresearch} />
        </section>

        <section class="card rounded-xl min-h-[240px]">
          <div class="card rounded-xl-title-row">
            <div class="card rounded-xl-title">워커 현황</div>
          </div>
          ${workers.length > 0
            ? html`<div class="cmd-card rounded-xl-stack">
                ${workers.map(worker => html`<${WarRoomWorkerCard} worker=${worker} />`)}
              </div>`
            : html`<${EmptyState} message="활성 워커 카드가 아직 없습니다." compact />`}
        </section>
      </div>

      <div class="flex flex-col gap-4 min-w-0">
        <section class="card rounded-xl min-h-[240px]">
          <div class="card rounded-xl-title-row">
            <div class="card rounded-xl-title">상황 피드</div>
          </div>
          ${feedItems.length > 0
            ? html`<div class="flex flex-col gap-3">
                ${feedItems.map(item => html`<${WarRoomFeedCard} item=${item} />`)}
              </div>`
            : html`<${EmptyState} message="메시지, chain, autoresearch, attention feed가 아직 없습니다." compact />`}
        </section>

        <section class="card rounded-xl min-h-[240px]">
          <div class="card rounded-xl-title-row">
            <div class="card rounded-xl-title">트레이스 흐름</div>
          </div>
          ${swarm && swarm.recent_trace_events.length > 0
            ? html`<div class="flex flex-col gap-3">
                ${swarm.recent_trace_events.map(event => html`<${TraceRow} event=${event} />`)}
              </div>`
            : html`<${EmptyState} message="실행 범위 트레이스 이벤트가 아직 없습니다." compact />`}
        </section>
      </div>

      <div class="flex flex-col gap-4 min-w-0">
        <section class="card rounded-xl min-h-[240px]">
          <div class="card rounded-xl-title-row">
            <div class="card rounded-xl-title">Agents</div>
          </div>
          ${agentViews.length > 0
            ? html`<div class="grid grid-cols-1 gap-3">
                ${agentViews.map(item => html`<${WarRoomPresenceCard} item=${item} />`)}
              </div>`
            : html`<${EmptyState} message="가시적인 active agent가 아직 없습니다." compact />`}
        </section>

        <section class="card rounded-xl min-h-[240px]">
          <div class="card rounded-xl-title-row">
            <div class="card rounded-xl-title">Keepers</div>
          </div>
          ${keeperViews.length > 0
            ? html`<div class="grid grid-cols-1 gap-3">
                ${keeperViews.map(item => html`<${WarRoomPresenceCard} item=${item} />`)}
              </div>`
            : html`<${EmptyState} message="가시적인 keeper/runtime 카드가 아직 없습니다." compact />`}
        </section>

        <section class="card rounded-xl min-h-[240px]">
          <div class="card rounded-xl-title-row">
            <div class="card rounded-xl-title">압력</div>
          </div>
          <div class="cmd-card rounded-xl-stack">
            ${swarmHasEvidence && swarm ? html`<${SwarmRunResolutionCard} swarm=${swarm} />` : null}
            ${blockers.length > 0
              ? blockers.map(blocker => html`<${SwarmBlockerCard} blocker=${blocker} />`)
              : html`<div class="bg-[var(--white-4)] border border-[var(--white-8)] p-3.5 rounded-xl cmd-guide-card ok"><p>지금 보이는 blocker는 없습니다.</p></div>`}
            ${pendingApprovals > 0
              ? html`
                  <article class="bg-[var(--white-4)] border border-[var(--white-8)] p-3.5 rounded-xl cmd-guide-card warn">
                    <div class="flex justify-between gap-2.5 items-start">
                      <strong>승인 대기</strong>
                      <span class="cmd-chip rounded-full warn">${pendingApprovals}</span>
                    </div>
                    <p>엄격 액션이 묶여 있습니다. 실제 승인 처리는 제어 표면에서 합니다.</p>
                  </article>
                `
              : null}
            ${pendingConfirmTotal > 0
              ? html`
                  <article class="bg-[var(--white-4)] border border-[var(--white-8)] p-3.5 rounded-xl cmd-guide-card warn">
                    <div class="flex justify-between gap-2.5 items-start">
                      <strong>확인 대기</strong>
                      <span class="cmd-chip rounded-full warn">${pendingConfirmHidden > 0 ? `${pendingConfirmVisible}/${pendingConfirmTotal}` : pendingConfirmTotal}</span>
                    </div>
                    <p>
                      운영자 미리보기가 사람 확인을 기다리고 있습니다.
                      ${pendingConfirmHidden > 0 ? ` 현재 actor 기준으로는 ${pendingConfirmVisible}건만 보입니다.` : ''}
                    </p>
                    <div class="cmd-tag rounded-full-row">
                      ${pendingConfirms.slice(0, 3).map(item => html`<span class="cmd-tag rounded-full">${item.confirm_token}</span>`)}
                    </div>
                  </article>
                `
              : null}
            ${activeLane
              ? html`
                  <article class="cmd-card rounded-xl p-3">
                    <div class="cmd-card rounded-xl-head">
                      <div>
                        <strong>${activeLane.label}</strong>
                        <div class="cmd-card rounded-xl-sub">${activeLane.kind} · ${activeLane.phase}</div>
                      </div>
                      <span class="cmd-chip rounded-full ${toneClass(sessionStatusTone(activeLane.motion_state))}">${displayStatus(activeLane.motion_state)}</span>
                    </div>
                    <div class="cmd-card rounded-xl-grid">
                      <span>현재 단계</span><span>${activeLane.current_step}</span>
                      <span>이동 사유</span><span>${activeLane.movement_reason}</span>
                      <span>막힘 수</span><span>${activeLane.blockers.length}</span>
                      <span>최근 이동</span><span>${relativeTime(activeLane.last_movement_at)}</span>
                    </div>
                  </article>
                `
              : null}
            ${swarmHasEvidence && swarm?.detachment
              ? html`
                  <article class="cmd-card rounded-xl p-3">
                    <div class="cmd-card rounded-xl-head">
                      <div>
                        <strong>${swarm.detachment.detachment_id}</strong>
                        <div class="cmd-card rounded-xl-sub">${swarm.detachment.assigned_unit_id}</div>
                      </div>
                      <span class="cmd-chip rounded-full ${toneClass(sessionStatusTone(swarm.detachment.status))}">${displayStatus(swarm.detachment.status ?? 'active')}</span>
                    </div>
                    <div class="cmd-card rounded-xl-grid">
                      <span>리더</span><span>${swarm.detachment.leader_id ?? '미지정'}</span>
                      <span>편성</span><span>${swarm.detachment.roster.length}</span>
                      <span>세션</span><span>${swarm.detachment.session_id ?? '연결 없음'}</span>
                      <span>하트비트</span><span>${deadlineLabel(swarm.detachment.heartbeat_deadline)}</span>
                    </div>
                  </article>
                `
              : selectedSession
                ? html`
                    <article class="cmd-card rounded-xl p-3">
                      <div class="cmd-card rounded-xl-head">
                        <div>
                          <strong>${selectedSession.session_id}</strong>
                          <div class="cmd-card rounded-xl-sub">현재 세션 기준</div>
                        </div>
                        <span class="cmd-chip rounded-full ${toneClass(sessionStatusTone(selectedSession.status))}">${displayStatus(selectedSession.status)}</span>
                      </div>
                      <div class="cmd-card rounded-xl-grid">
                        <span>진행률</span><span>${selectedSession.progress_pct != null ? `${selectedSession.progress_pct}%` : '정보 없음'}</span>
                        <span>경과</span><span>${formatElapsed(selectedSession.elapsed_sec)}</span>
                        <span>남은 시간</span><span>${formatElapsed(selectedSession.remaining_sec)}</span>
                        <span>완료 변화량</span><span>${selectedSession.done_delta_total ?? 0}</span>
                      </div>
                    </article>
                  `
                : null}
          </div>
        </section>
      </div>
    </div>
  `
}
