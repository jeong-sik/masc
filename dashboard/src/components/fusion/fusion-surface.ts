import { html } from 'htm/preact'
import { useMemo } from 'preact/hooks'
import type { BoardPost } from '../../types'
import { navigate, replaceRoute, route } from '../../router'
import {
  fusionBoardLoading,
  fusionBoardPosts,
  fusionRuns,
  fusionRunsLoading,
  refreshFusionBoard,
  refreshFusionRuns,
} from '../../store'
import { TimeAgo } from '../common/time-ago'
import { ringFocusClasses } from '../common/ring'
import { AgentAvatar } from '../overview/agent-avatar'
import { FusionRunsPanel } from './fusion-runs-panel'
import { asRecord, asString, asStringArray } from '../common/normalize'
import {
  firstString,
  firstNumber,
  normalizeFusionPanel,
  normalizeFusionUsage,
  type FusionPanelEntry,
} from '../../lib/fusion-meta'

type FusionRunStatus = 'complete' | 'failed' | 'running'
type FusionTone = 'ok' | 'warn' | 'bad' | 'volt' | 'muted'

const FAILED_PANEL_STATUSES: readonly string[] = ['failed', 'error']

function isPanelFailure(status: string): status is 'failed' | 'error' {
  return FAILED_PANEL_STATUSES.includes(status)
}

const FUSION_BOARD_SOURCE = 'fusion'

interface FusionModelClaim {
  text: string
  models: string[]
}

interface FusionContradiction {
  topic: string
  positions: Array<{
    model: string
    stance: string
  }>
}

interface FusionCoverageGap {
  topic: string
  addressedBy: string[]
  missing: string
}

interface FusionUniqueInsight {
  text: string
  model: string | null
}

interface FusionRecommendation {
  action: string | null
  rationale: string | null
}

interface FusionJudge {
  status: string | null
  decision: string | null
  synthesis: string | null
  resolvedAnswer: string | null
  error: string | null
  consensus: FusionModelClaim[]
  contradictions: FusionContradiction[]
  partialCoverage: FusionCoverageGap[]
  uniqueInsights: FusionUniqueInsight[]
  blindSpots: string[]
  missingInputs: string[]
  recommendation: FusionRecommendation | null
}

interface FusionUsage {
  inputTokens: number | null
  outputTokens: number | null
  costUsd: number | null
}

interface FusionRunView {
  runId: string
  boardPostId: string
  keeperName: string
  title: string
  question: string
  status: FusionRunStatus
  tone: FusionTone
  panel: FusionPanelEntry[]
  judge: FusionJudge
  usage: FusionUsage
  createdAt: string
  updatedAt: string
}

function normalizeModelClaims(value: unknown): FusionModelClaim[] {
  if (!Array.isArray(value)) return []
  return value.flatMap(item => {
    const direct = asString(item)
    if (direct) return [{ text: direct, models: [] }]

    const claim = asRecord(item)
    if (!claim) return []

    const text = firstString(claim, ['text', 'claim', 'summary', 'point'])
    if (!text) return []

    return [{
      text,
      models: asStringArray(claim.models),
    }]
  })
}

function normalizeContradictionPositions(value: unknown): FusionContradiction['positions'] {
  if (!Array.isArray(value)) return []
  return value.flatMap((item, index) => {
    if (Array.isArray(item)) {
      const stance = asString(item[1])
      if (!stance) return []
      return [{
        model: asString(item[0]) ?? `model-${index + 1}`,
        stance,
      }]
    }

    const position = asRecord(item)
    if (!position) return []

    const stance = firstString(position, ['stance', 'position', 'text'])
    if (!stance) return []

    return [{
      model: firstString(position, ['model', 'name', 'provider']) ?? `model-${index + 1}`,
      stance,
    }]
  })
}

function normalizeContradictions(value: unknown): FusionContradiction[] {
  if (!Array.isArray(value)) return []
  return value.flatMap((item, index) => {
    const contradiction = asRecord(item)
    if (!contradiction) return []

    const positions = normalizeContradictionPositions(contradiction.positions)
    if (positions.length === 0) return []

    return [{
      topic: firstString(contradiction, ['topic', 'text', 'claim']) ?? `contradiction-${index + 1}`,
      positions,
    }]
  })
}

function normalizeCoverageGaps(value: unknown): FusionCoverageGap[] {
  if (!Array.isArray(value)) return []
  return value.flatMap((item, index) => {
    const gap = asRecord(item)
    if (!gap) return []

    const missing = firstString(gap, ['missing', 'gap', 'note'])
    if (!missing) return []

    return [{
      topic: firstString(gap, ['topic', 'area', 'claim']) ?? `coverage-${index + 1}`,
      addressedBy: asStringArray(gap.addressed_by ?? gap.addressedBy),
      missing,
    }]
  })
}

function normalizeUniqueInsights(value: unknown): FusionUniqueInsight[] {
  if (!Array.isArray(value)) return []
  return value.flatMap(item => {
    const direct = asString(item)
    if (direct) return [{ text: direct, model: null }]

    const insight = asRecord(item)
    if (!insight) return []

    const text = firstString(insight, ['text', 'insight', 'summary'])
    if (!text) return []

    return [{
      text,
      model: firstString(insight, ['model', 'name', 'provider']),
    }]
  })
}

function normalizeRecommendation(value: unknown): FusionRecommendation | null {
  const recommendation = asRecord(value)
  if (!recommendation) return null

  const action = firstString(recommendation, ['action', 'title', 'label'])
  const rationale = firstString(recommendation, ['rationale', 'reason', 'summary'])
  if (!action && !rationale) return null

  return { action, rationale }
}

function normalizeJudge(value: unknown): FusionJudge {
  const judge = asRecord(value) ?? {}
  return {
    status: firstString(judge, ['status']),
    decision: firstString(judge, ['decision', 'verdict']),
    synthesis: firstString(judge, ['synthesis', 'rationale', 'summary']),
    resolvedAnswer: firstString(judge, ['resolved_answer', 'resolvedAnswer', 'answer']),
    error: firstString(judge, ['error', 'reason', 'error_text']),
    consensus: normalizeModelClaims(judge.consensus),
    contradictions: normalizeContradictions(judge.contradictions),
    partialCoverage: normalizeCoverageGaps(judge.partial_coverage ?? judge.partialCoverage),
    uniqueInsights: normalizeUniqueInsights(judge.unique_insights ?? judge.uniqueInsights),
    blindSpots: asStringArray(judge.blind_spots ?? judge.blindSpots),
    missingInputs: asStringArray(judge.missing ?? judge.missing_inputs ?? judge.missingInputs),
    recommendation: normalizeRecommendation(judge.recommend ?? judge.recommendation),
  }
}

function normalizeUsage(meta: Record<string, unknown>, panel: FusionPanelEntry[]): FusionUsage {
  const base = normalizeFusionUsage(meta, panel)
  return {
    inputTokens: base.inputTokens ?? null,
    outputTokens: base.outputTokens ?? null,
    costUsd: firstNumber(meta, ['cost_usd', 'costUsd', 'observed_cost_usd']),
  }
}

function statusFor(judge: FusionJudge, panel: FusionPanelEntry[]): FusionRunStatus {
  const status = judge.status?.toLowerCase() ?? ''
  if (status.includes('fail')) return 'failed'
  if (judge.error) return 'failed'
  if (judge.resolvedAnswer || judge.synthesis || judge.decision || status.includes('synth')) return 'complete'
  if (panel.length > 0 && panel.every(entry => isPanelFailure(entry.status))) return 'failed'
  return 'running'
}

function toneFor(status: FusionRunStatus, decision: string | null): FusionTone {
  if (status === 'failed') return 'bad'
  const lower = decision?.toLowerCase() ?? ''
  if (lower.includes('answer')) return 'ok'
  if (lower.includes('recommend')) return 'volt'
  if (lower.includes('insufficient') || lower.includes('uncertain')) return 'warn'
  return status === 'running' ? 'muted' : 'ok'
}

function keeperNameFor(post: BoardPost): string {
  return post.author_identity?.display_name
    || post.author_identity?.id
    || post.author
    || 'system'
}

function fusionMeta(post: BoardPost): Record<string, unknown> | null {
  const meta = asRecord(post.meta)
  if (!meta) return null
  if (asString(meta.source) === FUSION_BOARD_SOURCE) return meta

  const nested = asRecord(meta.fusion_deliberation)
  if (nested) return { ...nested, source: FUSION_BOARD_SOURCE }

  return null
}

function fusionRunFromPost(post: BoardPost): FusionRunView | null {
  const meta = fusionMeta(post)
  if (!meta) return null

  const panel = normalizeFusionPanel(meta.panel)
  const judge = normalizeJudge(meta.judge)
  const usage = normalizeUsage(meta, panel)
  const runId = firstString(meta, ['run_id', 'runId', 'id']) ?? post.id
  const question = firstString(meta, ['question', 'prompt']) ?? post.body ?? post.content ?? post.title
  const status = statusFor(judge, panel)
  const tone = toneFor(status, judge.decision)

  return {
    runId,
    boardPostId: post.id,
    keeperName: keeperNameFor(post),
    title: post.title || `Fusion run ${runId}`,
    question,
    status,
    tone,
    panel,
    judge,
    usage,
    createdAt: post.created_at,
    updatedAt: post.updated_at || post.created_at,
  }
}

function timeValue(iso: string): number {
  const parsed = Date.parse(iso)
  return Number.isFinite(parsed) ? parsed : 0
}

function buildFusionRuns(posts: readonly BoardPost[]): FusionRunView[] {
  return posts
    .flatMap(post => {
      const run = fusionRunFromPost(post)
      return run ? [run] : []
    })
    .sort((a, b) => timeValue(b.updatedAt) - timeValue(a.updatedAt))
}

function formatTokens(value: number | null | undefined): string {
  if (value == null) return 'n/a'
  return new Intl.NumberFormat().format(value)
}

function formatCost(value: number | null): string {
  if (value === null) return 'n/a'
  return `$${value.toFixed(4)}`
}

function statusLabel(status: FusionRunStatus): string {
  switch (status) {
    case 'complete':
      return 'complete'
    case 'failed':
      return 'failed'
    case 'running':
      return 'running'
  }
}

function statusDotClass(status: FusionRunStatus): 'done' | 'deny' | 'run' {
  if (status === 'complete') return 'done'
  if (status === 'failed') return 'deny'
  return 'run'
}

function compactText(value: string, max = 180): string {
  const normalized = value.replace(/\s+/g, ' ').trim()
  if (normalized.length <= max) return normalized
  return `${normalized.slice(0, max - 1)}...`
}

function FusionMetric({ label, value, tone = 'muted' }: { label: string; value: string | number; tone?: FusionTone }) {
  return html`
    <div class=${`fus-kpi tone-${tone}`}>
      <div class="fus-kpi-k">${label}</div>
      <div class="fus-kpi-v">${value}</div>
    </div>
  `
}

function FusionStatusGlyph({ status }: { status: FusionRunStatus }) {
  return html`<span class=${`fus-rdot ${statusDotClass(status)}`} aria-hidden="true"></span>`
}

function FusionPipelineStrip({ run }: { run: FusionRunView }) {
  const panelFailures = run.panel.filter(entry => isPanelFailure(entry.status)).length
  const gateClass = run.status === 'failed' && run.panel.length === 0 ? 'deny' : 'gate'
  const panelLabel = run.panel.length > 0 ? `panel ×${run.panel.length}` : 'panel pending'
  const judgeLabel = run.judge.decision ?? run.judge.status ?? (run.status === 'running' ? 'judge pending' : 'judge')

  return html`
    <section class="fus-pipe" data-testid="fusion-pipe" aria-label="Fusion run pipeline">
      <span class="fus-pipe-node kp">
        <${FusionStatusGlyph} status=${run.status} />
        keeper turn
      </span>
      <span class="fus-pipe-arr" aria-hidden="true">→</span>
      <span class=${`fus-pipe-node ${gateClass}`}>gate</span>
      <span class="fus-pipe-arr" aria-hidden="true">→</span>
      <span class=${`fus-pipe-node panel ${panelFailures > 0 ? 'warn' : ''}`}>
        ${panelLabel}${panelFailures > 0 ? ` · fail ${panelFailures}` : ''}
      </span>
      <span class="fus-pipe-arr" aria-hidden="true">→</span>
      <span class=${`fus-pipe-node judge ${run.status === 'failed' ? 'deny' : ''}`}>${judgeLabel}</span>
      <span class="fus-pipe-arr" aria-hidden="true">→</span>
      <span class="fus-pipe-node sink">board evidence</span>
    </section>
  `
}

function FusionPanelCard({ entry }: { entry: FusionPanelEntry }) {
  const failed = isPanelFailure(entry.status)
  const body = entry.answer ?? entry.reason ?? 'No panel output captured.'
  return html`
    <article class=${`fus-panel-card ${failed ? 'failed' : 'answered'}`}>
      <div class="fus-panel-head">
        <span class="fus-panel-model">${entry.model}</span>
        <span class=${`fus-mini-status ${failed ? 'bad' : 'ok'}`}>${entry.status}</span>
      </div>
      <p class="fus-panel-body">${compactText(body, 360)}</p>
      <div class="fus-panel-foot">
        <span>in ${formatTokens(entry.inputTokens)}</span>
        <span>out ${formatTokens(entry.outputTokens)}</span>
      </div>
    </article>
  `
}

function hasStructuredJudgeEvidence(judge: FusionJudge): boolean {
  return judge.consensus.length > 0
    || judge.contradictions.length > 0
    || judge.partialCoverage.length > 0
    || judge.uniqueInsights.length > 0
    || judge.blindSpots.length > 0
    || judge.missingInputs.length > 0
    || judge.recommendation !== null
}

function FusionModelChips({ models }: { models: string[] }) {
  if (models.length === 0) return null
  return html`
    <span class="fus-model-chips">
      ${models.map(model => html`<span class="fus-model-chip" key=${model}>${model}</span>`)}
    </span>
  `
}

function FusionJudgeEvidence({ judge }: { judge: FusionJudge }) {
  if (!hasStructuredJudgeEvidence(judge)) return null

  return html`
    <div class="fus-judge-evidence" data-testid="fusion-judge-evidence">
      <div class="fus-judge-evidence-head">
        <span>Structured judge evidence</span>
        <span>
          ${judge.consensus.length} consensus · ${judge.contradictions.length} contradictions ·
          ${judge.partialCoverage.length} coverage
        </span>
      </div>

      ${judge.consensus.length > 0
        ? html`
            <div class="fus-jgroup">
              <h4>Consensus</h4>
              <div class="fus-jrows">
                ${judge.consensus.map((claim, index) => html`
                  <div class="fus-jrow" key=${`consensus-${index}`}>
                    <p>${claim.text}</p>
                    <${FusionModelChips} models=${claim.models} />
                  </div>
                `)}
              </div>
            </div>
          `
        : null}

      ${judge.contradictions.length > 0
        ? html`
            <div class="fus-jgroup">
              <h4>Contradictions</h4>
              <div class="fus-jrows">
                ${judge.contradictions.map((contradiction, index) => html`
                  <div class="fus-jrow" key=${`contradiction-${index}`}>
                    <strong>${contradiction.topic}</strong>
                    ${contradiction.positions.map(position => html`
                      <span class="fus-position" key=${`${contradiction.topic}:${position.model}`}>
                        <span>${position.model}</span>
                        <span>${position.stance}</span>
                      </span>
                    `)}
                  </div>
                `)}
              </div>
            </div>
          `
        : null}

      ${judge.partialCoverage.length > 0
        ? html`
            <div class="fus-jgroup">
              <h4>Partial Coverage</h4>
              <div class="fus-jrows">
                ${judge.partialCoverage.map((gap, index) => html`
                  <div class="fus-jrow" key=${`coverage-${index}`}>
                    <strong>${gap.topic}</strong>
                    <${FusionModelChips} models=${gap.addressedBy} />
                    <p><span class="fus-muted-key">missing</span>${gap.missing}</p>
                  </div>
                `)}
              </div>
            </div>
          `
        : null}

      ${judge.uniqueInsights.length > 0
        ? html`
            <div class="fus-jgroup">
              <h4>Unique Insights</h4>
              <div class="fus-jrows">
                ${judge.uniqueInsights.map((insight, index) => html`
                  <div class="fus-jrow" key=${`insight-${index}`}>
                    <p>${insight.text}</p>
                    ${insight.model ? html`<${FusionModelChips} models=${[insight.model]} />` : null}
                  </div>
                `)}
              </div>
            </div>
          `
        : null}

      ${judge.blindSpots.length > 0 || judge.missingInputs.length > 0
        ? html`
            <div class="fus-jgroup fus-jgroup-split">
              ${judge.blindSpots.length > 0
                ? html`
                    <div>
                      <h4>Blind Spots</h4>
                      <ul>${judge.blindSpots.map(item => html`<li key=${item}>${item}</li>`)}</ul>
                    </div>
                  `
                : null}
              ${judge.missingInputs.length > 0
                ? html`
                    <div>
                      <h4>Missing Inputs</h4>
                      <ul>${judge.missingInputs.map(item => html`<li key=${item}>${item}</li>`)}</ul>
                    </div>
                  `
                : null}
            </div>
          `
        : null}

      ${judge.recommendation
        ? html`
            <div class="fus-jgroup">
              <h4>Recommendation</h4>
              <div class="fus-jrow">
                ${judge.recommendation.action ? html`<strong>${judge.recommendation.action}</strong>` : null}
                ${judge.recommendation.rationale ? html`<p>${judge.recommendation.rationale}</p>` : null}
              </div>
            </div>
          `
        : null}
    </div>
  `
}

function FusionRunRow({ run, active }: { run: FusionRunView; active: boolean }) {
  return html`
    <button
      type="button"
      class=${`fus-run-row ${active ? 'active' : ''} ${ringFocusClasses()}`}
      aria-current=${active ? 'true' : undefined}
      onClick=${() => replaceRoute('fusion', { run_id: run.runId })}
    >
      <span class="fus-row-top">
        <span class="fus-run-mark">
          <${FusionStatusGlyph} status=${run.status} />
          <span class="fus-run-id">${run.runId}</span>
        </span>
        <span class=${`fus-status tone-${run.tone}`}>${statusLabel(run.status)}</span>
      </span>
      <span class="fus-row-question">${compactText(run.question, 110)}</span>
      <span class="fus-row-meta">
        <span>${run.keeperName}</span>
        <${TimeAgo} timestamp=${run.updatedAt} />
      </span>
    </button>
  `
}

function FusionRunDetail({ run }: { run: FusionRunView }) {
  const answered = run.panel.filter(entry => !isPanelFailure(entry.status)).length
  const failed = run.panel.length - answered
  const synthesis = run.judge.synthesis ?? run.judge.error ?? 'No judge synthesis captured.'
  const resolved = run.judge.resolvedAnswer ?? 'No resolved answer captured.'

  return html`
    <article class="fus-detail" data-testid="fusion-detail">
      <header class="fus-detail-head">
        <div class="fus-detail-title">
          <div class="fus-detail-meta">
            <${FusionStatusGlyph} status=${run.status} />
            <span class=${`fus-status tone-${run.tone}`}>${statusLabel(run.status)}</span>
            <span class="fus-run-id">${run.runId}</span>
            <${TimeAgo} timestamp=${run.updatedAt} mode="both" />
          </div>
          <h2>${run.title}</h2>
        </div>
        <div class="fus-actions">
          <button
            type="button"
            class=${`fus-action ${ringFocusClasses()}`}
            onClick=${() => navigate('keepers', { keeper: run.keeperName })}
          >Open keeper</button>
          <button
            type="button"
            class=${`fus-action primary ${ringFocusClasses()}`}
            onClick=${() => navigate('board', { post: run.boardPostId })}
          >Open board post</button>
        </div>
      </header>

      <${FusionPipelineStrip} run=${run} />

      <section class="fus-question">
        <div class="fus-label">Prompt</div>
        <p>${run.question}</p>
      </section>

      <section class="fus-kpis" aria-label="Fusion run metrics">
        <${FusionMetric} label="panel" value=${`${answered}/${run.panel.length}`} tone=${failed > 0 ? 'warn' : 'ok'} />
        <${FusionMetric} label="input tokens" value=${formatTokens(run.usage.inputTokens)} />
        <${FusionMetric} label="output tokens" value=${formatTokens(run.usage.outputTokens)} tone="volt" />
        <${FusionMetric} label="cost" value=${formatCost(run.usage.costUsd)} />
      </section>

      <section class="fus-section">
        <div class="fus-section-head">
          <h3>Panel</h3>
          <span>${run.panel.length} models</span>
        </div>
        ${run.panel.length === 0
          ? html`<div class="fus-empty-inline">No panel entries captured for this run.</div>`
          : html`<div class="fus-panel-grid">${run.panel.map(entry => html`<${FusionPanelCard} key=${entry.model} entry=${entry} />`)}</div>`}
      </section>

      <section class="fus-judge">
        <div class="fus-section-head">
          <h3>Judge</h3>
          <span>${run.judge.decision ?? run.judge.status ?? 'n/a'}</span>
        </div>
        <pre class="fus-synthesis">${synthesis}</pre>
        <${FusionJudgeEvidence} judge=${run.judge} />
      </section>

      <section class="fus-resolved">
        <div class="fus-label">Resolved answer</div>
        <p>${resolved}</p>
      </section>

      <section class="fus-sink">
        <div>
          <div class="fus-label">Sink</div>
          <p>board evidence · post ${run.boardPostId}</p>
        </div>
        <${AgentAvatar} name=${run.keeperName} size="sm" />
      </section>
    </article>
  `
}

export function FusionSurface() {
  const posts = fusionBoardPosts.value
  const runs = useMemo(() => buildFusionRuns(posts), [posts])
  const registryRuns = fusionRuns.value
  const selectedRunId = route.value.params.run_id ?? route.value.params.run
  const selected = runs.find(run => run.runId === selectedRunId) ?? runs[0] ?? null
  const registryRunning = registryRuns.filter(run => run.status === 'running').length
  const registryFailed = registryRuns.filter(run => run.status === 'failed').length

  return html`
    <main class="ov ss-surface bg-surface-page text-text-primary v2-fusion-surface" data-testid="fusion-surface">
      <div class="ov-scroll fus-scroll">
        <header class="ov-head fus-head">
          <div>
            <h1>Fusion</h1>
            <p class="ov-sub">
              Panel deliberations, judge synthesis, and board sink evidence from masc_fusion.
            </p>
          </div>
          <button
            type="button"
            class=${`fus-refresh ${ringFocusClasses()}`}
            onClick=${() => { void refreshFusionBoard(); void refreshFusionRuns() }}
            disabled=${fusionBoardLoading.value || fusionRunsLoading.value}
          >${fusionBoardLoading.value || fusionRunsLoading.value ? 'Refreshing...' : 'Refresh'}</button>
        </header>

        <${FusionRunsPanel} />

        <section class="fus-top-kpis" aria-label="Fusion overview">
          <${FusionMetric} label="board runs" value=${runs.length} tone=${runs.length ? 'ok' : 'muted'} />
          <${FusionMetric}
            label="registry"
            value=${registryRuns.length}
            tone=${registryRunning ? 'warn' : registryRuns.length ? 'ok' : 'muted'}
          />
          <${FusionMetric} label="running" value=${registryRunning} tone=${registryRunning ? 'warn' : 'muted'} />
          <${FusionMetric} label="failed" value=${registryFailed} tone=${registryFailed ? 'bad' : 'muted'} />
        </section>

        ${runs.length === 0
          ? html`
              <section class="fus-empty" data-testid="fusion-empty">
                <div class="fus-empty-mark">F</div>
                <h2>No board-sink fusion posts yet</h2>
                <p>
                  Registry status is shown above from <code>/api/v1/dashboard/fusion-runs</code>;
                  detailed panel and judge review appears after the fusion sink writes a board post
                  with <code>meta.source = "fusion"</code>.
                </p>
              </section>
            `
          : html`
              <div class="fus-layout">
                <aside class="fus-list" aria-label="Fusion runs">
                  <div class="fus-list-head">
                    <span>Runs</span>
                    <span>${runs.length}</span>
                  </div>
                  <div class="fus-run-scroll">
                    ${runs.map(run => html`
                      <${FusionRunRow}
                        key=${run.runId}
                        run=${run}
                        active=${selected?.runId === run.runId}
                      />
                    `)}
                  </div>
                </aside>
                ${selected ? html`<${FusionRunDetail} run=${selected} />` : null}
              </div>
            `}
      </div>
    </main>
  `
}
