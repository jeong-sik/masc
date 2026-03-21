import { html } from 'htm/preact'
import type {
  DashboardProofActorContribution,
  DashboardProofArtifactRef,
  DashboardProofSelection,
  DashboardProofToolEvidence,
  DashboardProofVerdict,
} from '../types'
import { relativeTime } from './command/helpers'
import {
  actorActivityLabel,
  actorActivityMeta,
  actorActivityTone,
  compactPath,
  selectionLabel,
  selectionTone,
  timelineMetaLabel,
  toolEvidenceTags,
  type DedupedTimelineItem,
} from './proof-helpers'

export function SelectionCard({
  selection,
  summary,
}: {
  selection?: DashboardProofSelection | null
  summary?: {
    historical_verdict?: DashboardProofVerdict | null
    live_verdict?: DashboardProofVerdict | null
  } | null
}) {
  if (!selection || selection.mode === 'explicit') return null
  const historicalStronger =
    selection.mode === 'latest_auto_selected'
    && summary?.historical_verdict === 'proven'
    && summary?.live_verdict !== 'proven'
  return html`
    <div class="command-guide-card ${selectionTone(selection)}">
      <div class="command-guide-head">
        <strong>${selectionLabel(selection)}</strong>
        <span class="command-chip ${selectionTone(selection)}">${selection.mode ?? 'none'}</span>
      </div>
      <p>${selection.reason ?? '근거 컨텍스트 선택 정보가 없습니다.'}</p>
      ${historicalStronger
        ? html`<p>선택된 최신 세션은 과거 proof가 더 강하고 현재 live evidence는 더 약합니다.</p>`
        : null}
      <div class="command-card-grid">
        <span>선택된 세션</span><span>${selection.selected_session_id ?? '없음'}</span>
        <span>작성자</span><span>${selection.selected_created_by ?? '없음'}</span>
        <span>선택된 목표</span><span>${selection.selected_goal ?? '없음'}</span>
        <span>선택 가능한 세션</span><span>${selection.available_session_count ?? 0}</span>
      </div>
    </div>
  `
}

export function ToolEvidenceRow({ item }: { item: DashboardProofToolEvidence }) {
  return html`
    <article class="command-card proof-artifact-row">
      <div class="command-card-head">
        <div>
          <strong>${item.summary ?? item.event_type ?? '도구 근거'}</strong>
          <div class="command-meta-line">
            <span>${item.actor ?? '시스템'}</span>
            <span>${item.event_type ?? 'event'}</span>
          </div>
        </div>
        <span class="command-chip">${relativeTime(item.timestamp ?? null)}</span>
      </div>
      ${(() => {
        const tags = toolEvidenceTags(item)
        return tags.length > 0
          ? html`<div class="semantic-tag-row">
              ${tags.map(name => html`<span class="semantic-tag">${name}</span>`)}
            </div>`
          : null
      })()}
    </article>
  `
}

export function TimelineRow({ item }: { item: DedupedTimelineItem }) {
  return html`
    <article class="command-card proof-timeline-row">
      <div class="command-card-head">
        <div>
          <strong>${item.summary ?? item.event_type ?? '이벤트'}</strong>
          <div class="command-meta-line">
            <span>${timelineMetaLabel(item)}</span>
            <span>${item.event_type ?? '이벤트'}</span>
            <span>${item.actor ?? '시스템'}</span>
          </div>
        </div>
        <span class="command-chip">${relativeTime(item.timestamp)}</span>
      </div>
      ${item.sources.length > 1
        ? html`<div class="semantic-tag-row">
            ${item.sources.map(source => html`<span class="semantic-tag">${source}</span>`)}
          </div>`
        : null}
    </article>
  `
}

export function ActorContributionRow({ item }: { item: DashboardProofActorContribution }) {
  const output = item.recent_output_preview ?? null
  const input = item.recent_input_preview ?? null
  const eventSummary = item.recent_event_summary ?? null
  const requestPreview = item.recent_request_preview ?? null
  const lastSeen = item.last_active_at ?? item.recent_request_at ?? null
  const isPlanned = item.activity_state === 'planned_only'
  return html`
    <article class="mission-activity-row proof-actor-row" style="${isPlanned ? 'opacity: 0.45;' : ''}">
      <div class="mission-activity-head">
        <div>
          <strong>${item.actor}</strong>
          <div class="mission-activity-meta">
            <span>${item.role ?? '참여자'}</span>
            <span>${lastSeen ? relativeTime(lastSeen) : '기록 없음'}</span>
          </div>
        </div>
        <span class="command-chip ${actorActivityTone(item)}">
          ${actorActivityLabel(item)}
        </span>
      </div>
      <div class="mission-activity-copy">
        <span>${actorActivityMeta(item)}</span>
      </div>
      ${item.activity_detail
        ? html`<div class="proof-summary-block">
            <strong>현재 해석</strong>
            <span>${item.activity_detail}</span>
          </div>`
        : null}
      ${eventSummary
        ? html`<div class="proof-summary-block">
            <strong>최근 흔적</strong>
            <span>${eventSummary}</span>
          </div>`
        : null}
      ${requestPreview && item.activity_state !== 'acted'
        ? html`<div class="proof-summary-block">
            <strong>최근 요청</strong>
            <span>${requestPreview}</span>
          </div>`
        : null}
      ${(input || output)
        ? html`<div class="proof-io-grid">
            <div class="mission-activity-preview">
              <strong>최근 입력</strong>
              <span>${input ?? '표시 가능한 입력 없음'}</span>
            </div>
            <div class="mission-activity-preview">
              <strong>최근 응답</strong>
              <span>${output ?? '표시 가능한 응답 없음'}</span>
            </div>
          </div>`
        : null}
      ${Array.isArray(item.recent_tool_names) && item.recent_tool_names.length > 0
        ? html`<div class="semantic-tag-row">
            ${item.recent_tool_names.map(name => html`<span class="semantic-tag">${name}</span>`)}
          </div>`
        : null}
    </article>
  `
}

export function ArtifactRow({ item }: { item: DashboardProofArtifactRef }) {
  return html`
    <article class="command-card proof-artifact-row">
      <div class="command-card-head">
        <div>
          <strong>${item.kind}</strong>
          <div class="command-meta-line">
            <span>${compactPath(item.path)}</span>
          </div>
        </div>
        <span class="command-chip ${item.exists ? 'ok' : 'warn'}">${item.exists ? '존재함' : '없음'}</span>
      </div>
    </article>
  `
}

export function KeyValueGrid({
  title,
  rows,
}: {
  title?: string
  rows: Array<{ label: string; value: string }>
}) {
  if (rows.length === 0) return null
  return html`
    <div class="proof-kv-block">
      ${title ? html`<strong>${title}</strong>` : null}
      <div class="proof-kv-grid">
        ${rows.map(row => html`
          <span>${row.label}</span>
          <strong>${row.value}</strong>
        `)}
      </div>
    </div>
  `
}
