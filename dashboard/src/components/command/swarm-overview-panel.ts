import { html } from 'htm/preact'
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
    <section class="card command-section">
      <div class="card-title-row">
        <div class="card-title">스웜</div>
      </div>
      ${swarm
        ? html`
            <${SwarmStoryboard} lanes=${lanes} />
            <div class="command-summary-grid command-swarm-summary">
              <div class="monitor-stat-card"><span>활성 레인</span><strong>${overview?.active_lanes ?? 0}</strong><small>${overview?.moving_lanes ?? 0}개 이동 중</small></div>
              <div class="monitor-stat-card"><span>정체</span><strong>${overview?.stalled_lanes ?? 0}</strong><small>${overview?.projected_lanes ?? 0}개 예상 레인</small></div>
              <div class="monitor-stat-card"><span>마지막 이동</span><strong>${relativeTime(overview?.last_movement_at)}</strong><small>${swarm.generated_at ? `스냅샷 ${relativeTime(swarm.generated_at)}` : '방금 스냅샷'}</small></div>
              <div class="monitor-stat-card"><span>다음 액션</span><strong>${recommendation?.label ?? '운영자 상태 확인'}</strong><small>${recommendation?.tool ?? 'masc_operator_snapshot'}</small></div>
            </div>

            ${lanes.length > 0 ? html`<${SwarmHealthBar} lanes=${lanes} />` : null}

            <div class="command-swarm-layout ${compactLayout ? 'compact' : ''}">
              <div class="command-card-stack">
                ${lanes.length > 0
                  ? lanes.map(lane => html`<${SwarmLaneStrip} lane=${lane} />`)
                  : html`<div class="empty-state">활성 스웜 레인이 없습니다.</div>`}
              </div>

              <div class="command-card-stack">
                <div class="command-guide-card highlight ${focusKey === 'recommendation' ? 'focus' : ''}">
                  <div class="command-guide-head">
                    <strong>${recommendation?.label ?? '운영자 상태 확인'}</strong>
                    <span class="command-chip">${recommendation?.lane_id ?? '전체'}</span>
                  </div>
                  <p>${recommendation?.reason ?? '보이는 활성 스웜 레인이 아직 없습니다.'}</p>
                  <div class="command-card-foot">${recommendation?.tool ?? 'masc_operator_snapshot'}</div>
                </div>

                <${SwarmProofPanel} proof=${proof} />

                <div class="command-guide-card ${gaps.length > 0 ? 'warn' : 'ok'} ${focusKey === 'gaps' ? 'focus' : ''}">
                  <div class="command-guide-head">
                    <strong>핵심 공백</strong>
                    <span class="command-chip ${toneClass(gaps.some(gap => gap.severity === 'bad') ? 'bad' : gaps.length > 0 ? 'warn' : 'ok')}">${gaps.length}</span>
                  </div>
                  ${gaps.length > 0
                    ? html`<div class="swarm-event-rail">${gaps.slice(0, 4).map(gap => html`<${SwarmGapDot} gap=${gap} />`)}</div>`
                    : html`<p>지금 보이는 핵심 공백은 없습니다.</p>`}
                </div>

                <div class="command-guide-card">
                  <div class="command-guide-head">
                    <strong>이동 타임라인</strong>
                    <span class="command-chip">${timeline.length}</span>
                  </div>
                  ${timeline.length > 0
                    ? html`<div class="swarm-event-rail">${timeline.map(event => html`<${SwarmEventNode} event=${event} />`)}</div>`
                    : html`<p>붙어 있는 최근 이동 이벤트가 아직 없습니다.</p>`}
                </div>
              </div>
            </div>
          `
        : html`<div class="empty-state">스웜 상태를 아직 불러오지 못했습니다.</div>`}
    </section>
  `
}
