import { html } from 'htm/preact'
import { extractAgentInfo } from './common/agent-info'
import { linkedRecentToolsEmptyState, observedToolsEmptyState, toolAuditStateLabel } from './common/tool-audit'
import { StatCell } from './common/stat-cell'
import { ActionBar, ActionBtn } from './common/action-bar'
import { InlineKeeperAction } from './common/inline-keeper-action'
import { StatusChip } from './common/status-chip'
import { openAgentDetail } from './agent-detail'
import { openKeeperDetail } from './keeper-detail'
import { workflowActionLabel } from '../workflow-context'
import { formatPct } from '../lib/format-number'
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
  dotStateBg,
} from './mission-utils'

export function AgentBriefCard({ row }: { row: EnrichedAgentRow }) {
  const info = extractAgentInfo(row.brief.agent_name)
  const who = row.withWhom.length > 0 ? row.withWhom.slice(0, 3).join(', ') : '단독 또는 프로젝트 범위'
  const recentToolsLabel =
    row.recentTools.length > 0
      ? row.recentTools.join(', ')
      : toolAuditStateLabel(observedToolsEmptyState(row.keeper, row.brief.tool_audit_source))
  return html`
    <article class="w-full p-4 rounded-xl border border-[var(--white-8)] bg-[var(--white-4)] grid gap-3 text-inherit text-left cursor-pointer ${toneClass(row.brief.status ?? row.agent?.status)}">
      <button type="button" class="w-full p-0 border-0 bg-transparent text-inherit grid gap-3 text-left cursor-pointer" onClick=${() => openAgentDetail(row.brief.agent_name)}>
        <div class="flex justify-between gap-3 items-start flex-nowrap">
          <div class="flex gap-3 items-start min-w-0">
            <span class="agent-emoji">${row.agent?.emoji ?? row.keeper?.emoji ?? ''}</span>
            <div class="min-w-0">
              <strong class="block truncate">${row.brief.agent_name}</strong>
              <span>${info.model !== info.nickname ? `${info.model} · ` : ''}${info.nickname}</span>
            </div>
          </div>
          <${StatusChip} label=${statusLabel(row.brief.status ?? row.agent?.status)} tone=${toneClass(row.brief.status ?? row.agent?.status)} />
        </div>

        <div class="flex flex-wrap gap-3 text-[var(--text-body)] text-[13px] leading-snug">
          <span>어디서 · ${row.where}</span>
          <span>누구와 · ${who}</span>
          <span>주의 신호 · ${row.brief.related_attention_count}</span>
        </div>

        <div class="grid gap-1.5">
          <span>무엇을</span>
          <strong>${row.currentWork}</strong>
          ${row.how ? html`<small>어떻게 · ${row.how}</small>` : null}
        </div>
      </button>

      <details class="pt-2 border-t border-[var(--white-6)]">
        <summary>최근 흐름</summary>
        <div class="flex flex-wrap gap-3 text-[var(--text-body)] text-[13px] leading-snug mt-3">
          ${row.recentEvent ? html`<span>최근 일 · ${row.recentEvent}</span>` : html`<span>최근 사건 요약 없음</span>`}
          <span>관련 세션 · ${row.brief.related_session_id ?? '없음'}</span>
        </div>

        <details class="pt-2 border-t border-[var(--white-6)] mt-3">
          <summary>입력 · 응답 · 도구</summary>
          <div class="grid grid-cols-2 gap-3 mt-3">
            <${StatCell} label="최근 입력" value=${row.recentInput ?? '표시 가능한 최근 입력이 없습니다'} bg="white-3" />
            <${StatCell} label="최근 응답" value=${row.recentOutput ?? '표시 가능한 최근 응답이 없습니다'} bg="white-3" />
          </div>
          <div class="flex flex-wrap gap-3 text-[var(--text-body)] text-[13px] leading-snug mt-3">
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
      ? `컨텍스트 ${formatPct(row.brief.context_ratio)}`
      : (row.keeper?.context_ratio != null ? `컨텍스트 ${formatPct(row.keeper.context_ratio)}` : null),
    row.brief.last_turn_ago_s != null ? `최근 턴 ${Math.round(row.brief.last_turn_ago_s)}초 전` : null,
  ]
    .filter((value): value is string => value !== null)
    .join(' · ')
  const recentToolsLabel =
    row.recentTools.length > 0
      ? row.recentTools.join(', ')
      : toolAuditStateLabel(linkedRecentToolsEmptyState(row.keeper))

  return html`
    <article class="w-full p-4 rounded-xl border border-[var(--white-8)] bg-[var(--white-4)] grid gap-3 text-inherit text-left cursor-pointer ${toneClass(row.brief.status ?? row.keeper?.status)} ${liveStateClass(row.brief.status, row.keeper?.status)}">
      <button type="button" class="w-full p-0 border-0 bg-transparent text-inherit grid gap-3 text-left cursor-pointer" onClick=${() => {
        const keeper: Keeper = row.keeper ?? {
          name: row.brief.name,
          agent_name: row.brief.agent_name ?? row.brief.name,
          status: row.brief.status ?? 'unknown',
          context_ratio: row.brief.context_ratio ?? null,
        } as Keeper
        openKeeperDetail(keeper)
      }}>
        <div class="flex justify-between gap-3 items-start">
          <div class="flex gap-3 items-start">
            <div class="mission-status-dot ${liveStateClass(row.brief.status, row.keeper?.status)} ${dotStateBg(liveStateClass(row.brief.status, row.keeper?.status))}"></div>
            <span class="agent-emoji">${row.keeper?.emoji ?? ''}</span>
            <div>
              <strong>${row.brief.name}</strong>
              ${row.keeper?.koreanName ? html`<span>${row.keeper.koreanName}</span>` : null}
            </div>
          </div>
          <${StatusChip} label=${statusLabel(row.brief.status ?? row.keeper?.status)} tone=${toneClass(row.brief.status ?? row.keeper?.status)} />
        </div>

        <div class="flex flex-wrap gap-3 text-[var(--text-body)] text-[13px] leading-snug">
          <span>최근 하트비트 · ${row.keeper?.last_heartbeat ? relativeTime(row.keeper.last_heartbeat) : '기록 없음'}</span>
          <span>${continuity || '연속성 정보 없음'}</span>
        </div>

        <div class="grid gap-1.5">
          <span>무엇을</span>
          <strong>${row.currentWork}</strong>
          ${row.keeper?.skill_reason ? html`<small>판단 요약 · ${trimText(row.keeper.skill_reason, 120)}</small>` : null}
        </div>
      </button>

      <${ActionBar} class="pt-2 border-t border-[var(--white-6)]">
        <${InlineKeeperAction} keeperName=${row.brief.name} />
        <${ActionBtn} label="상세 보기" onClick=${(e: Event) => {
          e.stopPropagation()
          const keeper: Keeper = row.keeper ?? {
            name: row.brief.name,
            agent_name: row.brief.agent_name ?? row.brief.name,
            status: row.brief.status ?? 'unknown',
            context_ratio: row.brief.context_ratio ?? null,
          } as Keeper
          openKeeperDetail(keeper)
        }} />
      <//>

      <details class="pt-2 border-t border-[var(--white-6)]">
        <summary>연속성 상세</summary>
        <div class="flex flex-wrap gap-3 text-[var(--text-body)] text-[13px] leading-snug mt-3">
          <span>에이전트 · ${row.brief.agent_name ?? row.keeper?.agent_name ?? '기록 없음'}</span>
          ${row.recentEvent ? html`<span>최근 일 · ${row.recentEvent}</span>` : null}
        </div>
        <details class="pt-2 border-t border-[var(--white-6)] mt-3">
          <summary>입력 · 응답 · 도구</summary>
          <div class="grid grid-cols-2 gap-3 mt-3">
            <${StatCell} label="최근 입력" value=${row.recentInput ?? '표시 가능한 최근 입력이 없습니다'} bg="white-3" />
            <${StatCell} label="최근 응답" value=${row.recentOutput ?? '표시 가능한 최근 응답이 없습니다'} bg="white-3" />
          </div>
          <div class="flex flex-wrap gap-3 text-[var(--text-body)] text-[13px] leading-snug mt-3">
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
    <article class="p-4 rounded-xl border border-[var(--white-8)] bg-[var(--white-4)] grid gap-3 ${toneClass(item.severity)}">
      <div class="flex justify-between gap-3 items-start flex-wrap">
        <${StatusChip} label=${item.signal_type === 'action' && action ? workflowActionLabel(action.action_type) : attention?.kind ?? '내부 신호'} tone=${toneClass(item.severity)} />
        <span class="text-[var(--text-muted)] text-[13px]">${missionTargetTypeLabel(item.target_type)}${item.target_id ? ` · ${item.target_id}` : ''}</span>
      </div>
      <p class="m-0 text-[rgba(255,255,255,0.8)] leading-normal">${item.summary}</p>
      ${action ? html`<div class="py-3 px-4 rounded-xl bg-[var(--white-5)] border border-[var(--white-8)] text-[var(--text-strong)] leading-snug">${action.reason}</div>` : null}
      <${ActionBar}>
        ${action
          ? html`
              <${ActionBtn} label="이 액션으로 개입 열기" onClick=${() => openActionIntervene(action, attention, '상황판 내부 신호')} />
              <${ActionBtn} label="개입 준비 열기" onClick=${() => openActionCommand(action, attention, '상황판 내부 신호')} />
            `
          : attention
            ? html`
                <${ActionBtn} label="이 이슈로 개입 열기" onClick=${() => openIncidentIntervene(attention)} />
                <${ActionBtn} label="개입 준비 열기" onClick=${() => openIncidentCommand(attention)} />
              `
            : null}
      <//>
    </article>
  `
}
