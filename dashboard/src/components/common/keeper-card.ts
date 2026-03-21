import { html } from 'htm/preact'
import { MitosisRing } from './mitosis-ring'
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
  if (typeof value !== 'number' || Number.isNaN(value)) return '—'
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
      ? `mission-activity-card ${toneClass}`
      : 'keeper-canonical-card'
  const buttonClass =
    variant === 'mission'
      ? 'mission-card-select'
      : `monitor-row ${toneClass}${model.stateClass ? ` state-${model.stateClass}` : ''}`

  return html`
    <article class=${wrapperClass}>
      <button class=${buttonClass} data-testid=${testId} onClick=${onClick}>
        <div class=${variant === 'mission' ? 'mission-activity-head' : 'monitor-row-header'}>
          <div class=${variant === 'mission' ? 'mission-activity-title' : 'monitor-row-title'}>
            <span class="agent-emoji">${model.emoji ?? ''}</span>
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
                ${model.stateLabel ? html`<span class="monitor-pill ${toneClass}">${model.stateLabel}</span>` : null}
              `
            : html`<span class="command-chip ${toneClass}">${model.statusLabel}</span>`}
        </div>

        <div class=${variant === 'mission' ? 'mission-activity-meta' : 'monitor-meta'}>
          ${model.lastActivityAt
            ? html`<span>최근 활동 <${TimeAgo} timestamp=${model.lastActivityAt} /></span>`
            : html`<span>${model.lastActivityFallback ?? '최근 활동 없음'}</span>`}
          ${model.relatedSessionId ? html`<span>세션 · ${model.relatedSessionId}</span>` : null}
          ${model.continuity ? html`<span>${model.continuity}</span>` : null}
          ${model.lifecycle ? html`<span>생애주기 ${model.lifecycle}</span>` : null}
          <span>컨텍스트 ${formatContext(model.contextRatio)}</span>
        </div>

        <div class=${variant === 'mission' ? 'mission-activity-focus' : 'monitor-focus'}>
          ${variant === 'mission'
            ? html`
                <span>무엇을</span>
                <strong>${model.focus}</strong>
              `
            : html`${model.focus}`}
        </div>

        ${model.summary
          ? html`<div class=${variant === 'mission' ? 'mission-inline-note' : 'monitor-footnote'}>${model.summary}</div>`
          : null}
      </button>

      ${hasDetailDisclosure
        ? html`
            <details class="mission-card-disclosure compact">
              <summary>${model.disclosureLabel ?? '세부 정보'}</summary>
              <div class="mission-activity-foot">
                ${model.recentEvent ? html`<span>최근 일 · ${model.recentEvent}</span>` : null}
                ${model.routeSummary ? html`<span>route · ${model.routeSummary}</span>` : null}
                ${model.auditSource ? html`<span>audit · ${model.auditSource}</span>` : null}
                ${model.auditAt ? html`<span><${TimeAgo} timestamp=${model.auditAt} /></span>` : null}
              </div>
              ${model.recentInput || model.recentOutput
                ? html`
                    <div class="mission-io-stack">
                      <div class="mission-io-item">
                        <span>최근 입력</span>
                        <strong>${model.recentInput ?? '표시 가능한 최근 입력이 없습니다'}</strong>
                      </div>
                      <div class="mission-io-item">
                        <span>최근 응답</span>
                        <strong>${model.recentOutput ?? '표시 가능한 최근 응답이 없습니다'}</strong>
                      </div>
                    </div>
                  `
                : null}
              ${(model.recentTools?.length ?? 0) > 0 || (model.allowedTools?.length ?? 0) > 0
                ? html`
                    <div class="mission-activity-foot">
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
