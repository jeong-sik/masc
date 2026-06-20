import { html } from 'htm/preact'
import { useMemo } from 'preact/hooks'
import type { BoardPost } from '../../types'
import { navigate, replaceRoute, route } from '../../router'
import { boardLoading, boardPosts, fusionRunsLoading, refreshBoard, refreshFusionRuns } from '../../store'
import { TimeAgo } from '../common/time-ago'
import { ringFocusClasses } from '../common/ring'
import { AgentAvatar } from '../overview/agent-avatar'
import { FusionRunsPanel } from './fusion-runs-panel'

type FusionRunStatus = 'complete' | 'failed' | 'running'
type FusionTone = 'ok' | 'warn' | 'bad' | 'volt' | 'muted'

const FUSION_BOARD_SOURCE = 'fusion'

interface FusionPanelEntry {
  model: string
  status: string
  answer: string | null
  reason: string | null
  inputTokens: number | null
  outputTokens: number | null
}

interface FusionJudge {
  status: string | null
  decision: string | null
  synthesis: string | null
  resolvedAnswer: string | null
  error: string | null
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

function asRecord(value: unknown): Record<string, unknown> | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null
  return value as Record<string, unknown>
}

function asString(value: unknown): string | null {
  if (typeof value !== 'string') return null
  const trimmed = value.trim()
  return trimmed.length > 0 ? trimmed : null
}

function asNumber(value: unknown): number | null {
  if (typeof value === 'number') return Number.isFinite(value) ? value : null
  if (typeof value === 'string') {
    const parsed = Number(value)
    return Number.isFinite(parsed) ? parsed : null
  }
  return null
}

function firstString(source: Record<string, unknown>, keys: string[]): string | null {
  for (const key of keys) {
    const value = asString(source[key])
    if (value) return value
  }
  return null
}

function firstNumber(source: Record<string, unknown>, keys: string[]): number | null {
  for (const key of keys) {
    const value = asNumber(source[key])
    if (value !== null) return value
  }
  return null
}

function fusionMeta(post: BoardPost): Record<string, unknown> | null {
  const meta = asRecord(post.meta)
  if (!meta) return null
  if (asString(meta.source) === FUSION_BOARD_SOURCE) return meta

  const nested = asRecord(meta.fusion_deliberation)
  if (nested) return { ...nested, source: FUSION_BOARD_SOURCE }

  return null
}

function normalizePanelEntry(value: unknown, index: number): FusionPanelEntry | null {
  const entry = asRecord(value)
  if (!entry) return null
  const usage = asRecord(entry.usage)
  const model = firstString(entry, ['model', 'name', 'provider']) ?? `panel-${index + 1}`
  return {
    model,
    status: firstString(entry, ['status']) ?? 'unknown',
    answer: firstString(entry, ['answer', 'content', 'output']),
    reason: firstString(entry, ['reason', 'error', 'error_text']),
    inputTokens: firstNumber(entry, ['input_tokens', 'inputTokens']) ?? firstNumber(usage ?? {}, ['input_tokens', 'inputTokens']),
    outputTokens: firstNumber(entry, ['output_tokens', 'outputTokens']) ?? firstNumber(usage ?? {}, ['output_tokens', 'outputTokens']),
  }
}

function normalizePanel(value: unknown): FusionPanelEntry[] {
  if (!Array.isArray(value)) return []
  return value.flatMap((entry, index) => {
    const normalized = normalizePanelEntry(entry, index)
    return normalized ? [normalized] : []
  })
}

function normalizeJudge(value: unknown): FusionJudge {
  const judge = asRecord(value) ?? {}
  return {
    status: firstString(judge, ['status']),
    decision: firstString(judge, ['decision', 'verdict']),
    synthesis: firstString(judge, ['synthesis', 'rationale', 'summary']),
    resolvedAnswer: firstString(judge, ['resolved_answer', 'resolvedAnswer', 'answer']),
    error: firstString(judge, ['error', 'reason', 'error_text']),
  }
}

function normalizeUsage(meta: Record<string, unknown>, panel: FusionPanelEntry[]): FusionUsage {
  const observed = asRecord(meta.observed_usage) ?? {}
  const summedInput = panel.reduce((sum, entry) => sum + (entry.inputTokens ?? 0), 0)
  const summedOutput = panel.reduce((sum, entry) => sum + (entry.outputTokens ?? 0), 0)
  const inputTokens = firstNumber(observed, ['input_tokens', 'inputTokens'])
    ?? firstNumber(meta, ['input_tokens', 'inputTokens'])
    ?? (summedInput > 0 ? summedInput : null)
  const outputTokens = firstNumber(observed, ['output_tokens', 'outputTokens'])
    ?? firstNumber(meta, ['output_tokens', 'outputTokens'])
    ?? (summedOutput > 0 ? summedOutput : null)
  return {
    inputTokens,
    outputTokens,
    costUsd: firstNumber(meta, ['cost_usd', 'costUsd', 'observed_cost_usd']),
  }
}

function statusFor(judge: FusionJudge, panel: FusionPanelEntry[]): FusionRunStatus {
  const status = judge.status?.toLowerCase() ?? ''
  if (status.includes('fail')) return 'failed'
  if (judge.error) return 'failed'
  if (judge.resolvedAnswer || judge.synthesis || judge.decision || status.includes('synth')) return 'complete'
  if (panel.length > 0 && panel.every(entry => entry.status.toLowerCase().includes('fail'))) return 'failed'
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

function fusionRunFromPost(post: BoardPost): FusionRunView | null {
  const meta = fusionMeta(post)
  if (!meta) return null

  const panel = normalizePanel(meta.panel)
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

function formatTokens(value: number | null): string {
  if (value === null) return 'n/a'
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

function FusionPanelCard({ entry }: { entry: FusionPanelEntry }) {
  const failed = entry.status.toLowerCase().includes('fail')
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

function FusionRunRow({ run, active }: { run: FusionRunView; active: boolean }) {
  return html`
    <button
      type="button"
      class=${`fus-run-row ${active ? 'active' : ''} ${ringFocusClasses()}`}
      aria-current=${active ? 'true' : undefined}
      onClick=${() => replaceRoute('fusion', { run_id: run.runId })}
    >
      <span class="fus-row-top">
        <span class="fus-run-id">${run.runId}</span>
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
  const answered = run.panel.filter(entry => !entry.status.toLowerCase().includes('fail')).length
  const failed = run.panel.length - answered
  const synthesis = run.judge.synthesis ?? run.judge.error ?? 'No judge synthesis captured.'
  const resolved = run.judge.resolvedAnswer ?? 'No resolved answer captured.'

  return html`
    <article class="fus-detail" data-testid="fusion-detail">
      <header class="fus-detail-head">
        <div class="fus-detail-title">
          <div class="fus-detail-meta">
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
      </section>

      <section class="fus-resolved">
        <div class="fus-label">Resolved answer</div>
        <p>${resolved}</p>
      </section>

      <section class="fus-sink">
        <div>
          <div class="fus-label">Sink</div>
          <p>Board post ${run.boardPostId}</p>
        </div>
        <${AgentAvatar} name=${run.keeperName} size="sm" />
      </section>
    </article>
  `
}

export function FusionSurface() {
  const posts = boardPosts.value
  const runs = useMemo(() => buildFusionRuns(posts), [posts])
  const selectedRunId = route.value.params.run_id ?? route.value.params.run
  const selected = runs.find(run => run.runId === selectedRunId) ?? runs[0] ?? null
  const running = runs.filter(run => run.status === 'running').length
  const failed = runs.filter(run => run.status === 'failed').length

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
            onClick=${() => { void refreshBoard(); void refreshFusionRuns() }}
            disabled=${boardLoading.value || fusionRunsLoading.value}
          >${boardLoading.value || fusionRunsLoading.value ? 'Refreshing...' : 'Refresh'}</button>
        </header>

        <${FusionRunsPanel} />

        <section class="fus-top-kpis" aria-label="Fusion overview">
          <${FusionMetric} label="runs" value=${runs.length} tone=${runs.length ? 'ok' : 'muted'} />
          <${FusionMetric} label="running" value=${running} tone=${running ? 'warn' : 'muted'} />
          <${FusionMetric} label="failed" value=${failed} tone=${failed ? 'bad' : 'muted'} />
          <${FusionMetric} label="source" value="board meta" tone="volt" />
        </section>

        ${runs.length === 0
          ? html`
              <section class="fus-empty" data-testid="fusion-empty">
                <div class="fus-empty-mark">F</div>
                <h2>No fusion runs found</h2>
                <p>Load board posts with <code>meta.source = "fusion"</code> to review panel and judge output here.</p>
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
