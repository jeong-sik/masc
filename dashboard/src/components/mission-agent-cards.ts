import { html } from 'htm/preact'
import { extractAgentInfo } from './common/agent-info'
import { linkedRecentToolsEmptyState, observedToolsEmptyState, toolAuditStateLabel } from './common/tool-audit'
import { openAgentDetail } from './agent-detail'
import { openKeeperDetail } from './keeper-detail'
import { workflowActionLabel } from '../workflow-context'
import type {
  DashboardMissionInternalSignal,
  Keeper,
} from '../types'
import {
  type EnrichedAgentRow,
  type EnrichedKeeperRow,
  toneClass,
  relativeTime,
  statusLabel,
  missionTargetTypeLabel,
  trimText,
  openIncidentIntervene,
  openIncidentCommand,
  openActionIntervene,
  openActionCommand,
  liveStateClass,
} from './mission-utils'

export function AgentBriefCard({ row }: { row: EnrichedAgentRow }) {
  const info = extractAgentInfo(row.brief.agent_name)
  const who = row.withWhom.length > 0 ? row.withWhom.slice(0, 3).join(', ') : '단독 또는 방 단위'
  const recentToolsLabel =
    row.recentTools.length > 0
      ? row.recentTools.join(', ')
      : toolAuditStateLabel(observedToolsEmptyState(row.keeper, row.brief.tool_audit_source))
  return html`
    <article class="mission-activity-card ${toneClass(row.brief.status ?? row.agent?.status)}">
      <button class="mission-card-select" onClick=${() => openAgentDetail(row.brief.agent_name)}>
        <div class="mission-activity-head">
          <div class="mission-activity-title">
            <span class="agent-emoji">${row.agent?.emoji ?? row.keeper?.emoji ?? ''}</span>
            <div>
              <strong>${row.brief.agent_name}</strong>
              <span>${info.model !== info.nickname ? `${info.model} · ` : ''}${info.nickname}</span>
            </div>
          </div>
          <span class="command-chip ${toneClass(row.brief.status ?? row.agent?.status)}">${statusLabel(row.brief.status ?? row.agent?.status)}</span>
        </div>

        <div class="mission-activity-meta">
          <span>어디서 · ${row.where}</span>
          <span>누구와 · ${who}</span>
          <span>주의 신호 · ${row.brief.related_attention_count}</span>
        </div>

        <div class="mission-activity-focus">
          <span>무엇을</span>
          <strong>${row.currentWork}</strong>
          ${row.how ? html`<small>어떻게 · ${row.how}</small>` : null}
        </div>
      </button>

      <details class="mission-card-disclosure">
        <summary>최근 흐름</summary>
        <div class="mission-activity-foot">
          ${row.recentEvent ? html`<span>최근 일 · ${row.recentEvent}</span>` : html`<span>최근 사건 요약 없음</span>`}
          <span>관련 세션 · ${row.brief.related_session_id ?? '없음'}</span>
        </div>

        <details class="mission-card-disclosure compact">
          <summary>입력 · 응답 · 도구</summary>
          <div class="mission-io-stack">
            <div class="mission-io-item">
              <span>최근 입력</span>
              <strong>${row.recentInput ?? '표시 가능한 최근 입력이 없습니다'}</strong>
            </div>
            <div class="mission-io-item">
              <span>최근 응답</span>
              <strong>${row.recentOutput ?? '표시 가능한 최근 응답이 없습니다'}</strong>
            </div>
          </div>
          <div class="mission-activity-foot">
            <span>최근 도구 · ${recentToolsLabel}</span>
          </div>
        </details>
      </details>
    </article>
  `
}

export function KeeperBriefCard({ row }: { row: EnrichedKeeperRow }) {
  const continuity = [
    `세대 ${row.brief.generation ?? row.keeper?.generation ?? 0}`,
    row.brief.context_ratio != null
      ? `컨텍스트 ${Math.round(row.brief.context_ratio * 100)}%`
      : (row.keeper?.context_ratio != null ? `컨텍스트 ${Math.round(row.keeper.context_ratio * 100)}%` : null),
    row.brief.last_turn_ago_s != null ? `최근 턴 ${Math.round(row.brief.last_turn_ago_s)}초 전` : null,
  ]
    .filter((value): value is string => value !== null)
    .join(' · ')
  const recentToolsLabel =
    row.recentTools.length > 0
      ? row.recentTools.join(', ')
      : toolAuditStateLabel(linkedRecentToolsEmptyState(row.keeper))

  return html`
    <article class="mission-activity-card ${toneClass(row.brief.status ?? row.keeper?.status)} ${liveStateClass(row.brief.status, row.keeper?.status)}">
      <button class="mission-card-select" onClick=${() => {
        const keeper: Keeper = row.keeper ?? {
          name: row.brief.name,
          agent_name: row.brief.agent_name ?? row.brief.name,
          status: row.brief.status ?? 'unknown',
          context_ratio: row.brief.context_ratio ?? null,
        } as Keeper
        openKeeperDetail(keeper)
      }}>
        <div class="mission-activity-head">
          <div class="mission-activity-title">
            <div class="mission-status-dot ${liveStateClass(row.brief.status, row.keeper?.status)}"></div>
            <span class="agent-emoji">${row.keeper?.emoji ?? ''}</span>
            <div>
              <strong>${row.brief.name}</strong>
              ${row.keeper?.koreanName ? html`<span>${row.keeper.koreanName}</span>` : null}
            </div>
          </div>
          <span class="command-chip ${toneClass(row.brief.status ?? row.keeper?.status)}">${statusLabel(row.brief.status ?? row.keeper?.status)}</span>
        </div>

        <div class="mission-activity-meta">
          <span>최근 하트비트 · ${row.keeper?.last_heartbeat ? relativeTime(row.keeper.last_heartbeat) : '기록 없음'}</span>
          <span>${continuity || '연속성 정보 없음'}</span>
        </div>

        <div class="mission-activity-focus">
          <span>무엇을</span>
          <strong>${row.currentWork}</strong>
          ${row.keeper?.skill_reason ? html`<small>판단 요약 · ${trimText(row.keeper.skill_reason, 120)}</small>` : null}
        </div>
      </button>

      <details class="mission-card-disclosure">
        <summary>연속성 상세</summary>
        <div class="mission-activity-foot">
          <span>에이전트 · ${row.brief.agent_name ?? row.keeper?.agent_name ?? '기록 없음'}</span>
          ${row.recentEvent ? html`<span>최근 일 · ${row.recentEvent}</span>` : null}
        </div>
        <details class="mission-card-disclosure compact">
          <summary>입력 · 응답 · 도구</summary>
          <div class="mission-io-stack">
            <div class="mission-io-item">
              <span>최근 입력</span>
              <strong>${row.recentInput ?? '표시 가능한 최근 입력이 없습니다'}</strong>
            </div>
            <div class="mission-io-item">
              <span>최근 응답</span>
              <strong>${row.recentOutput ?? '표시 가능한 최근 응답이 없습니다'}</strong>
            </div>
          </div>
          <div class="mission-activity-foot">
            <span>최근 도구 · ${recentToolsLabel}</span>
          </div>
        </details>
      </details>
    </article>
  `
}

export function InternalSignalCard({ item }: { item: DashboardMissionInternalSignal }) {
  const action = item.action ?? null
  const attention = item.attention ?? null
  return html`
    <article class="mission-action-card ${toneClass(item.severity)}">
      <div class="mission-card-head">
        <span class="command-chip ${toneClass(item.severity)}">
          ${item.signal_type === 'action' && action ? workflowActionLabel(action.action_type) : attention?.kind ?? '내부 신호'}
        </span>
        <span class="mission-card-target">${missionTargetTypeLabel(item.target_type)}${item.target_id ? ` · ${item.target_id}` : ''}</span>
      </div>
      <p>${item.summary}</p>
      ${action ? html`<div class="mission-action-preview">${action.reason}</div>` : null}
      <div class="mission-card-actions">
        ${action
          ? html`
              <button class="control-btn ghost" onClick=${() => openActionIntervene(action, attention, '상황판 내부 신호')}>이 액션으로 개입 열기</button>
              <button class="control-btn ghost" onClick=${() => openActionCommand(action, attention, '상황판 내부 신호')}>이 이슈의 원인 보기</button>
            `
          : attention
            ? html`
                <button class="control-btn ghost" onClick=${() => openIncidentIntervene(attention)}>이 이슈로 개입 열기</button>
                <button class="control-btn ghost" onClick=${() => openIncidentCommand(attention)}>이 이슈의 원인 보기</button>
              `
            : null}
      </div>
    </article>
  `
}
