import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { Card } from './common/card'
import { EmptyState } from './common/empty-state'
import { LoadingState } from './common/feedback-state'
import { CountBadge } from './common/badge'
import {
  missionError,
  missionSessionDetail,
  missionSessionDetailError,
  missionSessionDetailLoading,
  missionLoading,
  missionSnapshot,
  refreshMissionSessionDetail,
} from '../mission-store'
import {
  selectedAttentionId,
  selectedSessionId,
  sessionLookupById,
  clearMissionSelection,
  toneClass,
  relativeTime,
  statusLabel,
} from './mission-utils'
import {
  SummaryStat,
  AttentionCard,
  SessionBriefCard,
  SessionDetailCard,
  InternalSignalCard,
  MissionBriefingCard,
} from './mission-cards'
import { ProvenanceStrip } from './common/provenance-strip'
export function hiddenMissionSectionLabels({
  activityCount,
  attentionCount,
}: {
  activityCount: number
  attentionCount: number
}): string[] {
  return [
    activityCount > 0 ? null : '최근 활동',
    attentionCount > 0 ? null : '세션 우선순위',
  ].filter((label): label is string => label != null)
}

export function missionJumpNavItems({
  sessionCount,
  activityCount,
  attentionCount,
}: {
  sessionCount: number
  activityCount: number
  attentionCount: number
}): Array<{ id: string, label: string, count: number }> {
  return [
    { id: 'mission-sessions', label: '세션', count: sessionCount, visible: true },
    { id: 'mission-output', label: '활동', count: activityCount, visible: activityCount > 0 },
    { id: 'mission-attention', label: '우선순위', count: attentionCount, visible: attentionCount > 0 },
  ]
    .filter(item => item.visible)
    .map(({ visible: _visible, ...item }) => item)
}

export function Mission() {
  const mission = missionSnapshot.value
  if (missionLoading.value && !mission) {
    return html`<${LoadingState}>상황판 스냅샷 불러오는 중...<//>`
  }
  if (missionError.value && !mission) {
    return html`<${EmptyState} message=${missionError.value} compact />`
  }
  if (!mission) {
    return html`<${EmptyState} message="상황판 스냅샷이 아직 없습니다." compact />`
  }

  const sessionRows = mission.sessions
  const activeSelectedAttentionId =
    selectedAttentionId.value && mission.attention_queue.some(item => item.id === selectedAttentionId.value)
      ? selectedAttentionId.value
      : null
  const activeSelectedSessionId =
    selectedSessionId.value && sessionRows.some(item => item.session_id === selectedSessionId.value)
      ? selectedSessionId.value
      : null

  useEffect(() => {
    if (selectedAttentionId.value !== activeSelectedAttentionId) {
      selectedAttentionId.value = activeSelectedAttentionId
    }
    if (selectedSessionId.value !== activeSelectedSessionId) {
      selectedSessionId.value = activeSelectedSessionId
    }
  }, [activeSelectedAttentionId, activeSelectedSessionId])

  const activeAttention = mission.attention_queue.find(item => item.id === activeSelectedAttentionId) ?? null
  const attentionSessionId =
    activeAttention?.related_session_ids.find(id => sessionRows.some(item => item.session_id === id)) ?? null
  const activeSessionId = activeSelectedSessionId ?? attentionSessionId ?? sessionRows[0]?.session_id ?? null
  const sessionLookup = sessionLookupById()
  const focusSession = sessionRows.find(item => item.session_id === activeSessionId) ?? null
  const attentionQueue = mission.attention_queue
    .filter(item => item.related_session_ids.length > 0)
    .slice(0, 6)
  const internalSignals = mission.internal_signals.slice(0, 3)
  const attentionSessions = sessionRows.filter(row =>
    row.top_attention != null || row.related_attention_count > 0
  ).length
  const blockerSessions = sessionRows.filter(row => Boolean(row.blocker_summary)).length
  const focusSessionOutputs = ((focusSession?.member_previews ?? []) as Array<{
    agent_name?: string | null
    role?: string | null
    recent_output_preview?: string | null
    status?: string | null
  }>).filter(row => row.recent_output_preview)
  const activityCount = focusSessionOutputs.length
  const hasActivity = activityCount > 0
  const hasAttentionQueue = attentionQueue.length > 0
  const hiddenSectionLabels = hiddenMissionSectionLabels({
    activityCount,
    attentionCount: attentionQueue.length,
  })
  const jumpNavItems = missionJumpNavItems({
    sessionCount: sessionRows.length,
    activityCount,
    attentionCount: attentionQueue.length,
  })

  useEffect(() => {
    void refreshMissionSessionDetail(activeSessionId)
  }, [activeSessionId])

  return html`
    <section class="flex flex-col gap-5">
      <div class="flex items-center justify-end gap-2 flex-wrap">
        <span class="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-[10px] font-medium border border-[var(--card-border)] bg-[var(--white-3)] text-[var(--text-body)]">
          <span class="w-1.5 h-1.5 rounded-full ${toneClass(mission.summary.room_health) === 'ok' ? 'bg-[var(--ok)]' : toneClass(mission.summary.room_health) === 'warn' ? 'bg-[var(--warn)]' : 'bg-[var(--bad)]'}"></span>
          ${statusLabel(mission.summary.room_health)}
        </span>
        <span class="text-[10px] text-[var(--text-muted)]">${mission.generated_at ? relativeTime(mission.generated_at) : ''}</span>
      </div>

      <!-- Summary stats row -->
      <div class="grid grid-cols-[repeat(auto-fit,minmax(120px,1fr))] gap-3">
        <${SummaryStat}
          label="세션"
          value=${sessionRows.length}
          detail="진행 중"
          tone=${focusSession?.top_attention?.severity ?? focusSession?.health ?? 'ok'}
        />
        <${SummaryStat}
          label="주의"
          value=${attentionSessions}
          detail="attention"
          tone=${attentionSessions > 0 ? 'warn' : 'ok'}
        />
        <${SummaryStat}
          label="막힘"
          value=${blockerSessions}
          detail="blocker"
          tone=${blockerSessions > 0 ? 'warn' : 'ok'}
        />
      </div>

      <!-- Jump nav -->
      <nav class="flex gap-2 flex-wrap">
        ${jumpNavItems.map(item => html`
          <button type="button"
            key=${item.id}
            class="px-2.5 py-1 rounded-full border border-[var(--card-border)] bg-[var(--white-3)] text-xs text-[var(--text-body)] cursor-pointer hover:bg-[var(--white-8)] transition-colors"
            onClick=${(e: Event) => { e.preventDefault(); document.getElementById(item.id)?.scrollIntoView({ behavior: 'smooth' }) }}
          >${item.label} ${item.count}</button>
        `)}
      </nav>

      <!-- Focus session indicator -->
      ${activeSessionId
        ? html`
            <div class="flex items-center justify-between gap-3 px-4 py-2.5 rounded-lg border border-[var(--white-8)] bg-[var(--white-4)] text-xs text-[var(--text-body)]">
              <span class="truncate">관찰 세션: ${focusSession?.goal ?? activeSessionId}${activeAttention ? ` / ${activeAttention.summary}` : ''}</span>
              <button type="button" class="shrink-0 px-2 py-1 rounded border border-[var(--card-border)] bg-transparent text-[10px] text-[var(--text-muted)] cursor-pointer hover:bg-[var(--white-6)]" onClick=${clearMissionSelection}>해제</button>
            </div>
          `
        : null}

      <${MissionBriefingCard} />

      ${hiddenSectionLabels.length > 0
        ? html`
            <div class="rounded-lg border border-[var(--card-border)] bg-[var(--white-3)] px-4 py-3 text-xs text-[var(--text-muted)]">
              데이터가 없는 섹션은 숨깁니다: ${hiddenSectionLabels.join(' · ')}
            </div>
          `
        : null}

      <!-- Sessions -->
      <${Card} title="진행중인 세션" class="mission-list-card rounded-lg" id="mission-sessions">
        <div class="mb-4">
          <h3 class="m-0 text-sm font-semibold text-[var(--text-strong)]">세션 목록</h3>
          <p class="m-0 mt-1 text-xs text-[var(--text-muted)]">세션 기준 목표, 최근 흐름, 막힘 상태.</p>
          <${ProvenanceStrip} items=${[{ kind: 'truth' }]} />
        </div>
        <div class="flex flex-col gap-3">
          ${sessionRows.length > 0
            ? sessionRows.map(row => html`<${SessionBriefCard} key=${row.session_id} brief=${row} selected=${activeSessionId === row.session_id} />`)
            : html`<div class="text-xs text-[var(--text-muted)] py-4 text-center">활성 세션 없음</div>`}
        </div>
      <//>

      <${SessionDetailCard}
        detail=${missionSessionDetail.value}
        loading=${missionSessionDetailLoading.value}
        error=${missionSessionDetailError.value}
      />

      <!-- Keepers -->
      <!-- Activity -->
      ${hasActivity
        ? html`
            <details open id="mission-output" class="rounded-lg border border-[var(--card-border)] overflow-hidden">
              <summary class="mission-collapsible-summary flex items-center gap-2 px-4 py-3 cursor-pointer text-sm font-medium text-[var(--text-strong)]">
                최근 활동
                <${CountBadge}>${activityCount}<//>
              </summary>
              <div class="p-4 pt-0">
                <div class="mb-3">
                  <p class="m-0 text-xs text-[var(--text-muted)]">선택된 세션과 연결된 행위자의 최근 출력.</p>
                  <${ProvenanceStrip} items=${[{ kind: 'truth' }]} />
                </div>
                <div class="flex flex-col gap-3">
                  ${focusSessionOutputs.slice(0, 4).map(row => html`
                    <div class="flex flex-col gap-1 p-3 rounded-lg border border-[var(--white-6)] bg-[var(--white-3)]">
                      <div class="flex items-center gap-2">
                        <span class="text-xs font-medium text-[var(--text-strong)]">${row.agent_name ?? 'unknown'}</span>
                        ${row.role ? html`<span class="text-[10px] text-[var(--text-muted)]">${row.role}</span>` : null}
                        ${row.status ? html`<span class="text-[10px] text-[var(--text-muted)]">${statusLabel(row.status)}</span>` : null}
                      </div>
                      <div class="text-xs text-[var(--text-body)] leading-relaxed">${row.recent_output_preview}</div>
                    </div>
                  `)}
                </div>
              </div>
            </details>
          `
        : null}

      <!-- Attention queue -->
      ${hasAttentionQueue
        ? html`
            <details open id="mission-attention" class="rounded-lg border border-[var(--card-border)] overflow-hidden">
              <summary class="mission-collapsible-summary flex items-center gap-2 px-4 py-3 cursor-pointer text-sm font-medium text-[var(--text-strong)]">
                세션 우선순위
                <span class="text-[10px] px-1.5 py-px rounded bg-[var(--warn-12)] text-[var(--warn)] tabular-nums">${attentionQueue.length}</span>
              </summary>
              <div class="p-4 pt-0">
                <div class="mb-3">
                  <p class="m-0 text-xs text-[var(--text-muted)]">주의 신호 기준 세션 집중 순서.</p>
                  <${ProvenanceStrip} items=${[{ kind: 'derived' }]} />
                </div>
                <div class="flex flex-col gap-3">
                  ${attentionQueue.map(item => html`<${AttentionCard} key=${item.id} item=${item} selected=${activeSelectedAttentionId === item.id} sessionLookup=${sessionLookup} />`)}
                </div>
              </div>
            </details>
          `
        : null}

      ${internalSignals.length > 0 ? html`
        <details class="rounded-lg border border-[var(--card-border)] overflow-hidden">
          <summary class="flex items-center gap-2 px-4 py-3 cursor-pointer text-xs text-[var(--text-muted)]">
            내부 신호
            <${CountBadge}>${internalSignals.length}<//>
          </summary>
          <div class="flex flex-col gap-3 p-4 pt-0">
            ${internalSignals.map(item => html`<${InternalSignalCard} key=${item.id} item=${item} />`)}
          </div>
        </details>
      ` : null}
    </section>
  `
}
