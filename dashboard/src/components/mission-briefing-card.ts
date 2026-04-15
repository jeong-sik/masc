import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { Card } from './common/card'
import { EmptyState } from './common/empty-state'
import { TagBadge } from './common/tag-badge'
import { ActionBar, ActionBtn } from './common/action-bar'
import { StatusChip } from './common/status-chip'
import {
  missionSnapshot,
  missionBriefing,
  missionBriefingError,
  missionBriefingLoading,
  refreshMissionBriefing,
} from '../mission-store'
import { keepers } from '../store'
import { operatorSnapshot } from '../operator-store'
import { navigate } from '../router'
import {
  missionTargetTypeLabel,
  relativeTime,
  signalClassLabel,
  statusLabel,
  toneClass,
  trimText,
} from './mission-utils'
import {
  missionInterveneParams,
  persistWorkflowContext,
} from '../workflow-context'
import type { DashboardWorkflowContext } from '../workflow-context'
import type {
  DashboardMissionBriefingResponse,
  DashboardMissionKeeperBrief,
  DashboardMissionResponse,
  Keeper,
  OperatorSnapshot,
} from '../types'

export interface LiveJudgeTarget {
  name: string
  model: string | null
  source: 'judge_runtime' | 'keeper'
  online: boolean
}

function normalizeKeeperStatus(value?: string | null): string {
  return typeof value === 'string' ? value.trim().toLowerCase() : ''
}

function isUnavailableKeeperStatus(status?: string | null): boolean {
  const normalized = normalizeKeeperStatus(status)
  return normalized === 'offline'
    || normalized === 'inactive'
    || normalized === 'dead'
    || normalized === 'crashed'
    || normalized === 'error'
}

function isPreferredKeeperStatus(status?: string | null): boolean {
  const normalized = normalizeKeeperStatus(status)
  return normalized === 'active'
    || normalized === 'running'
    || normalized === 'online'
    || normalized === 'healthy'
}

function keeperModelLabel(item?: {
  last_model_used?: string | null
  active_model?: string | null
  primary_model?: string | null
  model?: string | null
} | null): string | null {
  if (!item) return null
  return item.last_model_used ?? item.active_model ?? item.primary_model ?? item.model ?? null
}

function preferredKeeper(
  snapshotKeepers: Array<{
    name?: string | null
    model?: string | null
    last_model_used?: string | null
    active_model?: string | null
    primary_model?: string | null
    status?: string | null
  }>,
  fallbackKeepers: Keeper[],
): { name: string, model: string | null, online: boolean } | null {
  const snapshotCandidates = snapshotKeepers
    .filter(item => item.name && !isUnavailableKeeperStatus(item.status))
    .sort((left, right) => Number(isPreferredKeeperStatus(right.status)) - Number(isPreferredKeeperStatus(left.status)))
  const firstSnapshot = snapshotCandidates[0]
  if (firstSnapshot?.name) {
    return {
      name: firstSnapshot.name,
      model: keeperModelLabel(firstSnapshot),
      online: isPreferredKeeperStatus(firstSnapshot.status) || !isUnavailableKeeperStatus(firstSnapshot.status),
    }
  }
  const fallback = fallbackKeepers
    .filter(item => !isUnavailableKeeperStatus(item.status))
    .sort((left, right) => Number(isPreferredKeeperStatus(right.status)) - Number(isPreferredKeeperStatus(left.status)))[0]
  if (!fallback) return null
  return {
    name: fallback.name,
    model: keeperModelLabel(fallback),
    online: isPreferredKeeperStatus(fallback.status) || !isUnavailableKeeperStatus(fallback.status),
  }
}

export function resolveLiveJudgeTarget(
  snapshot: OperatorSnapshot | null | undefined,
  fallbackKeepers: Keeper[],
): LiveJudgeTarget | null {
  const runtime = snapshot?.operator_judge_runtime
  const runtimeKeeperName = runtime?.keeper_name?.trim()
  if (runtimeKeeperName) {
    const matchedKeeper =
      snapshot?.keepers?.find(item => item.name === runtimeKeeperName)
      ?? fallbackKeepers.find(item => item.name === runtimeKeeperName)
      ?? null
    return {
      name: runtimeKeeperName,
      model: runtime?.model_used ?? keeperModelLabel(matchedKeeper),
      source: 'judge_runtime',
      online:
        runtime?.judge_online === true
        || (matchedKeeper != null && isPreferredKeeperStatus(matchedKeeper.status)),
    }
  }
  const keeper = preferredKeeper(snapshot?.keepers ?? [], fallbackKeepers)
  if (!keeper) return null
  return {
    name: keeper.name,
    model: keeper.model,
    source: 'keeper',
    online: keeper.online,
  }
}

function fallbackKeepersFromMission(
  mission: DashboardMissionResponse | null | undefined,
): Keeper[] {
  return (mission?.keeper_briefs ?? []).map((keeper: DashboardMissionKeeperBrief) => ({
    name: keeper.name,
    status: keeper.status ?? 'unknown',
  }))
}

export function buildLiveJudgeSituationReport({
  mission,
  briefing,
  target,
}: {
  mission: DashboardMissionResponse | null | undefined
  briefing: DashboardMissionBriefingResponse | null | undefined
  target: LiveJudgeTarget
}): string {
  const namespace = mission?.summary.namespace ?? mission?.summary.namespace_id ?? 'default'
  const roomHealth = mission?.summary.room_health ?? 'unknown'
  const sessionCount = mission?.sessions.length ?? 0
  const attentionCount = mission?.attention_queue.length ?? 0
  const blockerCount = mission?.sessions.filter(item => Boolean(item.blocker_summary)).length ?? 0
  const metadataGapCount = briefing?.metadata_gap_count ?? briefing?.metadata_gaps.length ?? 0
  const sectionSummaries = briefing?.sections.slice(0, 3).map(section =>
    `${section.label}: ${trimText(section.summary, 140) ?? section.summary}`,
  ) ?? []
  const lines = [
    `[상황 보고] ${target.name}${target.model ? ` · ${target.model}` : ''}`,
    `- namespace: ${namespace}`,
    `- namespace_health: ${roomHealth}`,
    `- sessions: ${sessionCount}, attention: ${attentionCount}, blockers: ${blockerCount}`,
    briefing?.summary ? `- deterministic_briefing: ${trimText(briefing.summary, 180) ?? briefing.summary}` : null,
    sectionSummaries.length > 0 ? `- section_highlights: ${sectionSummaries.join(' / ')}` : null,
    metadataGapCount > 0 ? `- metadata_gaps: ${metadataGapCount}` : null,
    '이 브리핑은 dashboard 렌더링용 deterministic 요약입니다. 위 사실 기준으로 live 판단을 해 주세요.',
    '답변 형식: 1) 지금 위험 1-3개 2) 바로 필요한 조치 3) 놓친 관측 공백',
  ]
  return lines.filter((line): line is string => Boolean(line && line.trim() !== '')).join('\n')
}

function createLiveJudgeWorkflowContext(
  target: LiveJudgeTarget,
  mission: DashboardMissionResponse | null | undefined,
  briefing: DashboardMissionBriefingResponse | null | undefined,
): DashboardWorkflowContext {
  const createdAt = new Date().toISOString()
  const message = buildLiveJudgeSituationReport({ mission, briefing, target })
  const metadataGapCount = briefing?.metadata_gap_count ?? briefing?.metadata_gaps.length ?? 0
  return {
    id: ['mission', 'live_judge', target.name, createdAt].join(':'),
    source_surface: 'mission',
    source_label: '실제 판단 에이전트 보고',
    action_type: 'keeper_message',
    target_type: 'keeper',
    target_id: target.name,
    focus_kind: 'live_judgment',
    operation_id: null,
    summary: `${target.name}에게 상황판 요약을 보내 live 판단을 받습니다.`,
    payload_preview: `scope ${mission?.summary.namespace ?? mission?.summary.namespace_id ?? 'default'} · attention ${mission?.attention_queue.length ?? 0} · gaps ${metadataGapCount}`,
    suggested_payload: { message },
    preview: {
      keeper_name: target.name,
      model: target.model,
      report_type: 'live_judgment',
    },
    evidence: {
      briefing_status: briefing?.status ?? null,
      metadata_gap_count: metadataGapCount,
      generated_at: briefing?.generated_at ?? null,
    },
    created_at: createdAt,
  }
}

export function MissionBriefingCard() {
  const mission = missionSnapshot.value
  const briefing = missionBriefing.value
  const liveJudge = resolveLiveJudgeTarget(
    operatorSnapshot.value,
    keepers.value.length > 0 ? keepers.value : fallbackKeepersFromMission(mission),
  )
  const liveJudgeTone = toneClass(liveJudge?.online ? 'ok' : 'warn')
  const liveJudgeReport =
    mission && liveJudge
      ? buildLiveJudgeSituationReport({ mission, briefing, target: liveJudge })
      : null
  const briefingTone = toneClass(briefing?.status ?? (missionBriefingError.value ? 'bad' : 'warn'))
  const showEmpty = !briefing || briefing.sections.length === 0
  const retryNeedsForce =
    briefing?.status === 'error'
    || (briefing?.status === 'unavailable' && !briefing?.cached)

  useEffect(() => {
    let cancelled = false
    if (!briefing && !missionBriefingLoading.value && !missionBriefingError.value) {
      void refreshMissionBriefing().then(() => { if (cancelled) return })
    }
    return () => { cancelled = true }
  }, [briefing, missionBriefingLoading.value, missionBriefingError.value])

  const openLiveJudgeIntervene = () => {
    if (!liveJudge) return
    const context = createLiveJudgeWorkflowContext(liveJudge, mission, briefing)
    persistWorkflowContext(context)
    navigate('command', {
      section: 'operations',
      ...missionInterveneParams(context),
    })
  }

  return html`
    <${Card} title="판단 레이어" class="mission-briefing-card rounded-xl">
      <div class="flex items-center gap-2 flex-wrap mb-4">
        <${StatusChip} label=${statusLabel(briefing?.status ?? (missionBriefingError.value ? 'error' : 'loading'))} tone=${briefingTone} />
        ${liveJudge
          ? html`<${StatusChip}
              label=${`${liveJudge.name}${liveJudge.model ? ' · ' + liveJudge.model : ''}`}
              tone=${liveJudgeTone}
            />`
          : html`<${StatusChip} label="판단 대상 미확인" tone="warn" />`}
        ${liveJudge
          ? html`
              <${StatusChip} label=${liveJudge.online ? '온라인' : '확인 필요'} tone=${liveJudgeTone} />
              <${StatusChip} label=${liveJudge.source === 'judge_runtime' ? 'runtime' : 'fallback'} />
            `
          : null}
        ${briefing?.model ? html`<${StatusChip} label=${briefing.model} />` : null}
        ${briefing?.generated_at ? html`<${StatusChip} label=${relativeTime(briefing.generated_at)} />` : null}
        ${briefing?.cached ? html`<${StatusChip} label="캐시" />` : null}
        ${briefing?.stale ? html`<${StatusChip} label="오래됨" tone="warn" />` : null}
        ${briefing?.refreshing ? html`<${StatusChip} label="갱신 중" tone="warn" />` : null}
      </div>

      ${missionBriefingError.value ? html`<${EmptyState} message=${missionBriefingError.value} compact />` : null}
      ${briefing?.error ? html`<${EmptyState} message=${briefing.error} compact />` : null}
      ${briefing?.summary ? html`<div class="grid gap-1.5">${briefing.summary}</div>` : null}
      ${briefing?.last_error && !briefing.error
        ? html`<div class="grid gap-1.5">최근 갱신 실패: ${briefing.last_error}</div>`
        : null}

      ${briefing && briefing.sections.length > 0
        ? html`
            <div class="grid grid-cols-3 gap-3 mt-3">
              ${briefing.sections.slice(0, 3).map(section => html`
                <article class="p-4 rounded-xl border border-[var(--white-8)] bg-[var(--white-4)] grid gap-3 ${toneClass(section.status)}">
                  <div class="flex justify-between gap-3 items-start flex-wrap">
                    <strong>${section.label}</strong>
                    <div class="flex gap-2 flex-wrap justify-end">
                      <${StatusChip} label=${statusLabel(section.status)} tone=${toneClass(section.status)} />
                      ${signalClassLabel(section.signal_class)
                        ? html`<${StatusChip} label=${signalClassLabel(section.signal_class)} tone=${section.signal_class === 'mixed' ? 'warn' : ''} />`
                        : null}
                      ${section.evidence_quality ? html`<${StatusChip} label=${section.evidence_quality} />` : null}
                    </div>
                  </div>
                  <p class="m-0 text-[var(--text-body)] leading-normal">${section.summary}</p>
                  ${section.evidence.length > 0
                    ? html`
                        <details class="pt-2 border-t border-[var(--white-6)] mt-3">
                          <summary>근거 보기</summary>
                          <div class="flex gap-3 flex-wrap mt-3">
                            ${section.evidence.map(item => html`<${TagBadge}>${item}<//>`)}
                          </div>
                        </details>
                      `
                    : null}
                </article>
              `)}
            </div>
          `
        : (!missionBriefingLoading.value && !missionBriefingError.value && showEmpty
            ? html`
                <${EmptyState} message=${briefing?.status === 'pending'
                    ? '최신 스냅샷으로 브리핑을 생성 중입니다. 마지막 성공 결과가 생기면 자동으로 다시 읽습니다.'
                    : '판단 결과가 아직 없습니다.'} compact />
              `
            : null)}

      ${briefing && briefing.metadata_gaps.length > 0
        ? html`
            <details class="pt-2 border-t border-[var(--white-6)] mt-4">
              <summary>관측 공백 (${briefing.metadata_gap_count ?? briefing.metadata_gaps.length})</summary>
              <div class="flex flex-col gap-3 mt-3">
                ${briefing.metadata_gaps.map(item => html`
                  <article class="p-4 rounded-xl border border-[var(--white-8)] bg-[var(--white-3)] grid gap-3 ${item.severity === 'watch' ? 'warn' : ''}">
                    <div class="flex justify-between gap-3 items-start flex-wrap">
                      <strong>${missionTargetTypeLabel(item.scope_type)}${item.scope_id ? ` · ${item.scope_id}` : ''}</strong>
                      <${StatusChip} label=${statusLabel(item.severity)} tone=${item.severity === 'watch' ? 'warn' : ''} />
                    </div>
                    <p class="m-0 text-[var(--text-body)] leading-snug">${item.summary}</p>
                  </article>
                `)}
              </div>
            </details>
          `
        : null}

      ${liveJudgeReport
        ? html`
            <details class="pt-2 border-t border-[var(--white-6)] mt-4">
              <summary class="text-xs text-[var(--text-muted)] cursor-pointer">상황 보고 프리뷰</summary>
              <pre class="m-0 mt-2 whitespace-pre-wrap rounded-lg border border-[var(--white-6)] bg-[var(--white-2)] p-3 text-[12px] leading-[1.55] text-[var(--text-muted)]">${liveJudgeReport}</pre>
            </details>
          `
        : null}

      <${ActionBar}>
        <${ActionBtn}
          label=${liveJudge ? '실제 판단 요청' : '판단 대상 없음'}
          onClick=${openLiveJudgeIntervene}
          disabled=${!liveJudge}
        />
        <${ActionBtn}
          label=${missionBriefingLoading.value ? '응답 기다리는 중…' : '판단 다시 읽기'}
          onClick=${() => { void refreshMissionBriefing(retryNeedsForce) }}
          disabled=${missionBriefingLoading.value}
        />
        <${ActionBtn}
          label="강제 갱신"
          onClick=${() => { void refreshMissionBriefing(true) }}
          disabled=${missionBriefingLoading.value}
        />
      <//>
    <//>
  `
}
