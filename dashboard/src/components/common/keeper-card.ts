import { html } from 'htm/preact'
import { StatusChip } from './status-chip'
import { MitosisRing } from './mitosis-ring'
import { StatCell } from './stat-cell'
import { StatusBadge } from './status-badge'
import { TimeAgo } from './time-ago'
import { PipelineStageBadge } from '../keeper-pipeline-stage'
import type { PipelineStage } from '../../types'

export type CanonicalKeeperCardModel = {
  name: string
  koreanName?: string | null
  runtimeLabel?: string | null
  emoji?: string | null
  tone?: string
  statusRaw?: string | null
  statusLabel: string
  stateClass?: string | null
  stateLabel?: string | null
  pipelineStage?: PipelineStage | null
  contextRatio?: number | null
  note?: string | null
  focus: string
  lastActivityAt?: string | null
  lastActivityFallback?: string | null
  relatedSessionId?: string | null
  continuity?: string | null
  lifecycle?: string | null
  summary?: string | null
  recentEvent?: string | null
  recentInput?: string | null
  recentOutput?: string | null
  recentTools?: string[]
  allowedTools?: string[]
  routeSummary?: string | null
  auditSource?: string | null
  auditAt?: string | null
  disclosureLabel?: string
}

type KeeperCardProps = {
  model: CanonicalKeeperCardModel
  onClick: () => void
  variant: 'mission' | 'execution'
  testId?: string
}

function formatContext(value?: number | null): string {
  if (typeof value !== 'number' || Number.isNaN(value)) return 'N/A'
  return `${Math.round(value * 100)}%`
}

function renderToolSummary(tools: string[] | undefined, empty = '없음'): string {
  if (!tools || tools.length === 0) return empty
  return tools.slice(0, 4).join(', ')
}

export function KeeperCard({ model, onClick, variant, testId }: KeeperCardProps) {
  const hasDetailDisclosure =
    Boolean(model.recentEvent)
    || Boolean(model.recentInput)
    || Boolean(model.recentOutput)
    || Boolean(model.routeSummary)
    || Boolean(model.auditSource)
    || Boolean(model.auditAt)
    || (model.recentTools?.length ?? 0) > 0
    || (model.allowedTools?.length ?? 0) > 0

  const toneClass = model.tone ?? ''
  const wrapperClass =
    variant === 'mission'
      ? `w-full p-4 rounded-xl border border-[var(--white-8)] bg-[var(--white-4)] grid gap-3 text-inherit text-left cursor-pointer ${toneClass}`
      : 'keeper-canonical-card'
  const buttonClass =
    variant === 'mission'
      ? 'w-full p-0 border-0 bg-transparent text-inherit grid gap-3 text-left cursor-pointer'
      : `monitor-row p-4 ${toneClass}${model.stateClass ? ` state-${model.stateClass}` : ''}${model.stateClass === 'offline' ? ' opacity-35 border-[rgba(85,85,85,0.15)] bg-[rgba(0,0,0,0.08)] hover:opacity-55' : ''}`

  return html`
    <article class=${wrapperClass}>
      <button class=${buttonClass} data-testid=${testId} onClick=${onClick}>
        <div class=${variant === 'mission' ? 'flex justify-between gap-3 items-start' : 'monitor-row-header'}>
          <div class=${variant === 'mission' ? 'flex gap-3 items-start' : 'min-w-0'}>
            <span class="agent-emoji ${model.stateClass === 'offline' ? 'grayscale' : ''}">${model.emoji ?? ''}</span>
            <div>
              <div class=${variant === 'mission' ? '' : 'monitor-name-line'}>
                <strong class=${variant === 'mission' ? '' : 'monitor-title'}>${model.name}</strong>
                ${model.koreanName ? html`<span class=${variant === 'mission' ? '' : 'monitor-sub'}>${model.koreanName}</span>` : null}
              </div>
              ${model.runtimeLabel ? html`<div class=${variant === 'mission' ? '' : 'monitor-sub'}>${model.runtimeLabel}</div>` : null}
              ${model.note ? html`<div class=${variant === 'mission' ? '' : 'monitor-note'}>${model.note}</div>` : null}
            </div>
          </div>
          ${variant === 'execution'
            ? html`
                <${MitosisRing} ratio=${model.contextRatio ?? 0} size=${34} stroke=${4} />
                <${StatusBadge} status=${model.statusRaw ?? 'unknown'} />
                ${model.pipelineStage ? html`<${PipelineStageBadge} stage=${model.pipelineStage} />` : null}
                ${model.stateLabel ? html`<span class="monitor-pill ${toneClass} inline-flex items-center rounded-full px-2 py-[3px] text-[length:var(--fs-xs)] uppercase tracking-[0.06em]">${model.stateLabel}</span>` : null}
              `
            : html`<${StatusChip} label=${model.statusLabel} tone=${toneClass} />`}
        </div>

        <div class=${variant === 'mission' ? 'flex flex-wrap gap-3 text-[rgba(255,255,255,0.68)] text-[length:var(--fs-sm)] leading-[1.45]' : 'monitor-meta'}>
          ${model.lastActivityAt
            ? html`<span>최근 활동 <${TimeAgo} timestamp=${model.lastActivityAt} /></span>`
            : html`<span>${model.lastActivityFallback ?? '최근 활동 없음'}</span>`}
          ${model.relatedSessionId ? html`<span>세션 · ${model.relatedSessionId}</span>` : null}
          ${model.continuity ? html`<span>${model.continuity}</span>` : null}
          ${model.lifecycle ? html`<span>생애주기 ${model.lifecycle}</span>` : null}
          <span>컨텍스트 ${formatContext(model.contextRatio)}</span>
        </div>

        <div class=${variant === 'mission' ? 'grid gap-1.5' : 'monitor-focus'}>
          ${variant === 'mission'
            ? html`
                <span>무엇을</span>
                <strong>${model.focus}</strong>
              `
            : html`${model.focus}`}
        </div>

        ${model.summary
          ? html`<div class=${variant === 'mission' ? 'grid gap-1.5' : 'monitor-footnote'}>${model.summary}</div>`
          : null}
      </button>

      ${hasDetailDisclosure
        ? html`
            <details class="pt-3 border-t border-[var(--white-6)] mt-4">
              <summary>${model.disclosureLabel ?? '세부 정보'}</summary>
              <div class="flex flex-wrap gap-3 text-[rgba(255,255,255,0.68)] text-[length:var(--fs-sm)] leading-[1.45]">
                ${model.recentEvent ? html`<span>최근 일 · ${model.recentEvent}</span>` : null}
                ${model.routeSummary ? html`<span>route · ${model.routeSummary}</span>` : null}
                ${model.auditSource ? html`<span>audit · ${model.auditSource}</span>` : null}
                ${model.auditAt ? html`<span><${TimeAgo} timestamp=${model.auditAt} /></span>` : null}
              </div>
              ${model.recentInput || model.recentOutput
                ? html`
                    <div class="grid grid-cols-2 gap-3">
                      <${StatCell} label="최근 입력" value=${model.recentInput ?? '표시 가능한 최근 입력이 없습니다'} bg="white-3" />
                      <${StatCell} label="최근 응답" value=${model.recentOutput ?? '표시 가능한 최근 응답이 없습니다'} bg="white-3" />
                    </div>
                  `
                : null}
              ${(model.recentTools?.length ?? 0) > 0 || (model.allowedTools?.length ?? 0) > 0
                ? html`
                    <div class="flex flex-wrap gap-3 text-[rgba(255,255,255,0.68)] text-[length:var(--fs-sm)] leading-[1.45]">
                      <span>최근 도구 · ${renderToolSummary(model.recentTools)}</span>
                      <span>허용 도구 · ${renderToolSummary(model.allowedTools)}</span>
                    </div>
                  `
                : null}
            </details>
          `
        : null}
    </article>
  `
}
