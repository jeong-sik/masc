import { html } from 'htm/preact'
import { useMemo, useState } from 'preact/hooks'
import type { BoardPost } from '../../types'
import type { FusionRunRecord, FusionRunStatusLabel } from '../../api/dashboard'
import { navigate, replaceRoute, route } from '../../router'
import {
  fusionBoardError,
  fusionBoardLoading,
  fusionBoardPosts,
  fusionRuns,
  fusionRunsLoading,
  refreshFusionBoard,
  refreshFusionRuns,
} from '../../store'
import { TimeAgo } from '../common/time-ago'
import { ringFocusClasses } from '../common/ring'
import { RichContent } from '../common/rich-content'
import { AgentAvatar } from '../overview/agent-avatar'
import { fusionRunStatusText, fusionRunStatusTone } from './fusion-runs-panel'
import { asRecord, asString, asStringArray } from '../common/normalize'
import { fusionDecisionSpec, type FusionDecisionSpec } from '../v2/fusion-constants'
import {
  firstString,
  firstNumber,
  normalizeFusionPanel,
  normalizeFusionUsage,
  normalizeFusionJudgeNodes,
  classifyFusionJudgeShape,
  type FusionPanelEntry,
  type FusionJudgeNode,
  type FusionJudgeShape,
} from '../../lib/fusion-meta'
import {
  judgeShapeLabel,
  judgeRoleLabel,
  judgeNodeTokenLabel,
  judgeNodeIdentity,
  judgeNodeElapsedLabel,
} from './fusion-judge-format'

type FusionRunStatus = 'complete' | 'failed' | 'running'
type FusionTone = 'ok' | 'warn' | 'bad' | 'volt' | 'muted'
type FusionDecisionKey = 'Answer' | 'Recommend' | 'Insufficient'

const FAILED_PANEL_STATUSES: readonly string[] = ['failed', 'error']
const FAILED_JUDGE_STATUSES: readonly string[] = ['failed', 'error']
const COMPLETE_JUDGE_STATUSES: readonly string[] = ['synthesized', 'complete', 'completed']
const DECISION_KEY_BY_TOKEN: Readonly<Record<string, FusionDecisionKey>> = {
  answer: 'Answer',
  recommend: 'Recommend',
  insufficient: 'Insufficient',
}

function isPanelFailure(status: string): status is 'failed' | 'error' {
  return FAILED_PANEL_STATUSES.includes(status)
}

function normalizedWireToken(value: string | null): string | null {
  const trimmed = value?.trim()
  return trimmed ? trimmed.toLowerCase() : null
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

interface FusionRunParams {
  temperature: number | null
  topP: number | null
  topK: number | null
  maxTokens: number | null
}

interface FusionRunView {
  runId: string
  boardPostId: string
  boardOriginSource: string | null
  boardOriginRunId: string | null
  keeperName: string
  title: string
  question: string
  status: FusionRunStatus
  tone: FusionTone
  panel: FusionPanelEntry[]
  judge: FusionJudge
  judges: FusionJudgeNode[]
  usage: FusionUsage
  preset: string | null
  params: FusionRunParams
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

function normalizeParams(meta: Record<string, unknown>): FusionRunParams {
  return {
    temperature: firstNumber(meta, ['temperature']),
    topP: firstNumber(meta, ['top_p', 'topP']),
    topK: firstNumber(meta, ['top_k', 'topK']),
    maxTokens: firstNumber(meta, ['max_tokens', 'maxTokens']),
  }
}

function statusFor(judge: FusionJudge, panel: FusionPanelEntry[]): FusionRunStatus {
  const status = normalizedWireToken(judge.status)
  if (status && FAILED_JUDGE_STATUSES.includes(status)) return 'failed'
  if (judge.error) return 'failed'
  if (judge.resolvedAnswer || judge.synthesis || judge.decision) return 'complete'
  if (status && COMPLETE_JUDGE_STATUSES.includes(status)) return 'complete'
  if (panel.length > 0 && panel.every(entry => isPanelFailure(entry.status))) return 'failed'
  return 'running'
}

interface ParsedFusionDecision {
  raw: string
  key: FusionDecisionKey | null
}

function parseFusionDecision(decision: string | null): ParsedFusionDecision | null {
  const raw = decision?.trim()
  if (!raw) return null
  const token = normalizedWireToken(raw)
  return {
    raw,
    key: token ? DECISION_KEY_BY_TOKEN[token] ?? null : null,
  }
}

function toneFor(status: FusionRunStatus, decision: string | null): FusionTone {
  if (status === 'failed') return 'bad'
  const parsed = parseFusionDecision(decision)
  if (parsed?.key === 'Answer') return 'ok'
  if (parsed?.key === 'Recommend') return 'volt'
  if (parsed?.key === 'Insufficient') return 'warn'
  if (parsed && status === 'complete') return 'warn'
  return status === 'running' ? 'muted' : 'ok'
}

// Only exact wire decision tokens are elevated to semantic badges. Description
// strings remain raw/neutral so protocol drift is visible instead of silently
// inheriting the wrong label, glyph, or tone.
function decisionSpecFor(decision: string | null): FusionDecisionSpec | null {
  const parsed = parseFusionDecision(decision)
  if (!parsed) return null
  return fusionDecisionSpec(parsed.key ?? parsed.raw)
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
  const judges = normalizeFusionJudgeNodes(meta.judges)
  const usage = normalizeUsage(meta, panel)
  const params = normalizeParams(meta)
  const runId = firstString(meta, ['run_id', 'runId', 'id']) ?? post.id
  const question = firstString(meta, ['question', 'prompt']) ?? post.body ?? post.content ?? post.title
  const status = statusFor(judge, panel)
  const tone = toneFor(status, judge.decision)

  return {
    runId,
    boardPostId: post.id,
    boardOriginSource: post.origin?.source ?? null,
    boardOriginRunId: post.origin?.fusion_run_id ?? null,
    keeperName: keeperNameFor(post),
    title: post.title || `Fusion run ${runId}`,
    question,
    status,
    tone,
    panel,
    judge,
    judges,
    usage,
    preset: null,
    params,
    createdAt: post.created_at,
    updatedAt: post.updated_at || post.created_at,
  }
}

function timeValue(iso: string): number {
  const parsed = Date.parse(iso)
  return Number.isFinite(parsed) ? parsed : 0
}

// No sort here: ordering is owned exclusively by buildMergedRuns (creation/
// start axis). A second, different sort key at this layer is exactly the
// mixed-axis bug this file just removed.
function buildFusionRuns(posts: readonly BoardPost[]): FusionRunView[] {
  return posts.flatMap(post => {
    const run = fusionRunFromPost(post)
    return run ? [run] : []
  })
}

// Registry status ('completed') aligned to the board run status enum ('complete')
// so the shared status glyph / row styling apply to registry-only rows unchanged.
function registryToRunStatus(status: FusionRunStatusLabel): FusionRunStatus {
  return status === 'completed' ? 'complete' : status
}

// A sidebar run is either a board-sink run (full panel/judge detail) or a
// registry-only run — an in-progress or just-finished deliberation the registry
// tracks before a board post exists. They are merged into ONE master list so the
// surface matches the prototype's 2-pane master/detail instead of stacking a
// separate registry panel above it.
type MergedRun =
  | { kind: 'board'; runId: string; sortTime: number; running: boolean; view: FusionRunView }
  | { kind: 'registry'; runId: string; sortTime: number; running: boolean; record: FusionRunRecord }

// Master-list page size: rows rendered initially and added per "더 보기" click.
const FUSION_LIST_PAGE_SIZE = 30

// Dedup key is runId: once a deliberation lands a board post the board entry wins
// (it carries the detail), so the registry duplicate is dropped. Running rows pin
// to the top (the live work), then recency on a SINGLE stable axis per row kind:
// board post creation (createdAt ISO — the post lands when the deliberation
// completes) and registry start (startedAt unix seconds), both normalized to ms.
// The two kinds approximate different moments of a run's life, but each is
// immutable, which is the property that matters: sorting board rows by
// updatedAt let an old run leapfrog newer ones whenever its post was touched,
// which read as a jumbled list (38-bug campaign #34).
function buildMergedRuns(
  boardRuns: readonly FusionRunView[],
  registryRuns: readonly FusionRunRecord[],
): MergedRun[] {
  const boardIds = new Set(boardRuns.map(run => run.runId))
  const merged: MergedRun[] = [
    ...boardRuns.map((view): MergedRun => ({
      kind: 'board',
      runId: view.runId,
      sortTime: timeValue(view.createdAt),
      running: view.status === 'running',
      view,
    })),
    ...registryRuns
      .filter(record => !boardIds.has(record.runId))
      .map((record): MergedRun => ({
        kind: 'registry',
        runId: record.runId,
        sortTime: record.startedAt * 1000,
        running: record.status === 'running',
        record,
      })),
  ]
  return merged.sort((a, b) => {
    if (a.running !== b.running) return a.running ? -1 : 1
    return b.sortTime - a.sortTime
  })
}

function formatCost(value: number | null): string {
  if (value === null) return 'n/a'
  return `$${value.toFixed(4)}`
}

/** Combined panel+judge token total, in `Nk` form, for the detail KPI strip
 *  (prototype collapses the in/out split into one figure). Returns `null` when
 *  there is no token data so the cell renders an honest em-dash. */
function combinedTokenLabel(usage: FusionUsage): string | null {
  const input = usage.inputTokens ?? 0
  const output = usage.outputTokens ?? 0
  const total = input + output
  if (total <= 0) return null
  return total >= 1000 ? `${(total / 1000).toFixed(1)}k` : String(total)
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

// Prototype detail KPI cell (`.fus-kpi` with `.k`/`.v`, optional `.v` tone +
// `<small>` unit). Replaces the dead `.fus-kpi-k`/`.fus-kpi-v` markup.
function FusionMetric({
  label,
  value,
  unit,
  tone,
}: {
  label: string
  value: string | number
  unit?: string
  tone?: FusionTone
}) {
  return html`
    <div class="fus-kpi">
      <div class="k">${label}</div>
      <div class=${tone ? `v ${tone}` : 'v'}>
        ${value}${unit ? html`<small> ${unit}</small>` : null}
      </div>
    </div>
  `
}

function FusionStatusGlyph({ status }: { status: FusionRunStatus }) {
  return html`<span class=${`fus-rdot ${statusDotClass(status)}`} aria-hidden="true"></span>`
}

// Keeper identity link (prototype `.fus-who`/`.nm`). Navigates to the keeper
// chat lane, preserving the existing `navigate('keepers', …)` wiring.
function FusionKeeperLink({ keeper, size = 'sm' }: { keeper: string; size?: 'sm' | 'md' }) {
  return html`
    <button
      type="button"
      class=${`fus-who ${ringFocusClasses()}`}
      title=${`${keeper} 대화 열기`}
      onClick=${(event: Event) => {
        event.stopPropagation()
        navigate('keepers', { keeper })
      }}
    >
      <${AgentAvatar} name=${keeper} size=${size} />
      <span class="nm">${keeper}</span>
    </button>
  `
}

// RFC-0284 PR 2: render the observed judge nodes as a structural strip so the
// execution topology (JoJ = N 1차 + 메타, refine = 2, simple = 1) is visible
// instead of collapsing into the single canonical judge. Topology is read from
// the array shape alone; the canonical synthesis below is unchanged. Renders
// nothing for older board posts that predate the `judges` array.
export function FusionJudgesStrip({ nodes }: { nodes: readonly FusionJudgeNode[] }) {
  if (nodes.length === 0) return null
  const shape = classifyFusionJudgeShape(nodes)
  return html`
    <div class="fus-block">
      <div class="fus-block-lbl">
        심판 위상 · ${judgeShapeLabel(shape)}
        <span class="fus-sub-note">관측된 심판 노드 ${nodes.length}개 · RFC-0284</span>
      </div>
      <ul class="fus-judges" data-testid="fusion-judges" role="list">
        ${nodes.map(
          (node, index) => html`
            <li
              class=${`fus-judge-node ${node.failed ? 'failed' : 'ok'}`}
              key=${`${node.role}-${node.identity}-${index}`}
              data-role=${node.role}
              data-failed=${node.failed ? 'true' : 'false'}
            >
              <span class="fus-jn-role">${judgeRoleLabel(node.role)}</span>
              <span class="fus-jn-id mono" title=${judgeNodeIdentity(node) ?? ''}>
                ${judgeNodeIdentity(node) ?? ''}
              </span>
              ${node.failed && node.failureCode
                ? html`<span class="fus-jn-code mono" title=${node.error ?? node.failureCode}>${node.failureCode}</span>`
                : null}
              ${node.failed && judgeNodeElapsedLabel(node)
                ? html`<span
                    class=${`fus-jn-time ${node.timedOut ? 'timeout' : ''}`}
                    title=${node.timedOut ? '타임아웃 초과' : '경과 시간'}
                  >${judgeNodeElapsedLabel(node)}</span>`
                : null}
              <span class="fus-jn-tok">${judgeNodeTokenLabel(node)}</span>
              ${node.failed
                ? html`<span class="fus-jn-status deny" title=${node.error ?? 'failed'}>✗ 실패</span>`
                : html`<span class="fus-jn-status done">✓</span>`}
            </li>
          `,
        )}
      </ul>
    </div>
  `
}

// Structural JoJ facts derived from the observed judges array (single source of
// truth: the array shape + per-node role/failed). Shared by the pipeline strip,
// the first-judge card grid, the meta-drop isolation banner, and the topology
// chip so those four surfaces never diverge. `isolatedFirst` are the failed 1차
// 심판 nodes that meta reconcile excludes (RFC-0283 §2.3).
interface FusionShapeInfo {
  shape: FusionJudgeShape
  isJoj: boolean
  isRefine: boolean
  firstNodes: FusionJudgeNode[]
  isolatedFirst: FusionJudgeNode[]
  okFirstCount: number
}

function fusionShapeInfo(judges: readonly FusionJudgeNode[]): FusionShapeInfo {
  const shape = classifyFusionJudgeShape(judges)
  const firstNodes = judges.filter(node => node.role === 'first')
  const isolatedFirst = firstNodes.filter(node => node.failed)
  return {
    shape,
    isJoj: shape === 'judge-of-judges',
    isRefine: shape === 'refine',
    firstNodes,
    isolatedFirst,
    okFirstCount: firstNodes.length - isolatedFirst.length,
  }
}

// `identity (error), identity2 (error2)` for the meta-drop banner. identity is
// the panelist_id the backend carries on `first` nodes; error is the recorded
// failure reason (both from fusion_sink.ml Judge_failed). Falls back to the raw
// identity when no error string is present.
function metaDropLabel(isolated: readonly FusionJudgeNode[]): string {
  return isolated
    .map(node => {
      const id = judgeNodeIdentity(node) ?? node.identity
      return node.error ? `${id} (${node.error})` : id
    })
    .join(', ')
}

// A first-tier judge's 합의/상충 counts are derived from the meta judge's
// consensus[]/contradictions[] matched on the node identity — the single source
// of truth (the counts are never stored per node). meta.consensus.models and
// contradiction positions reference the first-judge identities (= panelist_ids),
// so a node's identity is the match key.
function firstJudgeConsensusCount(judge: FusionJudge, identity: string): number {
  return judge.consensus.filter(claim => claim.models.includes(identity)).length
}

function firstJudgeContradictionCount(judge: FusionJudge, identity: string): number {
  return judge.contradictions.filter(row => row.positions.some(position => position.model === identity)).length
}

// One 1차 심판 card (design FirstJudges). A failed node renders an isolation card
// (excluded from meta reconcile, RFC-0283 §2.3); a synthesized node shows its
// decision badge, resolved-answer gist, derived 합의/상충 counts, and token spend.
// No lens/model split — the backend carries only `identity` (= panelist_id) for a
// first node, so inventing a persona/model split would fabricate data.
function FusionFirstJudgeCard({ node, judge }: { node: FusionJudgeNode; judge: FusionJudge }) {
  if (node.failed) {
    return html`
      <article class="fus-jnode failed">
        <div class="fus-jnode-h">
          <span class="fus-jnode-id">${node.identity}</span>
          <span class="fus-jnode-fail">✗ ${node.error ?? '실패'}</span>
        </div>
        <p class="fus-jnode-isolated">격리됨 — meta reconcile에서 제외. 나머지 종합으로 진행(§2.3 격리).</p>
      </article>
    `
  }
  const dec = decisionSpecFor(node.decision ?? null)
  const consensusN = firstJudgeConsensusCount(judge, node.identity)
  const contraN = firstJudgeContradictionCount(judge, node.identity)
  return html`
    <article class="fus-jnode">
      <div class="fus-jnode-h">
        <span class="fus-jnode-id">${node.identity}</span>
        ${dec ? html`<span class=${`fus-dec-badge sm ${dec.cls}`}>${dec.glyph} ${dec.lbl}</span>` : null}
      </div>
      ${node.summary ? html`<p class="fus-jnode-sum">${compactText(node.summary, 240)}</p>` : null}
      <div class="fus-jnode-f">
        <span class="fus-jnode-stat">합의 ${consensusN}</span>
        <span class="fus-jnode-stat">상충 ${contraN}</span>
        <span class="fus-jnode-tok mono">${judgeNodeTokenLabel(node)}</span>
      </div>
    </article>
  `
}

// 1차 심판 card grid for a judge-of-judges run (N independent syntheses before
// meta reconcile). Renders nothing for a non-JoJ shape so simple/refine runs are
// unaffected.
function FusionFirstJudges({ shape, judge }: { shape: FusionShapeInfo; judge: FusionJudge }) {
  if (!shape.isJoj || shape.firstNodes.length === 0) return null
  return html`
    <div class="fus-block">
      <div class="fus-block-lbl">
        1차 심판 · ${shape.firstNodes.length}개 병렬
        <span class="fus-sub-note">패널과 독립 구성(judge_spec list)${
          shape.isolatedFirst.length > 0 ? ` · ${shape.isolatedFirst.length}개 격리` : ''
        }</span>
      </div>
      <div class="fus-jnodes" data-testid="fusion-first-judges">
        ${shape.firstNodes.map(
          (node, index) => html`<${FusionFirstJudgeCard} key=${`${node.identity}-${index}`} node=${node} judge=${judge} />`,
        )}
      </div>
    </div>
  `
}

function FusionPipelineStrip({ run }: { run: FusionRunView }) {
  const panelFailures = run.panel.filter(entry => isPanelFailure(entry.status)).length
  const gateClass = run.status === 'failed' && run.panel.length === 0 ? 'deny' : 'gate'
  const panelLabel = run.panel.length > 0 ? `panel ×${run.panel.length}` : 'panel pending'
  const off = run.status === 'failed' || run.status === 'running'
  const shape = fusionShapeInfo(run.judges)

  // Judge segment is shape-derived (no hardcoded topology branch): a JoJ run
  // renders `1차 심판 ×N (k 격리)` → `meta`; a refine run renders `심판` → `재검토`;
  // a single/custom shape keeps the one judge node labelled by its decision or
  // status (unchanged from the pre-RFC-0284 strip).
  const judgeSegment = shape.isJoj
    ? html`
        <span class=${`fus-pipe-node judge ${off ? 'off' : ''}`}>
          1차 심판 ×${shape.firstNodes.length}${shape.isolatedFirst.length > 0
            ? html`<em class="fus-pipe-iso"> ${shape.isolatedFirst.length} 격리</em>`
            : null}
        </span>
        <span class="fus-pipe-arr" aria-hidden="true">→</span>
        <span class=${`fus-pipe-node meta ${off ? 'off' : ''}`}>meta</span>
      `
    : shape.isRefine
      ? html`
          <span class=${`fus-pipe-node judge ${off ? 'off' : ''}`}>심판</span>
          <span class="fus-pipe-arr" aria-hidden="true">→</span>
          <span class=${`fus-pipe-node meta ${off ? 'off' : ''}`}>재검토</span>
        `
      : html`<span class=${`fus-pipe-node judge ${off ? 'off' : ''}`}>${run.judge.decision ?? run.judge.status ?? (run.status === 'running' ? 'judge pending' : 'judge')}</span>`

  return html`
    <section class="fus-pipe" data-testid="fusion-pipe" aria-label="Fusion run pipeline">
      <span class="fus-pipe-node kp">
        <${FusionStatusGlyph} status=${run.status} />
        keeper turn
      </span>
      <span class="fus-pipe-arr" aria-hidden="true">→</span>
      <span class=${`fus-pipe-node ${gateClass} ${gateClass === 'gate' ? 'ok' : ''}`}>gate</span>
      <span class="fus-pipe-arr" aria-hidden="true">→</span>
      <span class=${`fus-pipe-node panel ${run.status === 'failed' && run.panel.length === 0 ? 'off' : ''}`}>
        ${panelLabel}${panelFailures > 0 ? ` · fail ${panelFailures}` : ''}
      </span>
      <span class="fus-pipe-arr" aria-hidden="true">→</span>
      ${judgeSegment}
      <span class="fus-pipe-arr" aria-hidden="true">→</span>
      <span class=${`fus-pipe-node sink ${run.status === 'complete' ? '' : 'off'}`}>board evidence</span>
    </section>
  `
}

// Prototype panel card (`.fus-pcard`). Retains `.fus-panel-card` +
// `answered`/`failed` modifiers so existing tests keep matching, and adds the
// vendored `.fus-pcard*` classes that actually style the card. The answer body
// is collapsible (prototype `.fus-pans`).
function FusionPanelCard({ entry }: { entry: FusionPanelEntry }) {
  const failed = isPanelFailure(entry.status)
  const [open, setOpen] = useState(false)
  const body = entry.answer ?? entry.reason ?? 'No panel output captured.'
  const tokenTotal = (entry.inputTokens ?? 0) + (entry.outputTokens ?? 0)
  const tokenLabel = tokenTotal > 0
    ? (tokenTotal >= 1000 ? `${(tokenTotal / 1000).toFixed(1)}k` : String(tokenTotal))
    : null

  return html`
    <article class=${`fus-pcard fus-panel-card ${failed ? 'failed' : 'answered'}`}>
      <div class="fus-pcard-h">
        <span class="fus-pmodel mono">${entry.model}</span>
        ${failed && entry.reasonCode
          ? html`<span class="fus-pcode mono" title=${entry.reason ?? entry.reasonCode}>${entry.reasonCode}</span>`
          : null}
        ${failed
          ? html`<span class="fus-pstate fail">${entry.reason ?? entry.status}</span>`
          : tokenLabel
            ? html`<span class="fus-ptok mono" title="입력+출력 토큰">${tokenLabel} tok</span>`
            : null}
      </div>
      ${failed
        ? html`<div class="fus-pans failed">${body}</div>`
        : html`
            <div
              class=${`fus-pans ${open ? 'open' : ''}`}
              role="button"
              tabIndex=${0}
              title=${open ? '접기' : '펼치기'}
              onClick=${() => setOpen(prev => !prev)}
              onKeyDown=${(event: KeyboardEvent) => {
                if (event.key === 'Enter' || event.key === ' ') {
                  event.preventDefault()
                  setOpen(prev => !prev)
                }
              }}
            ><${RichContent} text=${body} previewLimit=${0} /></div>
          `}
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
    <span class="fus-mchips">
      ${models.map(model => html`<span class="fus-mchip mono" key=${model}>${model}</span>`)}
    </span>
  `
}

// Structured judge synthesis (prototype `.fus-judge-body` / `.fus-jsec`).
// Keeps `data-testid="fusion-judge-evidence"` + the "Structured judge evidence"
// summary head (consumed by tests) and renders the five prototype groups with
// glyphs + counts.
function FusionJudgeEvidence({ judge }: { judge: FusionJudge }) {
  if (!hasStructuredJudgeEvidence(judge)) return null

  return html`
    <div class="fus-judge" data-testid="fusion-judge-evidence">
      <div class="fus-judge-body">
        <section class="fus-jsec consensus" hidden=${judge.consensus.length === 0}>
          <h5>
            <span class="fus-jglyph">≡</span>합의 <span class="n">${judge.consensus.length}</span>
            <span class="fus-sub-note">Structured judge evidence</span>
          </h5>
          ${judge.consensus.map((claim, index) => html`
            <div class="fus-claim" key=${`consensus-${index}`}>
              <div class="fus-claim-text"><${RichContent} text=${claim.text} previewLimit=${0} /></div>
              <${FusionModelChips} models=${claim.models} />
            </div>
          `)}
        </section>

        ${judge.contradictions.length > 0
          ? html`
              <section class="fus-jsec contra">
                <h5><span class="fus-jglyph">⇄</span>상충 <span class="n">${judge.contradictions.length}</span></h5>
                ${judge.contradictions.map((contradiction, index) => html`
                  <div class="fus-contra" key=${`contradiction-${index}`}>
                    <div class="fus-contra-topic">${contradiction.topic}</div>
                    ${contradiction.positions.map(position => html`
                      <div class="fus-pos" key=${`${contradiction.topic}:${position.model}`}>
                        <span class="fus-pos-m mono">${position.model}</span>
                        <div class="fus-pos-s"><${RichContent} text=${position.stance} previewLimit=${0} /></div>
                      </div>
                    `)}
                  </div>
                `)}
              </section>
            `
          : null}

        ${judge.partialCoverage.length > 0
          ? html`
              <section class="fus-jsec coverage">
                <h5><span class="fus-jglyph">◑</span>부분 커버리지 <span class="n">${judge.partialCoverage.length}</span></h5>
                ${judge.partialCoverage.map((gap, index) => html`
                  <div class="fus-gap" key=${`coverage-${index}`}>
                    <div class="fus-gap-topic">${gap.topic}</div>
                    <div class="fus-gap-row">
                      <span class="k">다룸</span>
                      <${FusionModelChips} models=${gap.addressedBy} />
                    </div>
                    <div class="fus-gap-row">
                      <span class="k">누락</span>
                      <div class="fus-gap-miss"><${RichContent} text=${gap.missing} previewLimit=${0} /></div>
                    </div>
                  </div>
                `)}
              </section>
            `
          : null}

        ${judge.uniqueInsights.length > 0
          ? html`
              <section class="fus-jsec insight">
                <h5><span class="fus-jglyph">✦</span>고유 통찰 <span class="n">${judge.uniqueInsights.length}</span></h5>
                ${judge.uniqueInsights.map((insight, index) => html`
                  <div class="fus-insight" key=${`insight-${index}`}>
                    <div class="fus-insight-text"><${RichContent} text=${insight.text} previewLimit=${0} /></div>
                    ${insight.model ? html`<span class="fus-mchip mono">${insight.model}</span>` : null}
                  </div>
                `)}
              </section>
            `
          : null}

        ${judge.blindSpots.length > 0
          ? html`
              <section class="fus-jsec blind">
                <h5><span class="fus-jglyph">⚠</span>사각지대 <span class="n">${judge.blindSpots.length}</span></h5>
                <ul class="fus-blind">${judge.blindSpots.map(item => html`<li key=${item}><${RichContent} text=${item} previewLimit=${0} /></li>`)}</ul>
              </section>
            `
          : null}

        ${judge.missingInputs.length > 0
          ? html`
              <section class="fus-jsec blind">
                <h5><span class="fus-jglyph">⚠</span>부족한 입력 <span class="n">${judge.missingInputs.length}</span></h5>
                <ul class="fus-blind">${judge.missingInputs.map(item => html`<li key=${item}><${RichContent} text=${item} previewLimit=${0} /></li>`)}</ul>
              </section>
            `
          : null}
      </div>
    </div>
  `
}

// Row timestamp renders createdAt to match the list's sort axis: showing
// updatedAt made an edited old post wear a fresher timestamp than the rows
// above it, reproducing the jumbled impression the sort fix removed.
function FusionRunRow({ run, active }: { run: FusionRunView; active: boolean }) {
  const dec = decisionSpecFor(run.judge.decision)
  return html`
    <button
      type="button"
      class=${`fus-run-row fus-row ${active ? 'active sel' : ''} st-${run.status} ${ringFocusClasses()}`}
      aria-current=${active ? 'true' : undefined}
      onClick=${() => replaceRoute('fusion', { run_id: run.runId })}
    >
      <span class="fus-row-h">
        <${FusionStatusGlyph} status=${run.status} />
        <span class="fus-run-id mono">${run.runId}</span>
        <span class="fus-row-ts"><${TimeAgo} timestamp=${run.createdAt} /></span>
      </span>
      <span class="fus-row-prompt">${compactText(run.question, 110)}</span>
      <span class="fus-row-f">
        <span class="fus-who static" title=${run.keeperName}>
          <${AgentAvatar} name=${run.keeperName} size="sm" />
          <span class="nm">${run.keeperName}</span>
        </span>
        <span class="spacer"></span>
        ${run.status === 'running'
          ? html`<span class="fus-dec-badge run">심의 중</span>`
          : run.status === 'failed'
            ? html`<span class="fus-dec-badge bad">실패</span>`
            : dec
              ? html`<span class=${`fus-dec-badge ${dec.cls}`}>${dec.glyph} ${dec.lbl}</span>`
              : null}
      </span>
    </button>
  `
}

// Sidebar row for a registry-only run (no board post yet). Reuses the board
// row's `.fus-row` shell but carries no prompt/decision — the registry record
// only knows runId, keeper, preset, status, startedAt.
function FusionRegistryRow({ record, active }: { record: FusionRunRecord; active: boolean }) {
  const status = registryToRunStatus(record.status)
  const keeper = record.keeper || 'system'
  return html`
    <button
      type="button"
      class=${`fus-run-row fus-row registry-only ${active ? 'active sel' : ''} st-${status} ${ringFocusClasses()}`}
      aria-current=${active ? 'true' : undefined}
      data-testid="fusion-registry-row"
      onClick=${() => replaceRoute('fusion', { run_id: record.runId })}
    >
      <span class="fus-row-h">
        <${FusionStatusGlyph} status=${status} />
        <span class="fus-run-id mono">${record.runId}</span>
        <span class="fus-row-ts"><${TimeAgo} timestamp=${record.startedAt} /></span>
      </span>
      <span class="fus-row-f">
        <span class="fus-who static" title=${keeper}>
          <${AgentAvatar} name=${keeper} size="sm" />
          <span class="nm">${keeper}</span>
        </span>
        <span class="spacer"></span>
        ${record.status === 'running'
          ? html`<span class="fus-dec-badge run">심의 중</span>`
          : record.status === 'failed'
            ? html`<span class="fus-dec-badge bad">실패</span>`
            : html`<span class="fus-dec-badge">레지스트리</span>`}
      </span>
    </button>
  `
}

function findPreset(runId: string): string | null {
  return fusionRuns.value.find(run => run.runId === runId)?.preset ?? null
}

function paramChip(label: string, value: number | null): ReturnType<typeof html> | null {
  if (value === null) return null
  return html`<span class="fus-param"><span class="k">${label}</span><span class="v">${value}</span></span>`
}

function hasParams(params: FusionRunParams): boolean {
  return params.temperature !== null
    || params.topP !== null
    || params.topK !== null
    || params.maxTokens !== null
}

type FusionSinkLinkageStatus = 'verified' | 'missing' | 'mismatch'

interface FusionSinkLinkage {
  status: FusionSinkLinkageStatus
  label: string
  detail: string
}

function sinkLinkageFor(run: FusionRunView): FusionSinkLinkage {
  if (run.boardOriginSource !== FUSION_BOARD_SOURCE || !run.boardOriginRunId) {
    return {
      status: 'missing',
      label: 'origin unverified',
      detail: 'typed board origin is absent; using meta.run_id only',
    }
  }
  if (run.boardOriginRunId !== run.runId) {
    return {
      status: 'mismatch',
      label: 'origin mismatch',
      detail: `origin.fusion_run_id=${run.boardOriginRunId}`,
    }
  }
  return {
    status: 'verified',
    label: 'origin verified',
    detail: 'origin.source=fusion and origin.fusion_run_id match meta.run_id',
  }
}

function FusionSinkLinkageBadge({ linkage }: { linkage: FusionSinkLinkage }) {
  return html`
    <span
      class=${`fus-sink-linkage ${linkage.status}`}
      data-testid="fusion-sink-linkage"
      data-linkage-status=${linkage.status}
      title=${linkage.detail}
    >
      <span class="fus-sink-linkage-k">${linkage.label}</span>
      <span class="fus-sink-linkage-v">${linkage.detail}</span>
    </span>
  `
}

// Presentation-only thresholds for clamping a long resolved_answer. These are a
// display heuristic, not a semantic model of the rendered markdown — RichContent
// owns markdown parsing, so this deliberately avoids counting markdown blocks and
// instead uses the raw character length plus a blank-line paragraph count (the
// cheap signal available before RichContent runs). Tuning them changes only when
// the reveal toggle appears, never the content.
const RESOLVED_CLAMP_CHAR_THRESHOLD = 540
const RESOLVED_CLAMP_PARAGRAPH_THRESHOLD = 5

// Count blank-line-separated text paragraphs (a display signal, not markdown blocks).
function countTextParagraphs(text: string): number {
  return text.split(/\n{2,}/).filter(paragraph => paragraph.trim().length > 0).length
}

function FusionResolvedBody({ text }: { text: string }) {
  const [open, setOpen] = useState(false)
  const long =
    text.length > RESOLVED_CLAMP_CHAR_THRESHOLD
    || countTextParagraphs(text) > RESOLVED_CLAMP_PARAGRAPH_THRESHOLD
  return html`
    <div class="fus-resolved-body">
      <div class=${`fus-rich ${long && !open ? 'clamp' : ''}`}>
        <${RichContent} text=${text} previewLimit=${0} />
      </div>
      ${long
        ? html`<button
            type="button"
            class=${`fus-rich-more ${ringFocusClasses()}`}
            onClick=${() => setOpen(prev => !prev)}
          >${open ? '접기 ▴' : '전문 펼치기 ▾'}</button>`
        : null}
    </div>
  `
}

function FusionRunDetail({ run }: { run: FusionRunView }) {
  const answered = run.panel.filter(entry => !isPanelFailure(entry.status)).length
  const failed = run.panel.length - answered
  const resolved = run.judge.resolvedAnswer ?? run.judge.synthesis ?? run.judge.error ?? 'No resolved answer captured.'
  const dec = decisionSpecFor(run.judge.decision)
  const decClass = dec && dec.cls ? `dec-${dec.cls}` : ''
  const tokenLabel = combinedTokenLabel(run.usage)
  const preset = run.preset ?? findPreset(run.runId)
  const shape = fusionShapeInfo(run.judges)
  const sinkLinkage = sinkLinkageFor(run)

  return html`
    <div class="fus-run-scroll" data-testid="fusion-detail">
      <div class="fus-run-head">
        <div class="fus-run-id-row">
          <${FusionStatusGlyph} status=${run.status} />
          <h1 class="mono">${run.runId}</h1>
          ${preset ? html`<span class="fus-preset" title="runtime.toml [fusion.presets.*]">preset · ${preset}</span>` : null}
          <span class=${`fus-status tone-${run.tone}`}>${statusLabel(run.status)}</span>
        </div>
        <div class="fus-run-by">
          <${FusionKeeperLink} keeper=${run.keeperName} size="md" />
          <span class="fus-run-meta"><${TimeAgo} timestamp=${run.updatedAt} mode="both" /></span>
          <span class="spacer"></span>
          <button
            type="button"
            class=${`fus-link inline ${ringFocusClasses()}`}
            onClick=${() => navigate('keepers', { keeper: run.keeperName })}
          >키퍼 열기</button>
          <button
            type="button"
            class=${`fus-link inline ${ringFocusClasses()}`}
            onClick=${() => navigate('board', { post: run.boardPostId })}
          >보드 포스트 열기</button>
        </div>
      </div>

      <${FusionPipelineStrip} run=${run} />

      ${hasParams(run.params)
        ? html`
            <div class="fus-block">
              <div class="fus-block-lbl">생성 파라미터</div>
              <div class="fus-params">
                ${paramChip('temperature', run.params.temperature)}
                ${paramChip('top_p', run.params.topP)}
                ${paramChip('top_k', run.params.topK)}
                ${paramChip('max_tokens', run.params.maxTokens)}
              </div>
            </div>
          `
        : null}

      <div class="fus-kpis" aria-label="Fusion run metrics">
        <${FusionMetric}
          label="패널"
          value=${`${answered}/${run.panel.length}`}
          unit="모델"
          tone=${failed > 0 ? 'warn' : 'ok'}
        />
        <${FusionMetric} label="토큰 (패널+심판)" value=${tokenLabel ?? '—'} />
        <${FusionMetric} label="비용 (관측)" value=${formatCost(run.usage.costUsd)} />
        <${FusionMetric}
          label="결정"
          value=${dec ? dec.lbl : run.status === 'failed' ? '실패' : '대기'}
          tone=${dec && (dec.cls === 'ok' || dec.cls === 'warn' || dec.cls === 'volt') ? dec.cls : run.status === 'failed' ? 'bad' : undefined}
        />
      </div>

      <div class="fus-block">
        <div class="fus-block-lbl">심의 프롬프트</div>
        <div class="fus-prompt"><${RichContent} text=${run.question} previewLimit=${0} /></div>
      </div>

      <div class="fus-block">
        <div class="fus-block-lbl">
          패널 · ${run.panel.length}개 모델 병렬
          <span class="fus-sub-note">Async_agent.all · 실패 격리</span>
        </div>
        ${run.panel.length === 0
          ? html`<div class="fus-judge-wait">패널 응답이 기록되지 않았습니다.</div>`
          : html`<div class="fus-panel-grid">${run.panel.map(entry => html`<${FusionPanelCard} key=${entry.model} entry=${entry} />`)}</div>`}
      </div>

      <${FusionJudgesStrip} nodes=${run.judges} />

      <${FusionFirstJudges} shape=${shape} judge=${run.judge} />

      ${run.status === 'running'
        ? html`
            <div class="fus-block">
              <div class="fus-block-lbl">심판 종합</div>
              <div class="fus-judge-wait">
                <span class="fus-rdot run"></span>패널 응답 대기 중 — 전원 도착 후 심판(Structured.extract)이 1회 호출됩니다.
              </div>
            </div>
          `
        : html`
            <div class="fus-block">
              <div class="fus-block-lbl">
                ${shape.isJoj ? 'meta 심판 · reconcile' : '심판 종합'}
                <span class="fus-judge-model mono">${run.judge.decision ?? run.judge.status ?? 'n/a'}</span>
                <span class="fus-sub-note">${shape.isJoj
                  ? `1차 종합 ${shape.okFirstCount}개 reconcile`
                  : 'Structured.extract · 닫힌 타입 schema'}</span>
              </div>
              ${shape.isolatedFirst.length > 0
                ? html`<div class="fus-meta-drop">⚠ 격리됨: ${metaDropLabel(shape.isolatedFirst)} — meta는 살아남은 종합만으로 reconcile</div>`
                : null}
              ${hasStructuredJudgeEvidence(run.judge)
                ? html`<${FusionJudgeEvidence} judge=${run.judge} />`
                : html`<div class="fus-judge-wait">구조화된 심판 근거가 기록되지 않았습니다.</div>`}
            </div>
          `}

      <div class=${`fus-resolved ${decClass}`}>
        <div class="fus-resolved-h">
          ${dec
            ? html`<span class=${`fus-dec-badge big ${dec.cls}`}>${dec.glyph} ${dec.lbl}</span>`
            : html`<span class="fus-dec-badge big">${run.status === 'failed' ? '실패' : '미결'}</span>`}
          ${run.judge.recommendation?.action
            ? html`<span class="fus-rec-action">권고 · ${run.judge.recommendation.action}</span>`
            : null}
        </div>
        <div class="fus-resolved-lbl">resolved_answer</div>
        <${FusionResolvedBody} text=${resolved} />
        ${run.judge.recommendation?.rationale
          ? html`<div class="fus-rec-rationale"><span class="k">근거</span><${RichContent} text=${run.judge.recommendation.rationale} previewLimit=${0} /></div>`
          : null}
        ${run.judge.missingInputs.length > 0
          ? html`
              <div class="fus-missing">
                <span class="k">부족한 입력</span>
                <ul>${run.judge.missingInputs.map(item => html`<li key=${item}>${item}</li>`)}</ul>
              </div>
            `
          : null}
      </div>

      ${run.status === 'complete'
        ? html`
            <div class="fus-block">
              <div class="fus-block-lbl">
                결과 도착 · sink
                <span class="fus-sub-note">judge 결론이 키퍼 흐름에 녹는 경로</span>
              </div>
              <div class="fus-sink">
                <div class="fus-sink-tracks">
                  <div class="fus-sink-track">
                    <span class="fus-sink-ico chat">▭</span>
                    <div class="fus-sink-tx">
                      <button
                        type="button"
                        class=${`fus-sink-to ${ringFocusClasses()}`}
                        onClick=${() => navigate('keepers', { keeper: run.keeperName })}
                      >${run.keeperName} chat lane →</button>
                      <span class="fus-sink-d">resolved_answer 1줄 append → 다음 턴 observation · librarian이 memory-os fact로 추출</span>
                    </div>
                  </div>
                  <div class="fus-sink-track">
                    <span class="fus-sink-ico board">▦</span>
                    <div class="fus-sink-tx">
                      <button
                        type="button"
                        class=${`fus-sink-to ${ringFocusClasses()}`}
                        onClick=${() => navigate('board', { post: run.boardPostId })}
                      >보드 포스트 #${run.boardPostId} →</button>
                      <span class="fus-sink-d">패널 N + 심판 종합을 meta_json 증거로 발행 · typed origin으로 run linkage 검증</span>
                      <${FusionSinkLinkageBadge} linkage=${sinkLinkage} />
                    </div>
                  </div>
                  <div class="fus-sink-track">
                    <span class="fus-sink-ico wake">◉</span>
                    <div class="fus-sink-tx">
                      <span class="fus-sink-to static">키퍼 wake · Fusion_completed</span>
                      <span class="fus-sink-d">RFC-0266 typed stimulus로 호출 키퍼를 깨워 결론을 actionable 입력으로 전달</span>
                    </div>
                  </div>
                </div>
                <div
                  class="fus-corr"
                  data-testid="fusion-sink-correlation"
                  data-meta-run-id=${run.runId}
                  data-origin-source=${run.boardOriginSource ?? ''}
                  data-origin-run-id=${run.boardOriginRunId ?? ''}
                >
                  correlation · meta <span class="mono">${run.runId}</span>
                  <span class="fus-corr-sep">/</span>
                  origin <span class="mono">${run.boardOriginRunId ?? 'unverified'}</span>
                </div>
              </div>
            </div>
          `
        : null}
    </div>
  `
}

// Detail placeholder for a registry-only run: the deliberation is tracked by the
// registry but has not landed a board post, so there is no panel/judge evidence
// to render yet. Shows identity + live/failed status instead of fabricating detail.
function FusionRegistryDetail({ record }: { record: FusionRunRecord }) {
  const status = registryToRunStatus(record.status)
  const tone = fusionRunStatusTone(record.status)
  const keeper = record.keeper || 'system'
  return html`
    <div class="fus-run-scroll" data-testid="fusion-registry-detail">
      <div class="fus-run-head">
        <div class="fus-run-id-row">
          <${FusionStatusGlyph} status=${status} />
          <h1 class="mono">${record.runId}</h1>
          ${record.preset
            ? html`<span class="fus-preset" title="runtime.toml [fusion.presets.*]">preset · ${record.preset}</span>`
            : null}
          <span class=${`fus-status tone-${tone}`}>${fusionRunStatusText(record.status)}</span>
        </div>
        <div class="fus-run-by">
          <${FusionKeeperLink} keeper=${keeper} size="md" />
          <span class="fus-run-meta"><${TimeAgo} timestamp=${record.startedAt} mode="both" /></span>
        </div>
      </div>

      <div class="fus-block">
        <div class="fus-block-lbl" title="GET /api/v1/dashboard/fusion-runs">
          레지스트리 관측
        </div>
        <div class="fus-judge-wait">
          ${record.status === 'running'
            ? html`<span class="fus-rdot run"></span>심의 진행 중 — 패널·심판 상세는 fusion sink가 <code>meta.source = "fusion"</code> 보드 포스트를 기록한 뒤 이 자리에 나타납니다.`
            : record.status === 'failed'
              ? html`실패로 종료됨.${record.failureCode ? html` <span class="mono">${record.failureCode}</span>` : null}${record.error ? html` · ${record.error}` : null}`
              : '완료됨 — 보드 sink 기록을 기다리는 중입니다.'}
        </div>
      </div>
    </div>
  `
}

export function FusionSurface() {
  const posts = fusionBoardPosts.value
  const runs = useMemo(() => buildFusionRuns(posts), [posts])
  const registryRuns = fusionRuns.value
  const merged = useMemo(() => buildMergedRuns(runs, registryRuns), [runs, registryRuns])
  const boardError = fusionBoardError.value
  const selectedRunId = route.value.params.run_id ?? route.value.params.run
  // A registry-only record proves lifecycle state, but it cannot populate the
  // panel/judge evidence workspace. Without an explicit routed selection,
  // open the newest board-backed run so the default detail pane is useful;
  // registry rows remain selectable and keep their honest sparse detail.
  const selected = merged.find(run => run.runId === selectedRunId)
    ?? merged.find(run => run.kind === 'board')
    ?? merged[0]
    ?? null
  const registryRunning = registryRuns.filter(run => run.status === 'running').length
  const registryFailed = registryRuns.filter(run => run.status === 'failed').length
  // Paged master list (38-bug campaign #34): render a page of rows instead of
  // the full history. The page grows by FUSION_LIST_PAGE_SIZE on demand and
  // always extends far enough to include the routed selection so the active
  // row never disappears from the list.
  const [visibleCount, setVisibleCount] = useState(FUSION_LIST_PAGE_SIZE)
  const selectedIndex = selected
    ? merged.findIndex(run => run.runId === selected.runId)
    : -1
  const effectiveCount = Math.max(visibleCount, selectedIndex + 1)
  const visibleRuns = merged.slice(0, effectiveCount)
  const hiddenCount = merged.length - visibleRuns.length

  return html`
    <main class="surf fus v2-fusion-surface" data-testid="fusion-surface" data-screen-label="Fusion">
      <div class="fus-reality-notice" data-testid="fusion-reality-notice" role="status">
        <strong>부분 지원</strong>
        <span>보드 sink + registry 관측 · live JoJ judges 미구성 시 fail-closed</span>
      </div>
      ${boardError
        ? html`<div
            class="fus-board-error"
            data-testid="fusion-board-error"
            data-board-source="/api/v1/dashboard/board"
            data-board-sort="recent"
            data-board-limit="500"
            role="alert"
          >
            <span class="fus-board-error-k">Board sink load failed</span>
            <span class="fus-board-error-v">${boardError}</span>
          </div>`
        : null}

      <div class="fus-body">
        <aside class="fus-list" aria-label="Fusion runs">
          <div class="fus-list-h">
            <h4>심의 런</h4>
            <span class="fus-list-sub">${merged.length}</span>
            <span class="sr-only">보드 런 ${runs.length} · 레지스트리 ${registryRuns.length} · 실패 ${registryFailed}</span>
            ${registryRunning > 0
              ? html`<span class="fus-list-live"><span class="fus-rdot run"></span>${registryRunning} 진행</span>`
              : null}
            <span
              class="fus-list-truth"
              title="보드 sink와 registry 관측을 표시합니다. live JoJ는 judges 패널 구성이 없으면 fail-closed 상태로 남습니다."
            >관측</span>
            <button
              type="button"
              class=${`fus-list-refresh fus-refresh ${ringFocusClasses()}`}
              aria-label="Fusion 새로고침"
              title="Fusion 새로고침"
              onClick=${() => { void refreshFusionBoard(); void refreshFusionRuns() }}
              disabled=${fusionBoardLoading.value || fusionRunsLoading.value}
            >
              ${fusionBoardLoading.value || fusionRunsLoading.value
                ? html`<span aria-hidden="true">…</span><span class="sr-only">Refreshing...</span>`
                : '↻'}
            </button>
          </div>
          ${merged.length === 0
            ? html`<div class="fus-list-scroll"><div class="ov-empty">심의 런이 없습니다</div></div>`
            : html`
                <div class="fus-list-scroll">
                  ${visibleRuns.map(run => run.kind === 'board'
                    ? html`<${FusionRunRow}
                        key=${run.runId}
                        run=${run.view}
                        active=${selected?.runId === run.runId}
                      />`
                    : html`<${FusionRegistryRow}
                        key=${run.runId}
                        record=${run.record}
                        active=${selected?.runId === run.runId}
                      />`)}
                  ${hiddenCount > 0
                    ? html`<button
                        type="button"
                        class=${`fus-link inline fus-list-more ${ringFocusClasses()}`}
                        data-testid="fusion-list-more"
                        onClick=${() =>
                          // Grow from what is actually rendered, not the
                          // latch: after a deep link auto-extends the list
                          // (effectiveCount >> visibleCount), growing the
                          // latch alone would make the first clicks no-ops.
                          setVisibleCount(effectiveCount + FUSION_LIST_PAGE_SIZE)}
                      >더 보기 (${hiddenCount}개 남음)</button>`
                    : null}
                </div>
              `}
        </aside>

        ${merged.length === 0
          ? html`
              <div class="fus-run-scroll" data-testid="fusion-empty">
                <div class="fus-block">
                  <div class="fus-block-lbl">${boardError ? '보드 sink 확인 실패' : '보드 sink 대기'}</div>
                  <div class="fus-judge-wait">
                    ${boardError ? '보드 심의 기록을 확인하지 못했습니다.' : '아직 기록된 보드 심의가 없습니다.'}
                  </div>
                  <p class="fus-rec-rationale">
                    ${boardError
                      ? html`보드 sink read path(<code>${'/api/v1/dashboard/board?sort_by=recent&limit=500'}</code>)가 실패했습니다. registry 관측(<code>/api/v1/dashboard/fusion-runs</code>)은 독립 소스이며, 캐시된 보드 sink 행만 상세 리뷰에 표시됩니다.`
                      : html`레지스트리 관측(<code>/api/v1/dashboard/fusion-runs</code>)은 상단 KPI에 집계되고, 진행 중 런은 왼쪽 목록에 표시됩니다.
                        상세한 패널·심판 리뷰는 fusion sink가 <code>meta.source = "fusion"</code> 보드 포스트를 기록한 뒤 나타납니다.`}
                  </p>
                </div>
              </div>
            `
          : selected
            ? (selected.kind === 'board'
                ? html`<${FusionRunDetail} run=${selected.view} />`
                : html`<${FusionRegistryDetail} record=${selected.record} />`)
            : null}
      </div>
    </main>
  `
}
