import { html } from 'htm/preact'
import { CmdStatCard } from './cmd-stat-card'
import type {
  CommandPlaneChainOverlay,
  CommandPlaneSwarmLane,
  CommandPlaneSwarmResponse,
  OperatorGuidanceSummary,
  OperatorResidentJudgeRuntime,
  OperatorSessionSnapshot,
} from '../../types'
import { navigate } from '../../router'
import { setCommandPlaneSurface } from '../../command-store'
import {
  displayStatus,
  relativeTime,
  surfaceRouteParams,
  toneClass,
} from './helpers'
import {
  guidanceFreshnessLabel,
  guidanceLayerLabel,
  guidanceLayerTone,
  runtimeJudgeLabel,
} from '../ops/helpers'
import { WarRoomJumpButton } from './war-room-metrics'

type WarRoomHeroProps = {
  wallboard: boolean
  stickyTone: 'ok' | 'warn' | 'bad'
  heroTitle: string
  heroSummary: string
  swarmHasEvidence: boolean
  swarm?: CommandPlaneSwarmResponse | null
  selectedSession: OperatorSessionSnapshot | null
  activeLane: CommandPlaneSwarmLane | null
  activeSummary?: OperatorGuidanceSummary | null
  guidanceLayer: string
  fullscreenActive: boolean
  workerJoined?: number | null
  workerExpected?: number | null
  workerCardCount: number
  blockersCount: number
  pendingApprovals: number
  pendingConfirmTotal: number
  pendingConfirmVisible: number
  pendingConfirmHidden: number
  residentRuntime?: OperatorResidentJudgeRuntime | null
  latestSignal?: string | null
  latestMessage?: string | null
  latestTrace?: string | null
  chainOverlay: CommandPlaneChainOverlay | null
  onRefresh: () => void
  onToggleFullscreen: () => void
}

function standardView() {
  if (document.fullscreenElement) {
    void document.exitFullscreen?.()
  }
  setCommandPlaneSurface('warroom')
  navigate('operations', surfaceRouteParams('warroom'))
}

export function WarRoomHeroStrip({
  wallboard,
  stickyTone,
  heroTitle,
  heroSummary,
  swarmHasEvidence,
  swarm,
  selectedSession,
  activeLane,
  activeSummary,
  guidanceLayer,
  fullscreenActive,
  workerJoined,
  workerExpected,
  workerCardCount,
  blockersCount,
  pendingApprovals,
  pendingConfirmTotal,
  pendingConfirmVisible,
  pendingConfirmHidden,
  residentRuntime,
  latestSignal,
  latestMessage,
  latestTrace,
  chainOverlay,
  onRefresh,
  onToggleFullscreen,
}: WarRoomHeroProps) {
  return html`
    <section class="sticky top-0 z-[3] flex flex-col gap-4 p-[18px] rounded-[18px] border border-[var(--white-8)] backdrop-blur-[18px] cmd-warroom-strip ${toneClass(stickyTone)} ${wallboard ? 'wallboard' : ''}">
      <div class="flex justify-between gap-3.5 items-start flex-wrap">
        <div>
          <span class="inline-flex w-fit items-center gap-2 py-[5px] px-[10px] rounded-full text-[#7dd3fc] bg-[rgba(14,116,144,0.22)] border border-solid border-[rgba(125,211,252,0.18)] text-[length:var(--fs-xs)] tracking-[0.08em] uppercase">${wallboard ? 'War Room Wallboard' : '실시간 워룸'}</span>
          <strong>${heroTitle}</strong>
          <div class="cmd-card rounded-xl-sub">
            ${swarmHasEvidence ? (swarm?.operation?.operation_id ?? '작전 정보 없음') : '세션 기준값'}
            ${selectedSession?.session_id ? ` · 세션 ${selectedSession.session_id}` : ''}
            ${swarmHasEvidence && swarm?.detachment?.detachment_id ? ` · 분견대 ${swarm.detachment.detachment_id}` : ''}
            ${activeLane ? ` · 대표 레인 ${activeLane.label}` : ''}
          </div>
          <div class="mt-3 text-[rgba(226,232,240,0.86)] leading-[1.55] max-w-[82ch]">${heroSummary}</div>
          ${activeSummary?.summary
            ? html`<div class="grid gap-1 mt-2.5 py-3 px-3 rounded-lg border border-[var(--white-8)] bg-[var(--white-4)] text-[rgba(255,255,255,0.84)] text-[length:var(--fs-sm)] leading-snug cmd-warroom-guidance ${guidanceLayerTone(guidanceLayer)}">
                <strong>${guidanceLayerLabel(guidanceLayer)}</strong>
                <span>${activeSummary.summary}</span>
              </div>`
            : null}
        </div>
        <div class="flex gap-2.5 flex-wrap items-start justify-end">
          <button class="control-btn rounded-lg ghost" onClick=${onRefresh}>새로고침</button>
          ${wallboard
            ? html`
                <button class="control-btn rounded-lg ghost" onClick=${onToggleFullscreen}>
                  ${fullscreenActive ? '전체 화면 해제' : '전체 화면'}
                </button>
                <button class="control-btn rounded-lg ghost" onClick=${standardView}>
                  표준 보기
                </button>
              `
            : null}
          <${WarRoomJumpButton}
            label="스웜 상세"
            surface="swarm"
            params=${{
              ...(swarmHasEvidence && swarm?.operation?.operation_id ? { operation_id: swarm.operation.operation_id } : {}),
              ...(swarmHasEvidence && swarm?.run_id ? { run_id: swarm.run_id } : {}),
            }}
          />
          ${chainOverlay
            ? html`<${WarRoomJumpButton}
                label="체인"
                surface="chains"
                params=${{ operation: chainOverlay.operation.operation_id }}
              />`
            : null}
          <${WarRoomJumpButton} label="개입" />
        </div>
      </div>
      <div class="grid grid-cols-[repeat(auto-fit,minmax(170px,1fr))] gap-3">
        <${CmdStatCard} label="워커" value=${`${workerJoined ?? 0}/${workerExpected ?? 0}`} detail=${`${swarmHasEvidence ? (swarm?.summary?.completed_workers ?? 0) : 0} 완료 · ${workerCardCount} 카드`} />
        <${CmdStatCard} label="런타임" value=${swarmHasEvidence ? (swarm?.provider?.runtime_blocker ? '막힘' : swarm?.provider?.provider_reachable ? '준비됨' : selectedSession ? displayStatus(selectedSession.status) : '확인 필요') : (selectedSession ? displayStatus(selectedSession.status) : '확인 필요')} detail=${swarmHasEvidence ? `설정 ${swarm?.provider?.configured_capacity ?? 'n/a'} · 실제 ${swarm?.provider?.actual_slots ?? swarm?.provider?.total_slots ?? 0} · hot ${swarm?.summary?.peak_hot_slots ?? swarm?.provider?.peak_active_slots ?? 0}` : `세션 워커 ${workerCardCount}`} />
        <${CmdStatCard} label="압력" value=${blockersCount + pendingApprovals + pendingConfirmTotal} detail=${`막힘 ${blockersCount} · 승인 ${pendingApprovals} · 확인 ${pendingConfirmVisible}${pendingConfirmHidden > 0 ? `/${pendingConfirmTotal}` : ''}`} tone=${toneClass(blockersCount > 0 || pendingApprovals > 0 || pendingConfirmTotal > 0 ? 'warn' : 'ok')} />
        <${CmdStatCard} label="상주 판정기" value=${runtimeJudgeLabel(residentRuntime)} detail=${`${guidanceFreshnessLabel(activeSummary)}${residentRuntime?.model_used ? ` · ${residentRuntime.model_used}` : ''}`} tone=${toneClass(guidanceLayerTone(guidanceLayer))} />
        <${CmdStatCard} label="마지막 신호" value=${relativeTime(latestSignal)} detail=${latestMessage ? '메시지' : latestTrace ? '트레이스' : '대기 중'} />
      </div>
    </section>
  `
}
