import { html } from 'htm/preact'
import {
  commandPlaneSwarm,
  commandPlaneSwarmError,
  commandPlaneSwarmLoading,
} from '../../command-store'
import { route } from '../../router'
import { workflowContextForRoute } from '../../workflow-context'
import { ProvenanceChip } from '../common/provenance-strip'
import {
  currentCommandPlaneSummary,
  dashboardSwarmOperationId,
  dashboardSwarmRunId,
  relativeTime,
  swarmFocusKey,
  toneClass,
} from './helpers'
import { formatMessageContent } from '../ops/helpers'
import { TraceRow } from './topology'
import { SwarmBlockerCard, SwarmChecklistCard, SwarmEventNode, SwarmGapDot, SwarmProofPanel, SwarmWorkerCard } from './swarm-cards'
import {
  SwarmHealthBar,
  SwarmLaneStrip,
  SwarmRunResolutionCard,
  SwarmStoryboard,
} from './swarm-storyboard'

// Re-export for consumers that import from './swarm'
export { SwarmBlockerCard, SwarmChecklistCard, SwarmWorkerCard } from './swarm-cards'
export { SwarmHealthBar, SwarmRunResolutionCard, SwarmStoryboard } from './swarm-storyboard'

function SwarmPanel() {
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

export function SwarmSurface() {
  const swarm = commandPlaneSwarm.value
  const runId = dashboardSwarmRunId()
  const operationId = dashboardSwarmOperationId()
  const runtimeState = swarm?.provider?.runtime_blocker
    ? 'blocked'
    : swarm?.provider?.provider_reachable
      ? 'ready'
      : 'check'
  const actualSlots = swarm?.provider?.actual_slots ?? swarm?.provider?.total_slots ?? 0
  const expectedSlots = swarm?.provider?.expected_slots ?? 'n/a'
  const actualCtx = swarm?.provider?.actual_ctx ?? swarm?.provider?.ctx_per_slot ?? 0
  const expectedCtx = swarm?.provider?.expected_ctx ?? 'n/a'
  return html`
    <div class="command-section-stack">
      <${SwarmPanel} />
      <div class="command-surface-grid">
        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">스웜 라이브 런</div>
          </div>
          ${commandPlaneSwarmLoading.value
            ? html`<div class="empty-state">Loading swarm live state…</div>`
            : commandPlaneSwarmError.value
              ? html`<div class="empty-state error">${commandPlaneSwarmError.value}</div>`
              : swarm
                ? html`
                    <div class="command-tag-row">
                      <span class="command-tag">experimental</span>
                      <${ProvenanceChip} item=${{ kind: 'derived', label: 'derived read-model' }} />
                      <span class="command-tag ${swarm.run_resolution || swarm.resolution_recommendation ? 'warn' : 'ok'}">
                        ${swarm.run_resolution || swarm.resolution_recommendation ? 'operator resolution aware' : 'no resolution advice'}
                      </span>
                    </div>
                    <div class="command-card-sub">
                      이 화면은 swarm-live의 사회 truth 자체가 아니라, 실험적 오케스트레이션을 읽기 위한 파생 관찰면입니다.
                    </div>
                    <div class="command-summary-grid">
                      <div class="monitor-stat-card"><span>실행 런</span><strong>${swarm.run_id ?? runId ?? 'swarm-live'}</strong><small>${swarm.room_id ?? 'room 정보 없음'}</small></div>
                      <div class="monitor-stat-card"><span>워커</span><strong>${swarm.summary?.joined_workers ?? 0}/${swarm.summary?.expected_workers ?? 0}</strong><small>${swarm.summary?.live_workers ?? 0}개 가동 · ${swarm.summary?.completed_workers ?? 0}개 완료</small></div>
                      <div class="monitor-stat-card"><span>런타임</span><strong>${runtimeState}</strong><small>slots ${actualSlots}/${expectedSlots} · ctx ${actualCtx}/${expectedCtx}</small></div>
                      <div class="monitor-stat-card"><span>고동시성</span><strong>${swarm.summary?.pass_hot_concurrency ? '통과' : '확인 필요'}</strong><small>${swarm.provider?.slot_url ?? 'slot 정보 없음'}</small></div>
                      <div class="monitor-stat-card"><span>종단 점검</span><strong>${swarm.summary?.pass_end_to_end ? '통과' : '확인 필요'}</strong><small>${swarm.recommended_next_tool ?? 'masc_observe_traces'}</small></div>
                    </div>
                    <div class="command-card-grid">
                      <span>작전</span><span>${swarm.operation?.operation_id ?? operationId ?? '없음'}</span>
                      <span>분대</span><span>${swarm.squad?.label ?? '없음'}</span>
                      <span>실행체</span><span>${swarm.detachment?.detachment_id ?? '없음'}</span>
                      <span>예상 워커</span><span>${swarm.summary?.expected_workers ?? 0}명</span>
                      <span>최종 마커</span><span>${swarm.summary?.final_markers_seen ?? 0}</span>
                      <span>런타임 막힘</span><span>${swarm.provider?.runtime_blocker ?? '없음'}</span>
                      <span>추천 도구</span><span>${swarm.recommended_next_tool ?? 'masc_observe_traces'}</span>
                    </div>
                    ${swarm.truth_notes.length > 0
                      ? html`<div class="command-tag-row">
                          ${swarm.truth_notes.map(note => html`<span class="command-tag">${note}</span>`)}
                        </div>`
                      : null}
                    <${SwarmRunResolutionCard} swarm=${swarm} />
                  `
                : html`<div class="empty-state">스웜 read-model이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">체크리스트</div>
          </div>
          ${swarm && swarm.checklist.length > 0
            ? html`<div class="command-card-stack">
                ${swarm.checklist.map(item => html`<${SwarmChecklistCard} item=${item} />`)}
              </div>`
            : html`<div class="empty-state">체크리스트가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">워커</div>
          </div>
          ${swarm && swarm.workers.length > 0
            ? html`<div class="command-card-stack">
                ${swarm.workers.map(worker => html`<${SwarmWorkerCard} worker=${worker} />`)}
              </div>`
            : html`<div class="empty-state">워커 행이 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">런타임</div>
          </div>
          ${swarm?.provider
            ? html`
                <div class="command-card-grid">
                  <span>Provider</span><span>${swarm.provider.provider_base_url ?? 'n/a'}</span>
                  <span>Provider Reachable</span><span>${swarm.provider.provider_reachable == null ? 'n/a' : swarm.provider.provider_reachable ? 'yes' : 'no'}</span>
                  <span>Requested Model</span><span>${swarm.provider.provider_model_id ?? 'n/a'}</span>
                  <span>Actual Model</span><span>${swarm.provider.actual_model_id ?? 'n/a'}</span>
                  <span>Slot URL</span><span>${swarm.provider.slot_url ?? 'n/a'}</span>
                  <span>Expected Slots</span><span>${swarm.provider.expected_slots ?? 'n/a'}</span>
                  <span>Actual Slots</span><span>${swarm.provider.actual_slots ?? swarm.provider.total_slots ?? 0}</span>
                  <span>Expected Ctx</span><span>${swarm.provider.expected_ctx ?? 'n/a'}</span>
                  <span>Actual Ctx</span><span>${swarm.provider.actual_ctx ?? swarm.provider.ctx_per_slot ?? 0}</span>
                  <span>Active Now</span><span>${swarm.provider.active_slots_now ?? 0}</span>
                  <span>Peak Active</span><span>${swarm.provider.peak_active_slots ?? 0}</span>
                  <span>Sample Count</span><span>${swarm.provider.sample_count ?? 0}</span>
                  <span>Last Sample</span><span>${swarm.provider.last_sample_at ? relativeTime(swarm.provider.last_sample_at) : 'n/a'}</span>
                  <span>런타임 막힘</span><span>${swarm.provider.runtime_blocker ?? 'none'}</span>
                  <span>Doctor Checked</span><span>${swarm.provider.checked_at ? relativeTime(swarm.provider.checked_at) : 'n/a'}</span>
                </div>
                ${swarm.provider.detail
                  ? html`<div class="command-card-sub">${swarm.provider.detail}</div>`
                  : null}
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
                  : html`<div class="empty-state">slot telemetry가 아직 없습니다.</div>`}
              `
            : html`<div class="empty-state">런타임 telemetry가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">막힘 요인</div>
          </div>
          ${swarm && swarm.blockers.length > 0
            ? html`<div class="command-card-stack">
                ${swarm.blockers.map(blocker => html`<${SwarmBlockerCard} blocker=${blocker} />`)}
              </div>`
            : html`<div class="empty-state">막힘 요인은 없습니다. 다음 액션은 ${swarm?.recommended_next_tool ?? 'masc_observe_traces'} 입니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 메시지</div>
          </div>
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
                    <pre class="command-trace-detail">${formatMessageContent(message.content)}</pre>
                  </article>
                `)}
              </div>`
            : html`<div class="empty-state">run 범위 메시지가 아직 없습니다.</div>`}
        </section>

        <section class="card command-section">
          <div class="card-title-row">
            <div class="card-title">최근 트레이스 이벤트</div>
          </div>
          ${swarm && swarm.recent_trace_events.length > 0
            ? html`<div class="command-trace-stack">
                ${swarm.recent_trace_events.map(event => html`<${TraceRow} event=${event} />`)}
              </div>`
            : html`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
        </section>
      </div>
    </div>
  `
}
