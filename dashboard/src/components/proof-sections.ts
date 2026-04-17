import { html } from 'htm/preact'
import { RouteLink } from './common/route-link'
import { CopyIdButton } from './common/copy-id-button'
import { toolCategory } from './tool-call-shared'
import type { DashboardProofWorkerRunEvidence } from '../types'
import { relativeTime } from '../lib/format-time'
import {
  workerRunEvidenceLabel,
  workerRunEvidenceMeta,
  workerRunEvidencePreview,
  workerRunEvidenceTone,
} from './proof-helpers'

export function WorkerRunEvidenceRow({ item }: { item: DashboardProofWorkerRunEvidence }) {
  const preview = workerRunEvidencePreview(item)
  const validationFailures = Array.isArray(item.validation_failures) ? item.validation_failures : []
  const toolSurfaceNames = Array.isArray(item.tool_surface_names) ? item.tool_surface_names : []
  const toolNames = Array.isArray(item.tool_names) ? item.tool_names : []
  const scopeParams: Record<string, string> = {
    section: 'telemetry',
    ...(item.session_id ? { session_id: item.session_id } : {}),
    ...(item.operation_id ? { operation_id: item.operation_id } : {}),
    ...(item.worker_run_id ? { worker_run_id: item.worker_run_id } : {}),
  }
  return html`
    <article class="p-4 rounded-xl border border-card-border bg-card/40 backdrop-blur-md shadow-sm hover:border-accent/30 transition-all duration-200 flex flex-col gap-3">
      <div class="flex justify-between gap-4 items-start">
        <div class="flex flex-col gap-1.5 min-w-0">
          <strong class="text-[13px] text-text-strong font-bold tracking-wide">${item.worker_name ?? item.worker_run_id}</strong>
          <div class="flex flex-wrap gap-2 text-[11px] text-text-muted font-medium items-center">
            <span class="inline-flex items-center gap-1">
              <span class="font-mono bg-white/5 px-1.5 py-0.5 rounded border border-white/5" title=${item.worker_run_id}>${item.worker_run_id}</span>
              <${CopyIdButton} value=${item.worker_run_id} label="worker_run_id" size=${10} />
            </span>
            ${item.session_id ? html`<span class="inline-flex items-center gap-1">
              <span class="font-mono bg-white/5 px-1.5 py-0.5 rounded border border-white/5" title=${item.session_id}>S ${item.session_id}</span>
              <${CopyIdButton} value=${item.session_id} label="session_id" size=${10} />
            </span>` : null}
            ${item.operation_id ? html`<span class="inline-flex items-center gap-1">
              <span class="font-mono bg-white/5 px-1.5 py-0.5 rounded border border-white/5" title=${item.operation_id}>OP ${item.operation_id}</span>
              <${CopyIdButton} value=${item.operation_id} label="operation_id" size=${10} />
            </span>` : null}
            <span class="text-text-dim/60">•</span>
            <span>${item.ts_iso ? relativeTime(item.ts_iso) : '기록 없음'}</span>
          </div>
        </div>
        <div class="flex flex-col items-end gap-2">
          <span class="px-2.5 py-1 rounded-md text-[10px] font-bold uppercase tracking-widest shadow-sm ${workerRunEvidenceTone(item)}">
            ${workerRunEvidenceLabel(item)}
          </span>
          <${RouteLink}
            tab="monitoring"
            params=${scopeParams}
            class="rounded-md border border-white/10 bg-white/5 px-2 py-1 text-[10px] font-medium text-text-muted hover:text-text-strong hover:bg-white/10"
          >
            Runtime Diagnosis
          <//>
        </div>
      </div>
      <div class="text-[11px] text-text-body/80 bg-white/5 p-2 rounded-lg border border-white/10 mt-1 shadow-inner">
        ${workerRunEvidenceMeta(item) || 'runtime/model 메타데이터 없음'}
      </div>
      <div class="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 rounded-xl border border-white/10 bg-black/10 px-3 py-3 text-[11px]">
        <span class="text-text-muted">요청 runtime/model</span>
        <span class="font-mono text-text-body">${item.requested_runtime ?? '-'} / ${item.requested_model ?? '-'}</span>
        <span class="text-text-muted">해석 runtime/model</span>
        <span class="font-mono text-text-body">${item.resolved_runtime ?? '-'} / ${item.resolved_model ?? '-'}</span>
        <span class="text-text-muted">trace / proof</span>
        <span class="font-mono text-text-body">${item.trace_evidence_status ?? '-'} / ${item.proof_evidence_status ?? '-'}</span>
        <span class="text-text-muted">tool surface</span>
        <span class="font-mono text-text-body">${item.tool_surface_status ?? '-'}${item.evidence_session_id ? ` · ${item.evidence_session_id}` : ''}</span>
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
        : html`<div class="flex flex-col gap-1.5 py-3 px-4 rounded-xl border border-green-500/20 bg-green-500/5 shadow-inner mt-1">
            <strong class="text-[11px] font-semibold uppercase tracking-widest text-green-300">검증 상태</strong>
            <span class="text-[12px] text-text-body leading-relaxed whitespace-pre-wrap">${item.trace_validated ? 'trace validated' : 'validation failure 없음'}</span>
          </div>`
      }
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
