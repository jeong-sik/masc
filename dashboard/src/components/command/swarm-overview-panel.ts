import { html } from 'htm/preact'
import { CmdStatCard } from './cmd-stat-card'
import { EmptyState } from '../common/empty-state'
import { StatusChip } from '../common/status-chip'
import { route } from '../../router'
import { workflowContextForRoute } from '../../workflow-context'
import {
  currentCommandPlaneSummary,
  relativeTime,
  swarmFocusKey,
  toneClass,
} from './helpers'
import {
  SwarmEventNode,
  SwarmGapDot,
  SwarmProofPanel,
} from './swarm-cards'
import {
  SwarmHealthBar,
  SwarmLaneStrip,
  SwarmStoryboard,
} from './swarm-storyboard'

export function SwarmOverviewPanel() {
  const summary = currentCommandPlaneSummary()
  const workflowContext = workflowContextForRoute(route.value)
  const focusKey = swarmFocusKey(workflowContext)
  const swarm = summary?.swarm_status
  const proof = summary?.swarm_proof
  const lanes = swarm?.lanes.filter(lane => lane.present) ?? []
  const gaps = swarm?.gaps.items ?? []
  const timeline = swarm?.timeline.slice(0, 8) ?? []
  const overview = swarm?.overview
  const recommendation = swarm?.recommended_next_action
  const compactLayout = lanes.length <= 1

  return html`
    <section class="card rounded-xl min-h-[240px]">
      <div class="card rounded-xl-title-row">
        <div class="card rounded-xl-title">스웜</div>
      </div>
      ${swarm
        ? html`
            <${SwarmStoryboard} lanes=${lanes} />
            <div class="command-summary-grid mt-3">
              <${CmdStatCard} label="활성 레인" value=${overview?.active_lanes ?? 0} detail=${`${overview?.moving_lanes ?? 0}개 이동 중`} />
              <${CmdStatCard} label="정체" value=${overview?.stalled_lanes ?? 0} detail=${`${overview?.projected_lanes ?? 0}개 예상 레인`} />
              <${CmdStatCard} label="마지막 이동" value=${relativeTime(overview?.last_movement_at)} detail=${swarm.generated_at ? `스냅샷 ${relativeTime(swarm.generated_at)}` : '방금 스냅샷'} />
              <${CmdStatCard} label="다음 액션" value=${recommendation?.label ?? '운영자 상태 확인'} detail=${recommendation?.tool ?? 'masc_operator_snapshot'} />
            </div>

            ${lanes.length > 0 ? html`<${SwarmHealthBar} lanes=${lanes} />` : null}

            <div class="${compactLayout ? 'grid grid-cols-[minmax(0,1fr)] gap-4 mt-4' : 'grid grid-cols-[minmax(0,1.2fr)_minmax(0,0.8fr)] max-[1100px]:grid-cols-[minmax(0,1fr)] gap-4 mt-4'}">
              <div class="cmd-card rounded-xl-stack">
                ${lanes.length > 0
                  ? lanes.map(lane => html`<${SwarmLaneStrip} lane=${lane} />`)
                  : html`<${EmptyState} message="활성 스웜 레인이 없습니다." compact />`}
              </div>

              <div class="cmd-card rounded-xl-stack">
                <div class="bg-[var(--white-4)] border border-[var(--white-8)] p-4 rounded-xl cmd-guide-card highlight ${focusKey === 'recommendation' ? 'shadow-[0_0_0_1px_rgba(34,211,238,0.16)]' : ''}">
                  <div class="flex justify-between gap-3 items-start">
                    <strong>${recommendation?.label ?? '운영자 상태 확인'}</strong>
                    <${StatusChip} label=${recommendation?.lane_id ?? '전체'} />
                  </div>
                  <p>${recommendation?.reason ?? '보이는 활성 스웜 레인이 아직 없습니다.'}</p>
                  <div class="cmd-card rounded-xl-foot">${recommendation?.tool ?? 'masc_operator_snapshot'}</div>
                </div>

                <${SwarmProofPanel} proof=${proof} />

                <div class="bg-[var(--white-4)] border border-[var(--white-8)] p-4 rounded-xl cmd-guide-card ${gaps.length > 0 ? 'warn' : 'ok'} ${focusKey === 'gaps' ? 'shadow-[0_0_0_1px_rgba(34,211,238,0.16)]' : ''}">
                  <div class="flex justify-between gap-3 items-start">
                    <strong>핵심 공백</strong>
                    <${StatusChip} label=${String(gaps.length)} tone=${toneClass(gaps.some(gap => gap.severity === 'bad') ? 'bad' : gaps.length > 0 ? 'warn' : 'ok')} />
                  </div>
                  ${gaps.length > 0
                    ? html`<div class="border-l-2 border-[var(--card-border,var(--white-10))] pl-4 flex flex-col gap-0.5">${gaps.slice(0, 4).map(gap => html`<${SwarmGapDot} gap=${gap} />`)}</div>`
                    : html`<p>지금 보이는 핵심 공백은 없습니다.</p>`}
                </div>

                <div class="bg-[var(--white-4)] border border-[var(--white-8)] p-4 rounded-xl cmd-guide-card">
                  <div class="flex justify-between gap-3 items-start">
                    <strong>이동 타임라인</strong>
                    <${StatusChip} label=${String(timeline.length)} />
                  </div>
                  ${timeline.length > 0
                    ? html`<div class="border-l-2 border-[var(--card-border,var(--white-10))] pl-4 flex flex-col gap-0.5">${timeline.map(event => html`<${SwarmEventNode} event=${event} />`)}</div>`
                    : html`<p>붙어 있는 최근 이동 이벤트가 아직 없습니다.</p>`}
                </div>
              </div>
            </div>
          `
        : html`<${EmptyState} message="스웜 상태를 아직 불러오지 못했습니다." compact />`}
    </section>
  `
}
