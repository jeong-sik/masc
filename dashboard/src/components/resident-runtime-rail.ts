import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { connected, eventCount } from '../sse'
import {
  refreshDashboard,
  agents,
  tasks,
  keepers,
  serverStatus,
} from '../store'
import { refreshForTab } from '../tab-refresh'
import { TimeAgo } from './common/time-ago'
import { PanelSemanticDetails } from './common/semantic-layer'
import { navigate } from '../router'
import { operatorSnapshot, refreshOperatorRoomDigest, refreshOperatorSnapshot } from '../operator-store'
import { selectPendingConfirmState } from '../pending-confirm'

function shortCommit(commit: string | null | undefined): string {
  const value = commit?.trim()
  if (!value) return '커밋 정보 없음'
  return value.length > 10 ? value.slice(0, 10) : value
}

function residentStatusLabel(
  kind: 'social' | 'gardener' | 'guardian' | 'sentinel',
  status: 'live' | 'quiet' | 'starting' | 'idle' | 'disabled',
) {
  if (status === 'live') return '가동 중'
  if (status === 'quiet') return '조용함'
  if (status === 'starting') return '기동 중'
  if (status === 'idle') return kind === 'guardian' ? '유휴' : '대기 중'
  return '비활성'
}

function renderRuntimeStat(label: string, value: ComponentChildren) {
  return html`
    <div class="build-badge-row">
      <span>${label}</span>
      <strong>${value}</strong>
    </div>
  `
}

function renderResidentRuntimeCard(
  title: string,
  statusLabel: string,
  tone: 'ok' | 'warn' | 'bad',
  rows: ComponentChildren[],
  hint?: ComponentChildren,
) {
  return html`
    <div style="padding-top:12px; border-top:1px solid rgba(255,255,255,0.08); display:flex; flex-direction:column; gap:6px;">
      <div class="rail-card-head" style="margin:0;">
        <h3 style="font-size:12px;">${title}</h3>
        <span class="rail-section-chip ${tone}">${statusLabel}</span>
      </div>
      ${rows}
      ${hint ? html`<div class="rail-build-hint">${hint}</div>` : null}
    </div>
  `
}

export function SnapshotCard({ currentTab }: { currentTab: string }) {
  const liveConnected = connected.value
  const build = serverStatus.value?.build
  const socialRuntime = serverStatus.value?.social_runtime
  const gardener = serverStatus.value?.gardener
  const guardian = serverStatus.value?.guardian
  const sentinel = serverStatus.value?.sentinel
  const residentCards: ComponentChildren[] = []

  if (socialRuntime) {
    residentCards.push(
      renderResidentRuntimeCard(
        'Social Runtime',
        socialRuntime.enabled
          ? residentStatusLabel('social', 'live')
          : residentStatusLabel('social', 'disabled'),
        socialRuntime.enabled ? 'ok' : 'bad',
        [
          renderRuntimeStat('전략', socialRuntime.strategy ?? 'unknown'),
          renderRuntimeStat('대상 keeper', socialRuntime.active_keepers ?? 0),
          renderRuntimeStat('큐', socialRuntime.queue_depth ?? 0),
          renderRuntimeStat(
            '최근 결과',
            socialRuntime.last_result?.activity_report
              ?? (socialRuntime.last_pass_reason ? `판단 패스: ${socialRuntime.last_pass_reason}` : null)
              ?? (socialRuntime.last_system_skip_reason ? `시스템 스킵: ${socialRuntime.last_system_skip_reason}` : null)
              ?? '없음',
          ),
        ],
      ),
    )
  }

  if (gardener) {
    residentCards.push(
      renderResidentRuntimeCard(
        'Gardener',
        gardener.alive
          ? residentStatusLabel('gardener', 'live')
          : gardener.enabled
            ? residentStatusLabel('gardener', 'starting')
            : residentStatusLabel('gardener', 'disabled'),
        gardener.alive ? 'ok' : gardener.enabled ? 'warn' : 'bad',
        [
          renderRuntimeStat(
            '최근 tick',
            gardener.last_tick_completed_at
              ? html`<${TimeAgo} timestamp=${gardener.last_tick_completed_at} />`
              : '기록 없음',
          ),
          renderRuntimeStat(
            '판단',
            `${gardener.last_intervention ?? '없음'} · ${gardener.last_decision_source ?? '없음'}`,
          ),
          renderRuntimeStat(
            '백로그',
            `미할당 ${gardener.health_summary?.todo_count ?? 0} · P1/2 ${gardener.health_summary?.high_priority_todo ?? 0}`,
          ),
        ],
        gardener.last_reason ?? gardener.last_error ?? undefined,
      ),
    )
  }

  if (guardian) {
    const guardianLive = guardian.masc_loops_running === true
    residentCards.push(
      renderResidentRuntimeCard(
        'Guardian',
        guardianLive
          ? residentStatusLabel('guardian', 'live')
          : guardian.enabled
            ? residentStatusLabel('guardian', 'idle')
            : residentStatusLabel('guardian', 'disabled'),
        guardianLive ? 'ok' : guardian.enabled ? 'warn' : 'bad',
        [
          renderRuntimeStat('모드', guardian.mode ?? '알 수 없음'),
          renderRuntimeStat(
            '루프',
            `zombie ${guardian.zombie_loop_running ? 'on' : 'off'} · gc ${guardian.gc_loop_running ? 'on' : 'off'}`,
          ),
          renderRuntimeStat('소유자', guardian.runtime_owner ?? '없음'),
        ],
        guardian.last_gc_result
          ?? guardian.last_zombie_result
          ?? undefined,
      ),
    )
  }

  if (sentinel) {
    residentCards.push(
      renderResidentRuntimeCard(
        'Sentinel',
        sentinel.started
          ? residentStatusLabel('sentinel', 'live')
          : sentinel.enabled
            ? residentStatusLabel('sentinel', 'starting')
            : residentStatusLabel('sentinel', 'disabled'),
        sentinel.started ? 'ok' : sentinel.enabled ? 'warn' : 'bad',
        [
          renderRuntimeStat('에이전트', sentinel.agent_name ?? 'sentinel'),
          renderRuntimeStat('소비자', sentinel.consumers?.length ?? 0),
          renderRuntimeStat('가디언 소유자', sentinel.guardian_runtime_owner ?? '없음'),
        ],
        sentinel.llm_enabled === true ? 'LLM 기반 housekeeping resident' : undefined,
      ),
    )
  }

  return html`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>현황</h3>
        <${PanelSemanticDetails} panelId="side_rail.snapshot" compact=${true} />
        <span class="rail-section-chip ${liveConnected ? 'ok' : 'bad'}">${liveConnected ? '연결됨' : '오프라인'}</span>
      </div>
      <div class="rail-stat-grid">
        <div class="rail-stat-card">
          <span>에이전트</span>
          <strong>${agents.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>키퍼</span>
          <strong>${keepers.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>태스크</span>
          <strong>${tasks.value.length}</strong>
        </div>
        <div class="rail-stat-card">
          <span>이벤트</span>
          <strong>${eventCount.value}</strong>
        </div>
      </div>
      <div class="rail-inline-actions">
        <button
          class="rail-refresh-btn"
          onClick=${() => {
            refreshDashboard()
            refreshForTab(currentTab)
          }}
        >
          새로고침
        </button>
        <button class="rail-secondary-btn" onClick=${() => navigate('control')}>
          운영 패널 열기
        </button>
      </div>
      ${build
        ? html`<div class="rail-build-hint">서버 빌드 · v${build.release_version} · ${shortCommit(build.commit)}</div>`
        : null}
      ${residentCards.length > 0
        ? html`
            <div style="margin-top:12px; display:flex; flex-direction:column; gap:10px;">
              ${residentCards}
            </div>
          `
        : null}
    </section>
  `
}

export function InterveneRailCard() {
  const snapshot = operatorSnapshot.value
  const pendingConfirms = selectPendingConfirmState(snapshot).total_count
  const sessionCount = snapshot?.sessions.length ?? 0
  const keeperCount = snapshot?.keepers.length ?? 0

  return html`
    <section class="rail-card">
      <div class="rail-card-head">
        <h3>개입 바로가기</h3>
        <${PanelSemanticDetails} panelId="side_rail.quick_actions" compact=${true} />
        <span class="rail-section-chip ${pendingConfirms > 0 ? 'warn' : 'ok'}">${pendingConfirms > 0 ? '확인 필요' : '정상'}</span>
      </div>
      <div class="rail-stat-grid">
        <div class="rail-stat-card">
          <span>확인 대기</span>
          <strong>${pendingConfirms}</strong>
        </div>
        <div class="rail-stat-card">
          <span>Session</span>
          <strong>${sessionCount}</strong>
        </div>
        <div class="rail-stat-card">
          <span>키퍼</span>
          <strong>${keeperCount}</strong>
        </div>
      </div>
      <div class="rail-inline-actions">
        <button
          class="rail-refresh-btn"
          onClick=${() => {
            refreshOperatorSnapshot()
            refreshOperatorRoomDigest()
          }}
        >
          개입 데이터 갱신
        </button>
        <button class="rail-secondary-btn" onClick=${() => navigate('control')}>
          운영 패널 열기
        </button>
      </div>
    </section>
  `
}
