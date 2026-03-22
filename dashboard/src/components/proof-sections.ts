import { html } from 'htm/preact'
import type {
  DashboardProofActorContribution,
  DashboardProofArtifactRef,
  DashboardProofSelection,
  DashboardProofToolEvidence,
  DashboardProofWorkerRunEvidence,
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
  workerRunEvidenceLabel,
  workerRunEvidenceMeta,
  workerRunEvidencePreview,
  workerRunEvidenceTone,
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
    <div class="bg-[var(--white-4)] border border-[var(--white-8)] p-3.5 rounded-xl cmd-guide-card ${selectionTone(selection)}">
      <div class="command-guide-head">
        <strong>${selectionLabel(selection)}</strong>
        <span class="cmd-chip rounded-full ${selectionTone(selection)}">${selection.mode ?? 'none'}</span>
      </div>
      <p>${selection.reason ?? '근거 컨텍스트 선택 정보가 없습니다.'}</p>
      ${historicalStronger
        ? html`<p>선택된 최신 세션은 과거 proof가 더 강하고 현재 live evidence는 더 약합니다.</p>`
        : null}
      <div class="cmd-card rounded-xl-grid">
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
    <article class="cmd-card rounded-xl proof-artifact-row">
      <div class="cmd-card rounded-xl-head">
        <div>
          <strong>${item.summary ?? item.event_type ?? '도구 근거'}</strong>
          <div class="command-meta-line">
            <span>${item.actor ?? '시스템'}</span>
            <span>${item.event_type ?? 'event'}</span>
          </div>
        </div>
        <span class="cmd-chip rounded-full">${relativeTime(item.timestamp ?? null)}</span>
      </div>
      ${(() => {
        const tags = toolEvidenceTags(item)
        return tags.length > 0
          ? html`<div class="flex flex-wrap gap-1.5 mb-3">
              ${tags.map(name => html`<span class="semantic-tag">${name}</span>`)}
            </div>`
          : null
      })()}
    </article>
  `
}

export function WorkerRunEvidenceRow({ item }: { item: DashboardProofWorkerRunEvidence }) {
  const preview = workerRunEvidencePreview(item)
  const validationFailures = Array.isArray(item.validation_failures) ? item.validation_failures : []
  const toolNames = Array.isArray(item.tool_names) ? item.tool_names : []
  return html`
    <article class="proof-actor-row">
      <div class="flex justify-between gap-2.5 items-start">
        <div>
          <strong>${item.worker_name ?? item.worker_run_id}</strong>
          <div class="flex flex-wrap gap-2.5 text-[rgba(255,255,255,0.68)] text-[length:var(--fs-sm)] leading-[1.45]">
            <span>${item.worker_run_id}</span>
            <span>${item.ts_iso ? relativeTime(item.ts_iso) : '기록 없음'}</span>
          </div>
        </div>
        <span class="cmd-chip ${workerRunEvidenceTone(item)}">
          ${workerRunEvidenceLabel(item)}
        </span>
      </div>
      <div class="grid gap-1">
        <span>${workerRunEvidenceMeta(item) || 'runtime/model 메타데이터 없음'}</span>
      </div>
      ${preview
        ? html`<div class="grid gap-1.5 py-3 px-3.5 rounded-xl border border-[var(--white-8)] bg-[var(--white-4)]">
            <strong class="text-[var(--text-strong)]">${item.success === false || item.error || item.failure_reason ? '실패 요약' : '출력 요약'}</strong>
            <span class="text-[rgba(255,255,255,0.8)] leading-normal">${preview}</span>
          </div>`
        : null}
      ${validationFailures.length > 0
        ? html`<div class="grid gap-1.5 py-3 px-3.5 rounded-xl border border-[var(--warn-soft)] bg-[rgba(251,191,36,0.08)]">
            <strong class="text-[var(--text-strong)]">검증 실패</strong>
            <span class="text-[rgba(255,255,255,0.8)] leading-normal">${validationFailures.join(' · ')}</span>
          </div>`
        : null}
      ${toolNames.length > 0
        ? html`<div class="flex flex-wrap gap-1.5 mb-3">
            ${toolNames.map(name => html`<span class="semantic-tag">${name}</span>`)}
          </div>`
        : null}
    </article>
  `
}

export function TimelineRow({ item }: { item: DedupedTimelineItem }) {
  return html`
    <article class="cmd-card rounded-xl proof-timeline-row">
      <div class="cmd-card rounded-xl-head">
        <div>
          <strong>${item.summary ?? item.event_type ?? '이벤트'}</strong>
          <div class="command-meta-line">
            <span>${timelineMetaLabel(item)}</span>
            <span>${item.event_type ?? '이벤트'}</span>
            <span>${item.actor ?? '시스템'}</span>
          </div>
        </div>
        <span class="cmd-chip rounded-full">${relativeTime(item.timestamp)}</span>
      </div>
      ${item.sources.length > 1
        ? html`<div class="flex flex-wrap gap-1.5 mb-3">
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
    <article class="proof-actor-row" style="${isPlanned ? 'opacity: 0.45;' : ''}">
      <div class="flex justify-between gap-2.5 items-start">
        <div>
          <strong>${item.actor}</strong>
          <div class="flex flex-wrap gap-2.5 text-[rgba(255,255,255,0.68)] text-[length:var(--fs-sm)] leading-[1.45]">
            <span>${item.role ?? '참여자'}</span>
            <span>${lastSeen ? relativeTime(lastSeen) : '기록 없음'}</span>
          </div>
        </div>
        <span class="cmd-chip rounded-full ${actorActivityTone(item)}">
          ${actorActivityLabel(item)}
        </span>
      </div>
      <div class="grid gap-1">
        <span>${actorActivityMeta(item)}</span>
      </div>
      ${item.activity_detail
        ? html`<div class="grid gap-1.5 py-3 px-3.5 rounded-xl border border-[var(--white-8)] bg-[var(--white-4)]">
            <strong>현재 해석</strong>
            <span>${item.activity_detail}</span>
          </div>`
        : null}
      ${eventSummary
        ? html`<div class="grid gap-1.5 py-3 px-3.5 rounded-xl border border-[var(--white-8)] bg-[var(--white-4)]">
            <strong>최근 흔적</strong>
            <span>${eventSummary}</span>
          </div>`
        : null}
      ${requestPreview && item.activity_state !== 'acted'
        ? html`<div class="grid gap-1.5 py-3 px-3.5 rounded-xl border border-[var(--white-8)] bg-[var(--white-4)]">
            <strong>최근 요청</strong>
            <span>${requestPreview}</span>
          </div>`
        : null}
      ${(input || output)
        ? html`<div class="grid grid-cols-2 gap-2.5">
            <div class="p-3 rounded-xl bg-[var(--white-3)] border border-[var(--white-6)] grid gap-1">
              <strong>최근 입력</strong>
              <span>${input ?? '표시 가능한 입력 없음'}</span>
            </div>
            <div class="p-3 rounded-xl bg-[var(--white-3)] border border-[var(--white-6)] grid gap-1">
              <strong>최근 응답</strong>
              <span>${output ?? '표시 가능한 응답 없음'}</span>
            </div>
          </div>`
        : null}
      ${Array.isArray(item.recent_tool_names) && item.recent_tool_names.length > 0
        ? html`<div class="flex flex-wrap gap-1.5 mb-3">
            ${item.recent_tool_names.map(name => html`<span class="semantic-tag">${name}</span>`)}
          </div>`
        : null}
    </article>
  `
}

export function ArtifactRow({ item }: { item: DashboardProofArtifactRef }) {
  return html`
    <article class="cmd-card rounded-xl proof-artifact-row">
      <div class="cmd-card rounded-xl-head">
        <div>
          <strong>${item.kind}</strong>
          <div class="command-meta-line">
            <span>${compactPath(item.path)}</span>
          </div>
        </div>
        <span class="cmd-chip rounded-full ${item.exists ? 'ok' : 'warn'}">${item.exists ? '존재함' : '없음'}</span>
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
    <div class="grid gap-2.5">
      ${title ? html`<strong>${title}</strong>` : null}
      <div class="grid grid-cols-[132px_minmax(0,1fr)] gap-x-3 gap-y-2">
        ${rows.map(row => html`
          <span>${row.label}</span>
          <strong>${row.value}</strong>
        `)}
      </div>
    </div>
  `
}
