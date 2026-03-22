import { html } from 'htm/preact'
import { CmdStatCard } from './cmd-stat-card'
import { EmptyState } from '../common/empty-state'
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
    <div class="grid grid-cols-[minmax(0,1.15fr)_minmax(0,0.85fr)] gap-4">
      <section class="card rounded-xl min-h-[240px]">
        <div class="card rounded-xl-title-row">
          <div class="card rounded-xl-title">스웜 라이브 런</div>
        </div>
        ${commandPlaneSwarmLoading.value
          ? html`<${EmptyState} message="Loading swarm live state…" compact />`
          : commandPlaneSwarmError.value
            ? html`<${EmptyState} message=${commandPlaneSwarmError.value} compact />`
            : swarm
              ? html`
                  <div class="cmd-tag rounded-full-row">
                    <span class="cmd-tag rounded-full">experimental</span>
                    <${ProvenanceChip} item=${{ kind: 'derived', label: 'derived read-model' }} />
                    <span class="cmd-tag rounded-full ${swarm.run_resolution || swarm.resolution_recommendation ? 'warn' : 'ok'}">
                      ${swarm.run_resolution || swarm.resolution_recommendation ? 'operator resolution aware' : 'no resolution advice'}
                    </span>
                  </div>
                  <div class="cmd-card rounded-xl-sub">
                    이 화면은 swarm-live의 사회 truth 자체가 아니라, 실험적 오케스트레이션을 읽기 위한 파생 관찰면입니다.
                  </div>
                  <div class="command-summary-grid">
                    <${CmdStatCard} label="실행 런" value=${swarm.run_id ?? runId ?? 'swarm-live'} detail=${swarm.room_id ?? 'room 정보 없음'} />
                    <${CmdStatCard} label="워커" value=${`${swarm.summary?.joined_workers ?? 0}/${swarm.summary?.expected_workers ?? 0}`} detail=${`${swarm.summary?.live_workers ?? 0}개 가동 · ${swarm.summary?.completed_workers ?? 0}개 완료`} />
                    <${CmdStatCard} label="런타임" value=${runtimeState} detail=${`slots ${actualSlots}/${expectedSlots} · ctx ${actualCtx}/${expectedCtx}`} />
                    <${CmdStatCard} label="고동시성" value=${swarm.summary?.pass_hot_concurrency ? '통과' : '확인 필요'} detail=${swarm.provider?.slot_url ?? 'slot 정보 없음'} />
                    <${CmdStatCard} label="종단 점검" value=${swarm.summary?.pass_end_to_end ? '통과' : '확인 필요'} detail=${swarm.recommended_next_tool ?? 'masc_observe_traces'} />
                  </div>
                  <div class="cmd-card rounded-xl-grid">
                    <span>작전</span><span>${swarm.operation?.operation_id ?? operationId ?? '없음'}</span>
                    <span>분대</span><span>${swarm.squad?.label ?? '없음'}</span>
                    <span>실행체</span><span>${swarm.detachment?.detachment_id ?? '없음'}</span>
                    <span>예상 워커</span><span>${swarm.summary?.expected_workers ?? 0}명</span>
                    <span>최종 마커</span><span>${swarm.summary?.final_markers_seen ?? 0}</span>
                    <span>런타임 막힘</span><span>${swarm.provider?.runtime_blocker ?? '없음'}</span>
                    <span>추천 도구</span><span>${swarm.recommended_next_tool ?? 'masc_observe_traces'}</span>
                  </div>
                  ${swarm.truth_notes.length > 0
                    ? html`<div class="cmd-tag rounded-full-row">
                        ${swarm.truth_notes.map(note => html`<span class="cmd-tag rounded-full">${note}</span>`)}
                      </div>`
                    : null}
                  <${SwarmRunResolutionCard} swarm=${swarm} />
                `
              : html`<${EmptyState} message="스웜 read-model이 아직 없습니다." compact />`}
      </section>

      <section class="card rounded-xl min-h-[240px]">
        <div class="card rounded-xl-title-row">
          <div class="card rounded-xl-title">체크리스트</div>
        </div>
        ${swarm && swarm.checklist.length > 0
          ? html`<div class="cmd-card rounded-xl-stack">
              ${swarm.checklist.map(item => html`<${SwarmChecklistCard} item=${item} />`)}
            </div>`
          : html`<${EmptyState} message="체크리스트가 아직 없습니다." compact />`}
      </section>

      <section class="card rounded-xl min-h-[240px]">
        <div class="card rounded-xl-title-row">
          <div class="card rounded-xl-title">워커</div>
        </div>
        ${swarm && swarm.workers.length > 0
          ? html`<div class="cmd-card rounded-xl-stack">
              ${swarm.workers.map(worker => html`<${SwarmWorkerCard} worker=${worker} />`)}
            </div>`
          : html`<${EmptyState} message="워커 행이 아직 없습니다." compact />`}
      </section>

      <section class="card rounded-xl min-h-[240px]">
        <div class="card rounded-xl-title-row">
          <div class="card rounded-xl-title">런타임</div>
        </div>
        ${swarm?.provider
          ? html`
              <div class="cmd-card rounded-xl-grid">
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
                ? html`<div class="cmd-card rounded-xl-sub">${swarm.provider.detail}</div>`
                : null}
              ${swarm.provider.timeline.length > 0
                ? html`<div class="flex flex-col gap-3">
                    ${swarm.provider.timeline.slice(-12).map(sample => html`
                      <article class="grid grid-cols-[minmax(0,1fr)_minmax(220px,0.9fr)] gap-3.5">
                        <div class="min-w-0 [overflow-wrap:anywhere] break-words">
                          <div class="flex justify-between items-start">
                            <strong>${sample.active_slots} active</strong>
                            <span class="cmd-chip rounded-full">${relativeTime(sample.timestamp)}</span>
                          </div>
                          <div class="cmd-card rounded-xl-sub">slots ${sample.active_slot_ids.join(', ') || 'none'}</div>
                        </div>
                      </article>
                    `)}
                  </div>`
                : html`<${EmptyState} message="slot telemetry가 아직 없습니다." compact />`}
            `
          : html`<${EmptyState} message="런타임 telemetry가 아직 없습니다." compact />`}
      </section>

      <section class="card rounded-xl min-h-[240px]">
        <div class="card rounded-xl-title-row">
          <div class="card rounded-xl-title">막힘 요인</div>
        </div>
        ${swarm && swarm.blockers.length > 0
          ? html`<div class="cmd-card rounded-xl-stack">
              ${swarm.blockers.map(blocker => html`<${SwarmBlockerCard} blocker=${blocker} />`)}
            </div>`
          : html`<${EmptyState} message=${`막힘 요인은 없습니다. 다음 액션은 ${swarm?.recommended_next_tool ?? 'masc_observe_traces'} 입니다.`} compact />`}
      </section>

      <section class="card rounded-xl min-h-[240px]">
        <div class="card rounded-xl-title-row">
          <div class="card rounded-xl-title">최근 메시지</div>
        </div>
        ${swarm && swarm.recent_messages.length > 0
          ? html`<div class="flex flex-col gap-3">
              ${swarm.recent_messages.map(message => html`
                <article class="grid grid-cols-[minmax(0,1fr)_minmax(220px,0.9fr)] gap-3.5">
                  <div class="min-w-0 [overflow-wrap:anywhere] break-words">
                    <div class="flex justify-between items-start">
                      <strong>${message.from}</strong>
                      <span class="cmd-chip rounded-full">${relativeTime(message.timestamp)}</span>
                    </div>
                    <div class="cmd-card rounded-xl-sub">seq ${message.seq}</div>
                  </div>
                  <pre class="m-0 p-3 rounded-[10px] bg-[rgba(9,12,20,0.75)] text-[rgba(224,242,254,0.92)] text-[length:var(--fs-sm)] leading-[1.45] max-h-[220px] overflow-auto whitespace-pre-wrap break-words [overflow-wrap:anywhere]">${formatMessageContent(message.content)}</pre>
                </article>
              `)}
            </div>`
          : html`<${EmptyState} message="run 범위 메시지가 아직 없습니다." compact />`}
      </section>

      <section class="card rounded-xl min-h-[240px]">
        <div class="card rounded-xl-title-row">
          <div class="card rounded-xl-title">최근 트레이스 이벤트</div>
        </div>
        ${swarm && swarm.recent_trace_events.length > 0
          ? html`<div class="flex flex-col gap-3">
              ${swarm.recent_trace_events.map(event => html`<${TraceRow} event=${event} />`)}
            </div>`
          : html`<${EmptyState} message="run 범위 trace event가 아직 없습니다." compact />`}
      </section>
    </div>
  `
}
