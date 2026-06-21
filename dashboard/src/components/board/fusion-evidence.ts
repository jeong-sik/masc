import { html } from 'htm/preact'
import { RichContent } from '../common/rich-content'
import type { BoardPost } from '../../types/core'
import {
  extractFusionEvidence,
  type FusionJudgeView,
  type FusionPanelEntry,
} from '../../lib/fusion-meta'

function formatTokens(value: number | null | undefined): string | null {
  return value == null ? null : `${value.toLocaleString()} tok`
}

function statusClass(status: string): string {
  return status === 'answered' || status === 'synthesized'
    ? 'border-[var(--ok-30)] bg-[var(--ok-soft)] text-[var(--color-status-ok)]'
    : status === 'failed'
      ? 'border-[var(--bad-30)] bg-[var(--bad-15)] text-[var(--bad-light)]'
      : 'border-[var(--color-border-divider)] bg-[var(--color-bg-elevated)] text-[var(--color-fg-muted)]'
}

function metaChip(label: string, value: string | number | null | undefined) {
  if (value === null || value === undefined || value === '') return null
  return html`
    <span class="inline-flex items-center gap-1 rounded-[var(--r-1)] border border-[var(--color-border-divider)] bg-[var(--color-bg-elevated)] px-2 py-1 text-2xs text-[var(--color-fg-secondary)]">
      <span class="font-mono uppercase tracking-wide text-[var(--color-fg-muted)]">${label}</span>
      <span class="font-mono">${value}</span>
    </span>
  `
}

function PanelCard({ panel }: { panel: FusionPanelEntry }) {
  const tokenLabel = formatTokens(panel.outputTokens)
  return html`
    <article class="min-w-0 rounded-[var(--r-1)] border border-[var(--color-border-divider)] bg-[var(--color-bg-surface)] p-3" data-fusion-panel>
      <div class="mb-2 flex flex-wrap items-center gap-2">
        <span class="min-w-0 break-all font-mono text-2xs text-[var(--color-fg-secondary)]">${panel.model}</span>
        <span class=${`inline-flex rounded-[var(--r-0)] border px-1.5 py-0.5 text-3xs font-semibold uppercase tracking-wide ${statusClass(panel.status)}`}>${panel.status}</span>
        ${tokenLabel ? html`<span class="font-mono text-2xs text-[var(--color-fg-muted)]">${tokenLabel}</span>` : null}
      </div>
      ${panel.answer
        ? html`<div class="max-h-72 overflow-y-auto"><${RichContent} text=${panel.answer} previewLimit=${0} /></div>`
        : null}
      ${panel.reason
        ? html`<div class="text-xs leading-relaxed text-[var(--bad-light)]">${panel.reason}</div>`
        : null}
    </article>
  `
}

function JudgeBlock({ judge }: { judge: FusionJudgeView }) {
  const body = judge.synthesis ?? judge.resolvedAnswer ?? judge.error
  return html`
    <section class="rounded-[var(--r-1)] border border-[var(--color-brass-border)] bg-[var(--color-brass-soft)] p-3" data-fusion-judge>
      <div class="mb-2 flex flex-wrap items-center gap-2">
        <span class="font-semibold text-[var(--color-fg-secondary)]">심판 종합</span>
        <span class=${`inline-flex rounded-[var(--r-0)] border px-1.5 py-0.5 text-3xs font-semibold uppercase tracking-wide ${statusClass(judge.status)}`}>${judge.status}</span>
        ${judge.decision ? html`<span class="font-mono text-2xs text-[var(--color-fg-muted)]">${judge.decision}</span>` : null}
      </div>
      ${body
        ? html`<${RichContent} text=${body} previewLimit=${0} />`
        : html`<div class="text-xs text-[var(--color-fg-muted)]">심판 상세가 비어 있습니다.</div>`}
    </section>
  `
}

export function FusionBoardEvidence({
  post,
  class: className,
}: {
  post: Pick<BoardPost, 'meta'>
  class?: string
}) {
  const evidence = extractFusionEvidence(post.meta)
  if (!evidence) return null

  const answeredCount = evidence.panel.filter((panel) => panel.status === 'answered').length
  const rootClass = [
    'rounded-[var(--r-1)] border border-[var(--color-brass-border)] bg-[var(--color-bg-surface)] p-4',
    className,
  ].filter(Boolean).join(' ')
  return html`
    <section
      class=${rootClass}
      aria-label="Fusion 심의 증거"
      data-testid="fusion-board-evidence"
    >
      <div class="mb-3 flex flex-wrap items-start gap-2">
        <div class="min-w-0 flex-1">
          <h2 class="m-0 text-sm font-semibold text-[var(--color-fg-secondary)]">Fusion 심의 증거</h2>
          <div class="mt-1 text-2xs leading-relaxed text-[var(--color-fg-muted)]">패널 답변과 심판 종합은 board meta_json에서 렌더됩니다.</div>
        </div>
        ${metaChip('run', evidence.runId)}
        ${metaChip('panel', `${answeredCount}/${evidence.panel.length}`)}
        ${metaChip('out', formatTokens(evidence.usage?.outputTokens))}
      </div>

      ${evidence.question
        ? html`
          <div class="mb-3 rounded-[var(--r-1)] border border-[var(--color-border-divider)] bg-[var(--color-bg-elevated)] p-3" data-fusion-question>
            <div class="mb-1 font-mono text-3xs uppercase tracking-wide text-[var(--color-fg-muted)]">question</div>
            <div class="text-xs leading-relaxed text-[var(--color-fg-primary)]">${evidence.question}</div>
          </div>
        `
        : null}

      ${evidence.judge ? html`<${JudgeBlock} judge=${evidence.judge} />` : null}

      <div class="mt-3 grid gap-2" data-fusion-panel-list>
        ${evidence.panel.map((panel, index) => html`<${PanelCard} key=${`${panel.model}-${index}`} panel=${panel} />`)}
      </div>
    </section>
  `
}
