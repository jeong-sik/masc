import { html } from 'htm/preact'
import {
  commandPlaneSwarm,
  commandPlaneSwarmError,
  commandPlaneSwarmLoading,
} from '../../command-store'
import { ProvenanceChip } from '../common/provenance-strip'
import {
  dashboardSwarmOperationId,
  dashboardSwarmRunId,
  relativeTime,
} from './helpers'
import { formatMessageContent } from '../ops/helpers'
import { TraceRow } from './topology'
import {
  SwarmBlockerCard,
  SwarmChecklistCard,
  SwarmWorkerCard,
} from './swarm-cards'
import { SwarmRunResolutionCard } from './swarm-storyboard'

export function SwarmLivePanels() {
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
    <div class="grid grid-cols-[minmax(0,1.15fr)_minmax(0,0.85fr)] gap-4 max-[1100px]:grid-cols-1">
      <section class="card min-h-[240px]">
        <div class="card-title-row">
          <div class="card-title">스웜 라이브 런</div>
        </div>
        ${commandPlaneSwarmLoading.value
          ? html`<div class="empty-state">Loading swarm live state…</div>`
          : commandPlaneSwarmError.value
            ? html`<div class="empty-state error">${commandPlaneSwarmError.value}</div>`
            : swarm
              ? html`
                  <div class="flex gap-2 flex-wrap mt-2 text-[var(--white-56)] text-[length:var(--fs-sm)]">
                    <span class="command-tag">experimental</span>
                    <${ProvenanceChip} item=${{ kind: 'derived', label: 'derived read-model' }} />
                    <span class="command-tag ${swarm.run_resolution || swarm.resolution_recommendation ? 'warn' : 'ok'}">
                      ${swarm.run_resolution || swarm.resolution_recommendation ? 'operator resolution aware' : 'no resolution advice'}
                    </span>
                  </div>
                  <div class="text-[var(--white-56)] text-[length:var(--fs-sm)] mt-1 break-words [overflow-wrap:anywhere]">
                    이 화면은 swarm-live의 사회 truth 자체가 아니라, 실험적 오케스트레이션을 읽기 위한 파생 관찰면입니다.
                  </div>
                  <div class="grid grid-cols-[repeat(auto-fit,minmax(140px,1fr))] gap-3">
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
                    ? html`<div class="flex gap-2 flex-wrap mt-2 text-[var(--white-56)] text-[length:var(--fs-sm)]">
                        ${swarm.truth_notes.map(note => html`<span class="command-tag">${note}</span>`)}
                      </div>`
                    : null}
                  <${SwarmRunResolutionCard} swarm=${swarm} />
                `
              : html`<div class="empty-state">스웜 read-model이 아직 없습니다.</div>`}
      </section>

      <section class="card min-h-[240px]">
        <div class="card-title-row">
          <div class="card-title">체크리스트</div>
        </div>
        ${swarm && swarm.checklist.length > 0
          ? html`<div class="flex flex-col gap-3 mt-3.5">
              ${swarm.checklist.map(item => html`<${SwarmChecklistCard} item=${item} />`)}
            </div>`
          : html`<div class="empty-state">체크리스트가 아직 없습니다.</div>`}
      </section>

      <section class="card min-h-[240px]">
        <div class="card-title-row">
          <div class="card-title">워커</div>
        </div>
        ${swarm && swarm.workers.length > 0
          ? html`<div class="flex flex-col gap-3 mt-3.5">
              ${swarm.workers.map(worker => html`<${SwarmWorkerCard} worker=${worker} />`)}
            </div>`
          : html`<div class="empty-state">워커 행이 아직 없습니다.</div>`}
      </section>

      <section class="card min-h-[240px]">
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
                ? html`<div class="text-[var(--white-56)] text-[length:var(--fs-sm)] mt-1 break-words [overflow-wrap:anywhere]">${swarm.provider.detail}</div>`
                : null}
              ${swarm.provider.timeline.length > 0
                ? html`<div class="flex flex-col gap-3">
                    ${swarm.provider.timeline.slice(-12).map(sample => html`
                      <article class="command-trace-row">
                        <div class="min-w-0 break-words [overflow-wrap:anywhere]">
                          <div class="flex justify-between items-start">
                            <strong>${sample.active_slots} active</strong>
                            <span class="command-chip">${relativeTime(sample.timestamp)}</span>
                          </div>
                          <div class="text-[var(--white-56)] text-[length:var(--fs-sm)] mt-1 break-words [overflow-wrap:anywhere]">slots ${sample.active_slot_ids.join(', ') || 'none'}</div>
                        </div>
                      </article>
                    `)}
                  </div>`
                : html`<div class="empty-state">slot telemetry가 아직 없습니다.</div>`}
            `
          : html`<div class="empty-state">런타임 telemetry가 아직 없습니다.</div>`}
      </section>

      <section class="card min-h-[240px]">
        <div class="card-title-row">
          <div class="card-title">막힘 요인</div>
        </div>
        ${swarm && swarm.blockers.length > 0
          ? html`<div class="flex flex-col gap-3 mt-3.5">
              ${swarm.blockers.map(blocker => html`<${SwarmBlockerCard} blocker=${blocker} />`)}
            </div>`
          : html`<div class="empty-state">막힘 요인은 없습니다. 다음 액션은 ${swarm?.recommended_next_tool ?? 'masc_observe_traces'} 입니다.</div>`}
      </section>

      <section class="card min-h-[240px]">
        <div class="card-title-row">
          <div class="card-title">최근 메시지</div>
        </div>
        ${swarm && swarm.recent_messages.length > 0
          ? html`<div class="flex flex-col gap-3">
              ${swarm.recent_messages.map(message => html`
                <article class="command-trace-row">
                  <div class="min-w-0 break-words [overflow-wrap:anywhere]">
                    <div class="flex justify-between items-start">
                      <strong>${message.from}</strong>
                      <span class="command-chip">${relativeTime(message.timestamp)}</span>
                    </div>
                    <div class="text-[var(--white-56)] text-[length:var(--fs-sm)] mt-1 break-words [overflow-wrap:anywhere]">seq ${message.seq}</div>
                  </div>
                  <pre class="command-trace-detail">${formatMessageContent(message.content)}</pre>
                </article>
              `)}
            </div>`
          : html`<div class="empty-state">run 범위 메시지가 아직 없습니다.</div>`}
      </section>

      <section class="card min-h-[240px]">
        <div class="card-title-row">
          <div class="card-title">최근 트레이스 이벤트</div>
        </div>
        ${swarm && swarm.recent_trace_events.length > 0
          ? html`<div class="flex flex-col gap-3">
              ${swarm.recent_trace_events.map(event => html`<${TraceRow} event=${event} />`)}
            </div>`
          : html`<div class="empty-state">run 범위 trace event가 아직 없습니다.</div>`}
      </section>
    </div>
  `
}
