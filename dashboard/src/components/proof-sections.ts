import { html } from 'htm/preact'
import { StatusChip } from './common/status-chip'
import { toolCategory } from './tool-call-shared'
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
    <div class="bg-card/30 backdrop-blur-sm border border-card-border/50 p-5 rounded-2xl shadow-sm cmd-guide-card ${selectionTone(selection)}">
      <div class="flex items-center justify-between mb-3 pb-3 border-b border-card-border/50">
        <strong class="text-[13px] text-text-strong tracking-wide">${selectionLabel(selection)}</strong>
        <span class="px-2.5 py-1 rounded-md text-[10px] font-bold uppercase tracking-widest bg-white/5 border border-white/10 ${selectionTone(selection)}">${selection.mode ?? 'none'}</span>
      </div>
      <p class="text-[13px] text-text-body leading-relaxed mb-4">${selection.reason ?? '근거 컨텍스트 선택 정보가 없습니다.'}</p>
      ${historicalStronger
        ? html`<p class="text-[12px] text-warn/90 bg-warn/10 p-3 rounded-xl border border-warn/20 mb-4 shadow-inner">선택된 최신 세션은 과거 proof가 더 강하고 현재 live evidence는 더 약합니다.</p>`
        : null}
      <div class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-2.5 text-[12px] bg-bg-1/40 p-4 rounded-xl shadow-inner border border-white/5">
        <span class="text-text-muted font-medium">선택된 세션</span><span class="text-text-strong font-mono">${selection.selected_session_id ?? '없음'}</span>
        <span class="text-text-muted font-medium">작성자</span><span class="text-text-strong">${selection.selected_created_by ?? '없음'}</span>
        <span class="text-text-muted font-medium">선택된 목표</span><span class="text-text-strong">${selection.selected_goal ?? '없음'}</span>
        <span class="text-text-muted font-medium">선택 가능한 세션</span><span class="text-text-strong">${selection.available_session_count ?? 0}</span>
      </div>
    </div>
  `
}

export function ToolEvidenceRow({ item }: { item: DashboardProofToolEvidence }) {
  return html`
    <article class="p-4 rounded-xl border border-card-border bg-card/40 backdrop-blur-md shadow-sm hover:-translate-y-0.5 hover:shadow-md hover:bg-card/60 transition-all duration-200">
      <div class="flex items-start justify-between gap-4 mb-3">
        <div class="flex flex-col gap-1.5 min-w-0">
          <strong class="text-[13px] text-text-strong truncate">${item.summary ?? item.event_type ?? '도구 근거'}</strong>
          <div class="flex items-center gap-2 text-[11px] font-medium text-text-muted">
            <span class="px-2 py-0.5 rounded-md bg-white/5 border border-white/10">${item.actor ?? '시스템'}</span>
            <span class="text-text-dim/60">•</span>
            <span class="font-mono">${item.event_type ?? 'event'}</span>
          </div>
        </div>
        <span class="text-[11px] font-mono text-text-dim bg-white/5 px-2 py-0.5 rounded-md border border-white/5 shrink-0">${relativeTime(item.timestamp ?? null)}</span>
      </div>
      ${(() => {
        const tags = toolEvidenceTags(item)
        return tags.length > 0
          ? html`<div class="flex flex-wrap gap-2 mt-3 pt-3 border-t border-card-border/50">
              ${tags.map(name => html`<span class="px-2 py-1 rounded-md text-[10px] font-medium bg-[var(--accent-10)] text-accent border border-accent/20 shadow-sm">${name}</span>`)}
            </div>`
          : null
      })()}
    </article>
  `
}

export function WorkerRunEvidenceRow({ item }: { item: DashboardProofWorkerRunEvidence }) {
  const preview = workerRunEvidencePreview(item)
  const validationFailures = Array.isArray(item.validation_failures) ? item.validation_failures : []
  const toolSurfaceNames = Array.isArray(item.tool_surface_names) ? item.tool_surface_names : []
  const toolNames = Array.isArray(item.tool_names) ? item.tool_names : []
  const traceWorkerRunId =
    item.trace_ref && typeof item.trace_ref.worker_run_id === 'string'
      ? item.trace_ref.worker_run_id
      : null
  const conformance =
    item.session_conformance && typeof item.session_conformance === 'object' && !Array.isArray(item.session_conformance)
      ? item.session_conformance
      : null
  const conformanceChecks = Array.isArray(conformance?.checks) ? conformance.checks : []
  const conformanceFailures = conformanceChecks.filter(check => check && typeof check === 'object' && 'passed' in check && (check as { passed?: unknown }).passed === false)
  const proofEvidenceCount =
    typeof item.proof_evidence_count === 'number'
      ? item.proof_evidence_count
      : Array.isArray(item.raw_evidence_refs)
        ? item.raw_evidence_refs.length
        : null
  return html`
    <article class="p-4 rounded-xl border border-card-border bg-card/40 backdrop-blur-md shadow-sm hover:border-accent/30 transition-all duration-200 flex flex-col gap-3">
      <div class="flex justify-between gap-4 items-start">
        <div class="flex flex-col gap-1.5 min-w-0">
          <strong class="text-[13px] text-text-strong font-bold tracking-wide">${item.worker_name ?? item.worker_run_id}</strong>
          <div class="flex flex-wrap gap-2 text-[11px] text-text-muted font-medium items-center">
            <span class="font-mono bg-white/5 px-1.5 py-0.5 rounded border border-white/5">${item.worker_run_id}</span>
            <span class="text-text-dim/60">•</span>
            <span>${item.ts_iso ? relativeTime(item.ts_iso) : '기록 없음'}</span>
          </div>
        </div>
        <span class="px-2.5 py-1 rounded-md text-[10px] font-bold uppercase tracking-widest shadow-sm ${workerRunEvidenceTone(item)}">
          ${workerRunEvidenceLabel(item)}
        </span>
      </div>
      <div class="text-[11px] text-text-body/80 bg-white/5 p-2 rounded-lg border border-white/10 mt-1 shadow-inner">
        ${workerRunEvidenceMeta(item) || 'runtime/model 메타데이터 없음'}
      </div>
      ${preview
        ? html`<div class="flex flex-col gap-1.5 py-3 px-4 rounded-xl border border-card-border bg-bg-1/40 shadow-inner mt-1">
            <strong class="text-[11px] font-semibold uppercase tracking-widest text-text-muted">${item.success === false || item.error || item.failure_reason ? '실패 요약' : '출력 요약'}</strong>
            <span class="text-[12px] text-text-body leading-relaxed whitespace-pre-wrap font-mono opacity-90">${preview}</span>
          </div>`
        : null}
      ${validationFailures.length > 0
        ? html`<div class="flex flex-col gap-1.5 py-3 px-4 rounded-xl border border-warn/30 bg-warn/10 shadow-inner mt-1">
            <strong class="text-[11px] font-semibold uppercase tracking-widest text-warn">검증 실패</strong>
            <span class="text-[12px] text-text-body leading-relaxed whitespace-pre-wrap">${validationFailures.join(' · ')}</span>
          </div>`
        : null}
      ${(traceWorkerRunId || item.evidence_session_id || item.proof_run_id || item.proof_status || conformance)
        ? html`<div class="flex flex-col gap-2 mt-2 pt-3 border-t border-card-border/50">
            <strong class="text-[11px] font-semibold uppercase tracking-widest text-text-muted">증거 식별자</strong>
            <div class="grid gap-1.5 text-[11px] text-text-body">
              ${traceWorkerRunId ? html`<div>trace_ref · <span class="font-mono">${traceWorkerRunId}</span></div>` : null}
              ${item.evidence_session_id ? html`<div>evidence_session · <span class="font-mono">${item.evidence_session_id}</span></div>` : null}
              ${item.proof_run_id ? html`<div>proof_run · <span class="font-mono">${item.proof_run_id}</span></div>` : null}
              ${item.proof_status ? html`<div>proof_status · ${item.proof_status}${proofEvidenceCount != null ? ` · evidence ${proofEvidenceCount}` : ''}</div>` : null}
              ${conformance
                ? html`<div>
                    conformance · ${conformanceFailures.length > 0
                      ? `${conformanceFailures.length} failed`
                      : conformanceChecks.length > 0
                        ? `${conformanceChecks.length} checks ok`
                        : 'report present'}
                  </div>`
                : null}
            </div>
          </div>`
        : null}
      ${toolSurfaceNames.length > 0
        ? html`<div class="flex flex-col gap-2 mt-2 pt-3 border-t border-card-border/50">
            <strong class="text-[11px] font-semibold uppercase tracking-widest text-text-muted">사용 가능 도구</strong>
            <div class="flex flex-wrap gap-2">
              ${toolSurfaceNames.map(name => html`<span class="px-2 py-1 rounded-md text-[10px] font-medium bg-white/5 text-text-body border border-white/10 shadow-sm">${name}</span>`)}
            </div>
          </div>`
        : null}
      ${toolNames.length > 0
        ? html`<div class="flex flex-col gap-2 mt-2 pt-3 border-t border-card-border/50">
            <strong class="text-[11px] font-semibold uppercase tracking-widest text-text-muted">실행 도구</strong>
            <div class="flex flex-wrap gap-2">
              ${toolNames.map(name => {
                const cat = toolCategory(name)
                return html`<span class="inline-flex items-center gap-1 px-2 py-1 rounded-md text-[10px] font-medium bg-[var(--accent-10)] text-accent border border-accent/20 shadow-sm"><span class="font-mono font-bold ${cat.color}">${cat.icon}</span>${name}</span>`
              })}
            </div>
          </div>`
        : null}
    </article>
  `
}

export function TimelineRow({ item }: { item: DedupedTimelineItem }) {
  return html`
    <article class="p-4 rounded-xl border border-card-border bg-card/40 backdrop-blur-md shadow-sm hover:-translate-y-0.5 hover:shadow-md hover:bg-card/60 transition-all duration-200">
      <div class="flex items-start justify-between gap-4">
        <div class="flex flex-col gap-1.5 min-w-0">
          <strong class="text-[13px] text-text-strong font-medium truncate">${item.summary ?? item.event_type ?? '이벤트'}</strong>
          <div class="flex items-center gap-2 text-[11px] font-medium text-text-muted flex-wrap">
            <span class="px-2 py-0.5 rounded-md bg-white/5 border border-white/10">${timelineMetaLabel(item)}</span>
            <span class="px-2 py-0.5 rounded-md bg-[var(--accent-10)] text-accent border border-accent/20 shadow-sm">${item.event_type ?? '이벤트'}</span>
            <span class="text-text-dim/60">•</span>
            <span>${item.actor ?? '시스템'}</span>
          </div>
        </div>
        <span class="text-[11px] font-mono text-text-dim bg-white/5 px-2 py-0.5 rounded-md border border-white/5 shrink-0">${relativeTime(item.timestamp)}</span>
      </div>
      ${item.sources.length > 1
        ? html`<div class="flex flex-wrap gap-2 mt-3 pt-3 border-t border-card-border/50">
            ${item.sources.map(source => html`<span class="px-2 py-1 rounded-md text-[10px] font-medium bg-white/10 text-text-muted border border-white/5 shadow-sm">${source}</span>`)}
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
      <div class="flex justify-between gap-3 items-start">
        <div>
          <strong>${item.actor}</strong>
          <div class="flex flex-wrap gap-3 text-[var(--text-body)] text-[13px] leading-[1.45]">
            <span>${item.role ?? '참여자'}</span>
            <span>${lastSeen ? relativeTime(lastSeen) : '기록 없음'}</span>
          </div>
        </div>
        <${StatusChip} label=${actorActivityLabel(item)} tone=${actorActivityTone(item)} />
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
        ? html`<div class="grid grid-cols-2 gap-3">
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
            ${item.recent_tool_names.map(name => {
              const cat = toolCategory(name)
              return html`<span class="semantic-tag inline-flex items-center gap-1"><span class="font-mono font-bold ${cat.color}">${cat.icon}</span>${name}</span>`
            })}
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
        <${StatusChip} label=${item.exists ? '존재함' : '없음'} tone=${item.exists ? 'ok' : 'warn'} />
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
    <div class="grid gap-3">
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
