import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import {
  AlertTriangle,
  ClipboardCheck,
  FileText,
  GitCompareArrows,
  RefreshCw,
  Route,
  Send,
} from 'lucide-preact'
import { fetchDashboardPrompts, type DashboardPromptItem, type PromptSource } from '../api'
import { ActionButton } from './common/button'
import { ErrorState } from './common/feedback-state'
import { StatusChip, type StatusChipTone } from './common/status-chip'
import { errorToString } from '../lib/format-string'

type AssemblyLane =
  | 'registry'
  | 'system_prompt'
  | 'user_message'
  | 'extra_system_context'
  | 'oas_hook'
  | 'manifest'

type WarningSeverity = 'critical' | 'warn' | 'info'
type AssemblyStageRole = 'source_prep' | 'model_input' | 'evidence'

interface AssemblyStageSpec {
  id: string
  order: number
  title: string
  lane: AssemblyLane
  role: AssemblyStageRole
  messageSlot: string
  summary: string
  promptKeys: string[]
}

export interface KeeperPromptAssemblyRow {
  id: string
  order: number
  title: string
  lane: AssemblyLane
  promptKey: string
  source: PromptSource | 'computed'
  hasOverride: boolean
  filePath: string | null
  bytes: number
  estimatedTokens: number
  fingerprint: string
  missing: boolean
}

export interface KeeperPromptAssemblyWarning {
  id: string
  severity: WarningSeverity
  title: string
  detail: string
  promptKeys: string[]
  expected: string
}

export interface KeeperPromptAssemblyStage {
  id: string
  order: number
  title: string
  lane: AssemblyLane
  role: AssemblyStageRole
  messageSlot: string
  summary: string
  rows: KeeperPromptAssemblyRow[]
  promptCount: number
  bytes: number
  estimatedTokens: number
  overrideCount: number
  missingCount: number
}

export interface KeeperPromptAssemblyReport {
  rows: KeeperPromptAssemblyRow[]
  stages: KeeperPromptAssemblyStage[]
  warnings: KeeperPromptAssemblyWarning[]
  activePromptRoots: string[]
  stats: {
    totalRows: number
    overrideRows: number
    missingRows: number
    warningCount: number
    criticalCount: number
    promptBytes: number
    estimatedTokens: number
  }
}

const STAGES: AssemblyStageSpec[] = [
  {
    id: 'registry-bootstrap',
    order: 1,
    title: 'Prompt sources',
    lane: 'registry',
    role: 'source_prep',
    messageSlot: 'not sent',
    summary: 'MASC picks the active text from defaults, files, or saved edits.',
    promptKeys: ['keeper.world', 'keeper.capabilities', 'keeper.unified.system'],
  },
  {
    id: 'base-system',
    order: 2,
    title: 'System rules',
    lane: 'system_prompt',
    role: 'model_input',
    messageSlot: 'system',
    summary: 'Identity, rules, and safety boundaries.',
    promptKeys: [
      'keeper.constitution',
      'keeper.world',
      'keeper.capabilities',
      'keeper.recovery_block',
    ],
  },
  {
    id: 'unified-world',
    order: 3,
    title: 'World message',
    lane: 'user_message',
    role: 'model_input',
    messageSlot: 'user',
    summary: 'Current task, workspace state, and turn intent.',
    promptKeys: [
      'keeper.unified.system',
      'keeper.turn_intent',
      'keeper.turn_intent.claim_guidance_a',
      'keeper.turn_intent.claim_guidance_b',
      'keeper.turn_intent.board_activity_guidance',
      'keeper.turn_intent.board_post_guidance',
      'keeper.turn_intent.board_curation_guidance',
      'keeper.turn_intent.broadcast_guidance',
      'keeper.immediate_task_move',
    ],
  },
  {
    id: 'turn-soft-context',
    order: 4,
    title: 'Turn context',
    lane: 'extra_system_context',
    role: 'model_input',
    messageSlot: 'context',
    summary: 'Recent continuity and memory hints.',
    promptKeys: ['keeper.reply_guidelines'],
  },
  {
    id: 'oas-hook',
    order: 5,
    title: 'Provider handoff',
    lane: 'oas_hook',
    role: 'model_input',
    messageSlot: 'provider',
    summary: 'Provider-specific recall and tool hints before send.',
    promptKeys: [
      'keeper.memory_os_recall.context',
      'keeper.memory_os_recall.facts_section',
      'keeper.memory_os_recall.episodes_section',
      'keeper.tool_preferred_header',
      'keeper.tool_preferred_empty',
      'keeper.tool_unknown_guard',
    ],
  },
  {
    id: 'manifest-edge',
    order: 6,
    title: 'Audit trail',
    lane: 'manifest',
    role: 'evidence',
    messageSlot: 'not sent',
    summary: 'Stored after the request is assembled for inspection.',
    promptKeys: [],
  },
]

const STALE_RULES: Array<{
  id: string
  severity: WarningSeverity
  title: string
  pattern: RegExp
  expected: string
}> = [
  {
    id: 'retired-board-get',
    severity: 'critical',
    title: 'Retired board read alias',
    pattern: /\bkeeper_board_get\b/,
    expected: 'Use keeper_board_post_get with an exact post_id.',
  },
  {
    id: 'task-done-notes',
    severity: 'critical',
    title: 'Stale keeper_task_done argument',
    pattern: /keeper_task_done[\s\S]{0,120}\bnotes\b/,
    expected: 'Use keeper_task_done with task_id and result evidence.',
  },
  {
    id: 'keeper-pr-create',
    severity: 'warn',
    title: 'Conflicting keeper-native PR creation guidance',
    pattern: /\bkeeper_pr_create\b/,
    expected: 'Use the current repo-hosting workflow exposed by active tool policy.',
  },
  {
    id: 'hardcoded-masc-path',
    severity: 'warn',
    title: 'Hardcoded repo path example',
    pattern: /repos\/masc\//,
    expected: 'Use repos/REPO_NAME/.worktrees/TASK_NAME for task work examples.',
  },
  {
    id: 'playground-path',
    severity: 'warn',
    title: 'Host storage path still visible',
    pattern: /\.masc\/playground\//,
    expected: 'Keep keeper-facing examples sandbox-relative unless a live tool response explicitly returns a host cwd.',
  },
]

const DUPLICATED_TOOL_TERMS = [
  'keeper_task_done',
  'keeper_board_post_get',
  'Execute',
  'repos/REPO_NAME/.worktrees/TASK_NAME',
]

function textByteLength(value: string): number {
  return new TextEncoder().encode(value).length
}

function estimateTokens(value: string): number {
  return Math.ceil(textByteLength(value) / 4)
}

function shortFingerprint(value: string): string {
  let hash = 2166136261
  for (let i = 0; i < value.length; i += 1) {
    hash ^= value.charCodeAt(i)
    hash = Math.imul(hash, 16777619)
  }
  return (hash >>> 0).toString(16).padStart(8, '0')
}

function promptText(prompt: DashboardPromptItem | undefined): string {
  if (!prompt) return ''
  return prompt.effective ?? prompt.file_value ?? prompt.default ?? ''
}

function promptRoot(filePath: string | null): string | null {
  if (!filePath) return null
  const marker = '/prompts/'
  const idx = filePath.indexOf(marker)
  if (idx < 0) return null
  return filePath.slice(0, idx + marker.length - 1)
}

function severityTone(severity: WarningSeverity): StatusChipTone {
  if (severity === 'critical') return 'bad'
  if (severity === 'warn') return 'warn'
  return 'info'
}

function stageRows(rows: KeeperPromptAssemblyRow[], stage: AssemblyStageSpec): KeeperPromptAssemblyRow[] {
  return rows.filter(row => row.order === stage.order)
}

function buildStages(rows: KeeperPromptAssemblyRow[]): KeeperPromptAssemblyStage[] {
  return STAGES.map(stage => {
    const rowsForStage = stageRows(rows, stage)
    const promptCount = rowsForStage.filter(row => row.promptKey !== '(computed)').length
    return {
      id: stage.id,
      order: stage.order,
      title: stage.title,
      lane: stage.lane,
      role: stage.role,
      messageSlot: stage.messageSlot,
      summary: stage.summary,
      rows: rowsForStage,
      promptCount,
      bytes: rowsForStage.reduce((sum, row) => sum + row.bytes, 0),
      estimatedTokens: rowsForStage.reduce((sum, row) => sum + row.estimatedTokens, 0),
      overrideCount: rowsForStage.filter(row => row.hasOverride).length,
      missingCount: rowsForStage.filter(row => row.missing).length,
    }
  })
}

export function buildKeeperPromptAssemblyReport(
  prompts: DashboardPromptItem[],
): KeeperPromptAssemblyReport {
  const promptByKey = new Map(prompts.map(prompt => [prompt.key, prompt]))
  const rows: KeeperPromptAssemblyRow[] = []

  for (const stage of STAGES) {
    if (stage.promptKeys.length === 0) {
      rows.push({
        id: `${stage.id}:computed`,
        order: stage.order,
        title: stage.title,
        lane: stage.lane,
        promptKey: '(computed)',
        source: 'computed',
        hasOverride: false,
        filePath: null,
        bytes: 0,
        estimatedTokens: 0,
        fingerprint: '-',
        missing: false,
      })
      continue
    }

    for (const promptKey of stage.promptKeys) {
      const prompt = promptByKey.get(promptKey)
      const text = promptText(prompt)
      rows.push({
        id: `${stage.id}:${promptKey}`,
        order: stage.order,
        title: stage.title,
        lane: stage.lane,
        promptKey,
        source: prompt?.source ?? 'missing',
        hasOverride: prompt?.has_override ?? false,
        filePath: prompt?.file_path ?? null,
        bytes: textByteLength(text),
        estimatedTokens: estimateTokens(text),
        fingerprint: text ? shortFingerprint(text) : '-',
        missing: !prompt || prompt.source === 'missing',
      })
    }
  }

  const keeperPrompts = prompts.filter(prompt =>
    prompt.key.startsWith('keeper.') || prompt.key.startsWith('behavior.'),
  )
  const warnings: KeeperPromptAssemblyWarning[] = []

  for (const rule of STALE_RULES) {
    const hits = keeperPrompts
      .filter(prompt => rule.pattern.test(promptText(prompt)))
      .map(prompt => prompt.key)
      .sort()
    if (hits.length === 0) continue
    warnings.push({
      id: rule.id,
      severity: rule.severity,
      title: rule.title,
      detail: `${hits.length} prompt(s) need cleanup.`,
      promptKeys: hits,
      expected: rule.expected,
    })
  }

  for (const term of DUPLICATED_TOOL_TERMS) {
    const hits = keeperPrompts
      .filter(prompt => promptText(prompt).includes(term))
      .map(prompt => prompt.key)
      .sort()
    if (hits.length <= 2) continue
    warnings.push({
      id: `duplicate:${term}`,
      severity: 'info',
      title: `Duplicated tool guidance: ${term}`,
      detail: `${term} appears across ${hits.length} Keeper/behavior prompts.`,
      promptKeys: hits,
      expected: 'Keep generic tool grammar in one canonical prompt and leave persona/runtime files to add only local policy.',
    })
  }

  const activePromptRoots = Array.from(
    new Set(
      prompts
        .map(prompt => promptRoot(prompt.file_path))
        .filter((value): value is string => Boolean(value)),
    ),
  ).sort()

  const promptBytes = rows.reduce((sum, row) => sum + row.bytes, 0)
  const estimatedTokens = rows.reduce((sum, row) => sum + row.estimatedTokens, 0)
  const criticalCount = warnings.filter(warning => warning.severity === 'critical').length
  const stages = buildStages(rows)

  return {
    rows,
    stages,
    warnings,
    activePromptRoots,
    stats: {
      totalRows: rows.length,
      overrideRows: rows.filter(row => row.hasOverride).length,
      missingRows: rows.filter(row => row.missing).length,
      warningCount: warnings.length,
      criticalCount,
      promptBytes,
      estimatedTokens,
    },
  }
}

function formatBytes(bytes: number): string {
  if (bytes <= 0) return '-'
  if (bytes < 1024) return `${bytes} B`
  return `${(bytes / 1024).toFixed(1)} KiB`
}

function sourceTone(row: KeeperPromptAssemblyRow): StatusChipTone {
  if (row.missing) return 'bad'
  if (row.hasOverride) return 'warn'
  if (row.source === 'file') return 'ok'
  if (row.source === 'computed') return 'neutral'
  return 'info'
}

function stageAttention(stage: KeeperPromptAssemblyStage): { tone: StatusChipTone; label: string; note: string } | null {
  if (stage.missingCount > 0) {
    return { tone: 'bad', label: 'needs setup', note: 'Needs setup before it can be sent.' }
  }
  if (stage.overrideCount > 0) {
    return { tone: 'warn', label: 'edited', note: 'Saved edits are included.' }
  }
  return null
}

function modelInputMicrocopy(stages: KeeperPromptAssemblyStage[]): string {
  return `${stages.length} model-visible part${stages.length === 1 ? '' : 's'}`
}

function reportMicrocopy(report: KeeperPromptAssemblyReport): string {
  const modelStages = report.stages.filter(stage => stage.role === 'model_input')
  return modelInputMicrocopy(modelStages)
}

function ModelInputStage({ stage, index }: { stage: KeeperPromptAssemblyStage; index: number }) {
  const messageTone: StatusChipTone = index === 0 ? 'info' : index === 1 ? 'ok' : 'warn'
  const attention = stageAttention(stage)

  return html`
    <li class="min-w-0 border-t border-[var(--color-border-default)] py-3 first:border-t-0 first:pt-0 last:pb-0">
      <div class="mb-1 flex flex-wrap items-center gap-2">
        <span class="text-3xs font-semibold text-[var(--color-fg-disabled)]">${index + 1}</span>
        <${StatusChip} tone=${messageTone} uppercase=${false}>${stage.messageSlot}<//>
        <div class="text-xs font-semibold leading-tight text-[var(--color-fg-primary)]">${stage.title}</div>
        ${attention ? html`<${StatusChip} tone=${attention.tone}>${attention.label}<//>` : null}
      </div>
      <div class="text-2xs leading-relaxed text-[var(--color-fg-muted)]">
        ${stage.summary}
        ${attention ? html`<span class="text-[var(--color-fg-disabled)]"> ${attention.note}</span>` : null}
      </div>
    </li>
  `
}

function SupportStep({
  icon: Icon,
  eyebrow,
  title,
  summary,
}: {
  icon: typeof FileText
  eyebrow: string
  title: string
  summary: string
}) {
  return html`
    <section class="min-w-0 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2.5">
      <div class="mb-2 flex min-w-0 items-center gap-2">
        <${Icon} size=${15} class="shrink-0 text-[var(--color-accent-fg)]" />
        <div class="min-w-0">
          <div class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-disabled)]">${eyebrow}</div>
          <div class="text-sm font-semibold leading-tight text-[var(--color-fg-primary)]">${title}</div>
        </div>
      </div>
      <p class="m-0 text-2xs leading-relaxed text-[var(--color-fg-muted)]">${summary}</p>
    </section>
  `
}

function PromptFlowMap({ stages }: { stages: KeeperPromptAssemblyStage[] }) {
  const modelStages = stages.filter(stage => stage.role === 'model_input')
  const sourceStage = stages.find(stage => stage.role === 'source_prep')
  const auditStage = stages.find(stage => stage.role === 'evidence')

  return html`
    <section data-prompt-route-default class="grid gap-3 lg:grid-cols-[minmax(0,0.85fr)_minmax(0,1.65fr)]">
      <div class="order-2 grid content-start gap-3 lg:order-1">
        <${SupportStep}
          icon=${FileText}
          eyebrow="before send"
          title="Choose source text"
          summary=${sourceStage?.summary ?? 'MASC chooses the active text for this turn.'}
        />
        <${SupportStep}
          icon=${ClipboardCheck}
          eyebrow="after send"
          title="Save audit trail"
          summary=${auditStage?.summary ?? 'The assembled request is stored for inspection.'}
        />
      </div>

      <section class="order-1 min-w-0 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-3 lg:order-2">
        <div class="mb-2 grid gap-1 sm:flex sm:min-w-0 sm:items-center sm:justify-between sm:gap-3">
          <div class="flex min-w-0 items-center gap-2">
            <${Send} size=${15} class="shrink-0 text-[var(--color-accent-fg)]" />
            <div class="min-w-0">
              <div class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-disabled)]">model sees</div>
              <div class="text-sm font-semibold leading-tight text-[var(--color-fg-primary)]">Model request</div>
            </div>
          </div>
          <span class="pl-7 text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-disabled)] sm:shrink-0 sm:pl-0">${modelInputMicrocopy(modelStages)}</span>
        </div>
        <p class="m-0 text-2xs leading-relaxed text-[var(--color-fg-muted)]">
          Only these ordered parts leave MASC for the model.
        </p>
        <ol class="mt-3">
          ${modelStages.map((stage, index) => html`
            <${ModelInputStage} key=${stage.id} stage=${stage} index=${index} />
          `)}
        </ol>
      </section>
    </section>
  `
}

function CleanupDetails({ warnings }: { warnings: KeeperPromptAssemblyWarning[] }) {
  if (warnings.length === 0) return null

  const hasCritical = warnings.some(warning => warning.severity === 'critical')

  return html`
    <details data-prompt-quality-checks class="mt-3 rounded-[var(--r-1)] border ${hasCritical ? 'border-[var(--bad-20)] bg-[var(--bad-8)]' : 'border-[var(--color-border-default)] bg-[var(--color-bg-surface)]'}">
      <summary class="flex cursor-pointer list-none items-center justify-between gap-3 px-3 py-2">
        <span class="flex items-center gap-2 text-xs font-semibold text-[var(--color-fg-primary)]">
          ${hasCritical ? html`<${AlertTriangle} size=${14} />` : null}
          Prompt quality checks
        </span>
        <span class="flex items-center gap-2">
          <${StatusChip} tone=${hasCritical ? 'bad' : 'neutral'}>
            ${warnings.length} finding${warnings.length === 1 ? '' : 's'}
          <//>
        </span>
      </summary>
      <div class="grid gap-2 border-t border-[var(--color-border-default)] p-3">
        ${warnings.map(warning => html`
          <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2">
            <div class="mb-1 flex flex-wrap items-center gap-2">
              <span class="text-xs font-semibold text-[var(--color-fg-primary)]">${warning.title}</span>
              <${StatusChip} tone=${severityTone(warning.severity)}>${warning.severity}<//>
            </div>
            <div class="text-2xs leading-relaxed text-[var(--color-fg-muted)]">${warning.detail} ${warning.expected}</div>
            <div class="mt-2 flex flex-wrap gap-1">
              ${warning.promptKeys.map(key => html`
                <span class="rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-1.5 py-0.5 font-mono text-3xs text-[var(--color-fg-secondary)]">${key}</span>
              `)}
            </div>
          </div>
        `)}
      </div>
    </details>
  `
}

function SourceEvidenceDetails({ report, compact }: { report: KeeperPromptAssemblyReport; compact: boolean }) {
  if (compact) return null

  return html`
    <details data-developer-evidence class="mt-3 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)]">
      <summary class="flex cursor-pointer list-none items-center justify-between gap-3 px-3 py-2">
        <span class="flex items-center gap-2 text-xs font-semibold text-[var(--color-fg-primary)]">
          <${GitCompareArrows} size=${14} />
          Technical trace
        </span>
        <span class="text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-disabled)]">hidden by default</span>
      </summary>
      <div class="border-t border-[var(--color-border-default)] p-3">
        ${report.activePromptRoots.length > 0 ? html`
          <div class="mb-3 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-3 py-2">
            <div class="mb-1 text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-disabled)]">active prompt root</div>
            ${report.activePromptRoots.map(root => html`
              <code class="block break-all text-2xs text-[var(--color-fg-secondary)]">${root}</code>
            `)}
          </div>
        ` : null}
        <div class="overflow-x-auto rounded-[var(--r-1)] border border-[var(--color-border-default)]">
          <table class="min-w-[860px] w-full border-collapse text-left text-2xs">
            <thead class="bg-[var(--color-bg-elevated)] text-[var(--color-fg-muted)]">
              <tr>
                <th class="px-3 py-2 font-semibold uppercase tracking-[var(--track-caps)]">step</th>
                <th class="px-3 py-2 font-semibold uppercase tracking-[var(--track-caps)]">prompt</th>
                <th class="px-3 py-2 font-semibold uppercase tracking-[var(--track-caps)]">source</th>
                <th class="px-3 py-2 font-semibold uppercase tracking-[var(--track-caps)]">weight</th>
                <th class="px-3 py-2 font-semibold uppercase tracking-[var(--track-caps)]">fingerprint</th>
              </tr>
            </thead>
            <tbody>
              ${report.rows.map(row => html`
                <tr class="border-t border-[var(--color-border-default)] ${row.hasOverride
                  ? 'bg-[var(--warn-8)]'
                  : row.missing
                    ? 'bg-[var(--bad-8)]'
                    : ''}">
                  <td class="px-3 py-2 align-top">
                    <div class="font-mono text-[var(--color-fg-disabled)]">#${row.order}</div>
                    <div class="text-xs font-medium text-[var(--color-fg-primary)]">${row.title}</div>
                  </td>
                  <td class="px-3 py-2 align-top">
                    <div class="font-mono text-xs text-[var(--color-fg-secondary)]">${row.promptKey}</div>
                    ${row.filePath ? html`<div class="mt-1 max-w-[320px] truncate font-mono text-3xs text-[var(--color-fg-disabled)]" title=${row.filePath}>${row.filePath}</div>` : null}
                  </td>
                  <td class="px-3 py-2 align-top">
                    <div class="flex flex-wrap gap-1">
                      <${StatusChip} tone=${sourceTone(row)}>${row.source}<//>
                      ${row.hasOverride ? html`<${StatusChip} tone="warn">override<//>` : null}
                    </div>
                  </td>
                  <td class="px-3 py-2 align-top font-mono text-xs text-[var(--color-fg-secondary)]">
                    <div>${formatBytes(row.bytes)}</div>
                    <div class="text-3xs text-[var(--color-fg-disabled)]">${row.estimatedTokens ? `${row.estimatedTokens.toLocaleString()} tok est` : '-'}</div>
                  </td>
                  <td class="px-3 py-2 align-top font-mono text-xs text-[var(--color-fg-secondary)]">${row.fingerprint}</td>
                </tr>
              `)}
            </tbody>
          </table>
        </div>
      </div>
    </details>
  `
}

function PromptAssemblyContent({ report, compact = false }: { report: KeeperPromptAssemblyReport; compact?: boolean }) {
  return html`
    <div
      class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] p-4"
    >
      <div class="mb-4 border-b border-[var(--color-border-default)] pb-3">
        <div class="max-w-4xl">
          <div class="mb-1 flex flex-wrap items-center gap-2">
            <${Route} size=${16} class="text-[var(--color-accent-fg)]" />
            <h3 class="text-sm font-semibold text-[var(--color-fg-primary)]">Turn prompt recipe</h3>
            <span class="text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-disabled)]">${reportMicrocopy(report)}</span>
          </div>
          <p class="m-0 max-w-3xl text-2xs leading-relaxed text-[var(--color-fg-muted)]">
            Default view shows the model-visible order. File paths, hashes, and token estimates stay in Technical trace.
          </p>
        </div>
      </div>

      <${PromptFlowMap} stages=${report.stages} />
      <${CleanupDetails} warnings=${report.warnings} />
      <${SourceEvidenceDetails} report=${report} compact=${compact} />
    </div>
  `
}

export function KeeperPromptAssemblyPanel({
  compact = false,
  prompts: providedPrompts,
}: {
  compact?: boolean
  prompts?: DashboardPromptItem[]
}) {
  const [loadedPrompts, setLoadedPrompts] = useState<DashboardPromptItem[]>([])
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const ownsFetch = providedPrompts == null

  async function load() {
    if (!ownsFetch) return
    setLoading(true)
    setError(null)
    try {
      const response = await fetchDashboardPrompts()
      setLoadedPrompts(response.prompts ?? [])
    } catch (err) {
      setError(errorToString(err))
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => {
    if (ownsFetch) void load()
  }, [ownsFetch])

  const report = buildKeeperPromptAssemblyReport(providedPrompts ?? loadedPrompts)

  return html`
    <div class="mb-5 pb-24 lg:pb-0" data-keeper-prompt-assembly-panel>
      <div class="mb-2 flex items-center justify-between gap-3">
        <div class="flex items-center gap-2">
          <span class="text-2xs font-semibold uppercase tracking-wider text-[var(--color-fg-muted)]">Prompt Recipe</span>
          ${loading ? html`<${StatusChip} tone="info">loading<//>` : null}
        </div>
        ${ownsFetch ? html`
          <${ActionButton} variant="ghost" size="sm" disabled=${loading} onClick=${() => { void load() }}>
            <${RefreshCw} size=${12} />
            ${loading ? '새로고침 중' : '새로고침'}
          <//>
        ` : null}
      </div>
      ${error ? html`<${ErrorState} message=${error} class="mb-3" />` : null}
      <${PromptAssemblyContent} report=${report} compact=${compact} />
    </div>
  `
}
