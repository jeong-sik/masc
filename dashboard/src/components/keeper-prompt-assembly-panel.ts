import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import {
  AlertTriangle,
  BookOpenText,
  Brain,
  FileText,
  GitCompareArrows,
  Map as MapIcon,
  RefreshCw,
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

interface AssemblyComputedRowSpec {
  id: string
  promptKey: string
}

interface AssemblyStageSpec {
  id: string
  order: number
  title: string
  lane: AssemblyLane
  role: AssemblyStageRole
  messageSlot: string
  summary: string
  promptKeys: string[]
  computedRows?: AssemblyComputedRowSpec[]
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
  text: string
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

export interface KeeperPromptAssemblyPreset {
  id: string
  label: string
  description: string
  count: number
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
    summary: 'Current task, workspace state, scheduler signals, and turn intent.',
    promptKeys: [
      'keeper.unified.system',
      'keeper.turn_intent',
      'keeper.immediate_task_move',
    ],
    computedRows: [
      { id: 'world-observation', promptKey: '(computed:world_observation)' },
      { id: 'scheduled-automation', promptKey: '(computed:scheduled_automation)' },
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
    title: 'Final context',
    lane: 'oas_hook',
    role: 'model_input',
    messageSlot: 'final',
    summary: 'Memory and tool hints added at the end.',
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

function promptDisplayText(row: KeeperPromptAssemblyRow): string {
  if (row.text) return row.text
  if (row.source === 'computed') return 'Computed at turn time from workspace, scheduler, memory, and runtime state.'
  if (row.missing) return 'Required prompt file is missing from the active prompt root.'
  return 'No effective text is currently resolved for this prompt.'
}

function sourceLabel(source: KeeperPromptAssemblyRow['source']): string {
  if (source === 'computed') return 'computed'
  if (source === 'override') return 'saved override'
  if (source === 'file') return 'prompt file'
  if (source === 'default') return 'default'
  return 'missing'
}

function messageSlotLabel(stage: KeeperPromptAssemblyStage): string {
  if (stage.messageSlot === 'not sent') return 'not sent'
  return `${stage.messageSlot} message`
}

function stageRoleLabel(stage: KeeperPromptAssemblyStage): string {
  if (stage.role === 'source_prep') return 'source preparation'
  if (stage.role === 'evidence') return 'audit evidence'
  return 'model input'
}

function stagePurpose(stage: KeeperPromptAssemblyStage): string {
  if (stage.role === 'model_input') return 'Keeper sees this'
  if (stage.role === 'source_prep') return 'chooses source text'
  return 'kept for recap'
}

function stageAccentClass(stage: KeeperPromptAssemblyStage): string {
  switch (stage.lane) {
    case 'registry':
      return 'border-l-[var(--info)] bg-[rgba(106,142,176,0.10)] text-[#48647a]'
    case 'system_prompt':
      return 'border-l-[#8e63a9] bg-[rgba(142,99,169,0.12)] text-[#6f4b88]'
    case 'user_message':
      return 'border-l-[var(--ok)] bg-[rgba(107,158,107,0.12)] text-[#486f48]'
    case 'extra_system_context':
      return 'border-l-[var(--warn)] bg-[rgba(201,162,74,0.14)] text-[#806331]'
    case 'oas_hook':
      return 'border-l-[#ba5b65] bg-[rgba(196,106,90,0.13)] text-[#87444b]'
    case 'manifest':
      return 'border-l-[var(--color-border-strong)] bg-[rgba(44,40,34,0.08)] text-[#6a5c4a]'
    default:
      return 'border-l-[var(--color-border-default)] bg-[rgba(44,40,34,0.08)] text-[#6a5c4a]'
  }
}

function stageDotClass(stage: KeeperPromptAssemblyStage): string {
  switch (stage.lane) {
    case 'registry':
      return 'bg-[var(--info)]'
    case 'system_prompt':
      return 'bg-[#8e63a9]'
    case 'user_message':
      return 'bg-[var(--ok)]'
    case 'extra_system_context':
      return 'bg-[var(--warn)]'
    case 'oas_hook':
      return 'bg-[#ba5b65]'
    case 'manifest':
      return 'bg-[var(--color-border-strong)]'
    default:
      return 'bg-[var(--color-border-default)]'
  }
}

function stagePresetId(stage: KeeperPromptAssemblyStage): string {
  return `stage:${stage.id}`
}

function isStagePreset(id: string): boolean {
  return id.startsWith('stage:')
}

function stageIdFromPreset(id: string): string | null {
  return isStagePreset(id) ? id.slice('stage:'.length) : null
}

function assemblyPresetOptions(report: KeeperPromptAssemblyReport): KeeperPromptAssemblyPreset[] {
  const stagePresets = report.stages
    .filter(stage => stage.rows.some(row => row.source !== 'computed'))
    .map(stage => ({
      id: stagePresetId(stage),
      label: stage.messageSlot === 'not sent' ? stage.title : `${stage.messageSlot}: ${stage.title}`,
      description: stage.summary,
      count: stage.rows.filter(row => row.source !== 'computed').length,
    }))

  return [
    {
      id: 'all',
      label: '전체',
      description: 'Full prompt world and assembly trail.',
      count: report.stats.totalRows,
    },
    ...stagePresets,
    {
      id: 'attention',
      label: '수정/누락',
      description: 'Saved overrides and missing required prompt files.',
      count: report.stats.overrideRows + report.stats.missingRows,
    },
  ]
}

function rowsForPreset(stage: KeeperPromptAssemblyStage, activePreset: string): KeeperPromptAssemblyRow[] {
  if (activePreset === 'attention') {
    return stage.rows.filter(row => row.hasOverride || row.missing)
  }
  return stage.rows
}

function stagesForPreset(report: KeeperPromptAssemblyReport, activePreset: string): KeeperPromptAssemblyStage[] {
  const stageId = stageIdFromPreset(activePreset)
  if (stageId) return report.stages.filter(stage => stage.id === stageId)
  if (activePreset === 'attention') {
    const attentionStages = report.stages.filter(stage => rowsForPreset(stage, activePreset).length > 0)
    return attentionStages.length > 0 ? attentionStages : report.stages
  }
  return report.stages
}

function stageBytesForPreset(stage: KeeperPromptAssemblyStage, activePreset: string): number {
  return rowsForPreset(stage, activePreset).reduce((sum, row) => sum + row.bytes, 0)
}

function stageTokensForPreset(stage: KeeperPromptAssemblyStage, activePreset: string): number {
  return rowsForPreset(stage, activePreset).reduce((sum, row) => sum + row.estimatedTokens, 0)
}

function presetStats(stages: KeeperPromptAssemblyStage[], activePreset: string) {
  const rows = stages.flatMap(stage => rowsForPreset(stage, activePreset))
  return {
    rows,
    bytes: rows.reduce((sum, row) => sum + row.bytes, 0),
    estimatedTokens: rows.reduce((sum, row) => sum + row.estimatedTokens, 0),
    overrides: rows.filter(row => row.hasOverride).length,
    missing: rows.filter(row => row.missing).length,
  }
}

function minimapHeight(stage: KeeperPromptAssemblyStage, activePreset: string, largest: number): string {
  const tokens = stageTokensForPreset(stage, activePreset)
  const ratio = largest > 0 ? tokens / largest : 0.2
  const px = Math.max(28, Math.round(28 + ratio * 76))
  return `${px}px`
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
    const promptCount = rowsForStage.filter(row => row.source !== 'computed').length
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

  function pushComputedRows(stage: AssemblyStageSpec) {
    const computedRows =
      stage.computedRows ?? (stage.promptKeys.length === 0
        ? [{ id: 'computed', promptKey: '(computed)' }]
        : [])

    for (const row of computedRows) {
      rows.push({
        id: `${stage.id}:${row.id}`,
        order: stage.order,
        title: stage.title,
        lane: stage.lane,
        promptKey: row.promptKey,
        source: 'computed',
        hasOverride: false,
        filePath: null,
        text: '',
        bytes: 0,
        estimatedTokens: 0,
        fingerprint: '-',
        missing: false,
      })
    }
  }

  for (const stage of STAGES) {
    if (stage.promptKeys.length === 0) {
      pushComputedRows(stage)
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
        text,
        bytes: textByteLength(text),
        estimatedTokens: estimateTokens(text),
        fingerprint: text ? shortFingerprint(text) : '-',
        missing: !prompt || prompt.source === 'missing',
      })
    }

    pushComputedRows(stage)
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
  return `${stages.length} sent part${stages.length === 1 ? '' : 's'}`
}

function reportMicrocopy(report: KeeperPromptAssemblyReport): string {
  const modelStages = report.stages.filter(stage => stage.role === 'model_input')
  return modelInputMicrocopy(modelStages)
}

interface BuildPathStep {
  id: string
  label: string
  title: string
  summary: string
  chips: string[]
  tone: StatusChipTone
  stages: KeeperPromptAssemblyStage[]
}

function buildPathSteps(report: KeeperPromptAssemblyReport): BuildPathStep[] {
  const sourceStages = report.stages.filter(stage => stage.role === 'source_prep')
  const modelStages = report.stages.filter(stage => stage.role === 'model_input')
  const evidenceStages = report.stages.filter(stage => stage.role === 'evidence')

  return [
    {
      id: 'source-chosen',
      label: '1',
      title: 'Prompt text chosen',
      summary: 'MASC selects the active text from defaults, files, or saved edits.',
      chips: sourceStages.map(stage => stage.title),
      tone: 'neutral',
      stages: sourceStages,
    },
    {
      id: 'sent-to-model',
      label: '2',
      title: 'Sent to model',
      summary: 'Only these ordered request parts leave MASC.',
      chips: modelStages.map(stage => `${stage.messageSlot}: ${stage.title}`),
      tone: 'info',
      stages: modelStages,
    },
    {
      id: 'stored-record',
      label: '3',
      title: 'Stored record',
      summary: 'The audit record is kept for inspection after assembly. It is not sent.',
      chips: evidenceStages.map(stage => stage.title),
      tone: 'neutral',
      stages: evidenceStages,
    },
  ]
}

function BuildPathStepRow({ step }: { step: BuildPathStep }) {
  const overrideCount = step.stages.reduce((sum, stage) => sum + stage.overrideCount, 0)
  const missingCount = step.stages.reduce((sum, stage) => sum + stage.missingCount, 0)

  return html`
    <li class="min-w-0 border-t border-[var(--color-border-default)] py-3 first:border-t-0 first:pt-0 last:pb-0 v2-monitoring-row">
      <div class="mb-1 flex flex-wrap items-center gap-2">
        <${StatusChip} tone=${step.tone} uppercase=${false}>${step.label}<//>
        <div class="text-xs font-semibold text-[var(--color-fg-primary)]">${step.title}</div>
        ${overrideCount > 0 ? html`<${StatusChip} tone="warn">${overrideCount} edited<//>` : null}
        ${missingCount > 0 ? html`<${StatusChip} tone="bad">${missingCount} missing<//>` : null}
      </div>
      <p class="m-0 text-2xs leading-relaxed text-[var(--color-fg-muted)]">${step.summary}</p>
      <div class="mt-2 flex flex-wrap gap-1 v2-monitoring-row">
        ${step.chips.map(chip => html`
          <span class="rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-1.5 py-0.5 text-3xs text-[var(--color-fg-secondary)]">${chip}</span>
        `)}
      </div>
    </li>
  `
}

function PromptPresetControls({
  presets,
  activePreset,
  onSelect,
}: {
  presets: KeeperPromptAssemblyPreset[]
  activePreset: string
  onSelect: (id: string) => void
}) {
  return html`
    <div data-prompt-preset-switcher class="flex min-w-0 flex-wrap gap-1.5">
      ${presets.map(preset => {
        const active = preset.id === activePreset
        return html`
          <button
            type="button"
            class=${`min-h-8 rounded-[var(--r-1)] border px-2.5 py-1.5 text-left transition-colors ${active
              ? 'border-[var(--accent-30)] bg-[var(--accent-15)] text-[var(--color-accent-fg)]'
              : 'border-[var(--color-border-default)] bg-[var(--color-bg-surface)] text-[var(--color-fg-secondary)] hover:border-[var(--accent-22)] hover:bg-[var(--color-bg-elevated)]'}`}
            data-active=${active ? 'true' : 'false'}
            title=${preset.description}
            onClick=${() => onSelect(preset.id)}
          >
            <span class="flex items-center gap-2">
              <span class="text-2xs font-semibold leading-none">${preset.label}</span>
              <span class="rounded-[var(--r-0)] bg-[rgba(255,255,255,0.06)] px-1.5 py-0.5 font-mono text-3xs leading-none">${preset.count}</span>
            </span>
          </button>
        `
      })}
    </div>
  `
}

function CodexMetric({
  label,
  value,
  detail,
  tone = 'neutral',
}: {
  label: string
  value: string
  detail: string
  tone?: StatusChipTone
}) {
  return html`
    <div class="min-w-0 rounded-[var(--r-1)] border border-[rgba(114,97,67,0.34)] bg-[rgba(43,32,21,0.08)] px-3 py-2">
      <div class="mb-1 flex items-center justify-between gap-2">
        <span class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[#7d6a4b]">${label}</span>
        <${StatusChip} tone=${tone} uppercase=${false}>${detail}<//>
      </div>
      <div class="break-words font-mono text-sm font-semibold leading-tight text-[#2b2015]">${value}</div>
    </div>
  `
}

function PromptSourceLine({ row, stage }: { row: KeeperPromptAssemblyRow; stage: KeeperPromptAssemblyStage }) {
  return html`
    <div class="grid gap-1 text-3xs leading-relaxed text-[#6a5a40] sm:grid-cols-[minmax(0,1fr)_auto] sm:items-center">
      <div class="min-w-0">
        <span class="font-semibold uppercase tracking-[var(--track-caps)]">${messageSlotLabel(stage)}</span>
        <span class="mx-1 text-[#9a7a3a]">/</span>
        <span>${stageRoleLabel(stage)}</span>
        <span class="mx-1 text-[#9a7a3a]">/</span>
        <span>${sourceLabel(row.source)}</span>
        ${row.filePath ? html`
          <span class="mx-1 text-[#9a7a3a]">/</span>
          <code class="break-all font-mono text-[#4e3b23]">${row.filePath}</code>
        ` : null}
      </div>
      <div class="flex flex-wrap gap-1 sm:justify-end">
        <span class="rounded-[var(--r-0)] border border-[rgba(114,97,67,0.28)] bg-[rgba(255,255,255,0.24)] px-1.5 py-0.5 font-mono text-[#4e3b23]">bytes ${formatBytes(row.bytes)}</span>
        <span class="rounded-[var(--r-0)] border border-[rgba(114,97,67,0.28)] bg-[rgba(255,255,255,0.24)] px-1.5 py-0.5 font-mono text-[#4e3b23]">tokens ${row.estimatedTokens ? row.estimatedTokens.toLocaleString() : '-'}</span>
        <span class="rounded-[var(--r-0)] border border-[rgba(114,97,67,0.28)] bg-[rgba(255,255,255,0.24)] px-1.5 py-0.5 font-mono text-[#4e3b23]">fingerprint ${row.fingerprint}</span>
      </div>
    </div>
  `
}

function PromptDocumentRow({ row, stage }: { row: KeeperPromptAssemblyRow; stage: KeeperPromptAssemblyStage }) {
  const text = promptDisplayText(row)
  return html`
    <article
      data-prompt-document-row
      class=${`group relative border-l-4 ${stageAccentClass(stage)} rounded-r-[var(--r-1)] border-y border-r border-[rgba(114,97,67,0.24)] bg-clip-padding px-4 py-3 shadow-[0_1px_0_rgba(255,255,255,0.45)_inset]`}
    >
      <div class="mb-2 flex min-w-0 flex-wrap items-center gap-2">
        <span class="flex size-6 shrink-0 items-center justify-center rounded-[var(--r-0)] bg-[rgba(43,32,21,0.10)] font-mono text-3xs font-semibold text-current">
          ${row.order}
        </span>
        <div class="min-w-0">
          <div class="truncate font-mono text-xs font-semibold text-[#2b2015]">${row.promptKey}</div>
          <div class="text-3xs uppercase tracking-[var(--track-caps)] text-[#7d6a4b]">${stage.title}</div>
        </div>
        <div class="ml-auto flex flex-wrap gap-1">
          <${StatusChip} tone=${sourceTone(row)} uppercase=${false}>${sourceLabel(row.source)}<//>
          ${row.hasOverride && row.source !== 'override' ? html`<${StatusChip} tone="warn" uppercase=${false}>edited<//>` : null}
          ${row.missing && row.source !== 'missing' ? html`<${StatusChip} tone="bad" uppercase=${false}>missing<//>` : null}
        </div>
      </div>
      <${PromptSourceLine} row=${row} stage=${stage} />
      <pre
        class="mt-3 max-h-80 overflow-auto whitespace-pre-wrap break-words rounded-[var(--r-1)] border border-[rgba(114,97,67,0.22)] bg-[rgba(255,251,238,0.62)] p-3 font-serif text-sm leading-7 text-[#2b2015] shadow-[0_10px_22px_rgba(43,32,21,0.05)_inset]"
      >${text}</pre>
    </article>
  `
}

function PromptStageDocument({
  stage,
  activePreset,
}: {
  stage: KeeperPromptAssemblyStage
  activePreset: string
}) {
  const rows = rowsForPreset(stage, activePreset)
  const attention = stageAttention(stage)

  return html`
    <section data-prompt-codex-stage=${stage.id} class="scroll-mt-6">
      <div class="mb-3 flex min-w-0 items-start gap-3">
        <span class=${`mt-1 size-3 shrink-0 rounded-full ${stageDotClass(stage)} shadow-[0_0_0_4px_rgba(43,32,21,0.08)]`}></span>
        <div class="min-w-0 flex-1">
          <div class="flex flex-wrap items-center gap-2">
            <h4 class="m-0 text-lg font-semibold leading-tight" style=${{ color: '#2b2015', textTransform: 'none' }}>${stage.title}</h4>
            <${StatusChip} tone=${stage.role === 'model_input' ? 'info' : 'neutral'} uppercase=${false}>${stagePurpose(stage)}<//>
            ${attention ? html`<${StatusChip} tone=${attention.tone} uppercase=${false}>${attention.label}<//>` : null}
          </div>
          <p class="m-0 mt-1 text-sm leading-relaxed" style=${{ color: '#6a5a40' }}>${stage.summary}</p>
        </div>
        <div class="hidden shrink-0 text-right font-mono text-2xs text-[#6a5a40] sm:block">
          <div>${formatBytes(stageBytesForPreset(stage, activePreset))}</div>
          <div>${stageTokensForPreset(stage, activePreset).toLocaleString()} tok est</div>
        </div>
      </div>
      <div class="grid gap-3">
        ${rows.map(row => html`
          <${PromptDocumentRow} key=${row.id} row=${row} stage=${stage} />
        `)}
      </div>
    </section>
  `
}

function PromptCodexMinimap({
  stages,
  activePreset,
  selectedPreset,
  onSelectPreset,
}: {
  stages: KeeperPromptAssemblyStage[]
  activePreset: string
  selectedPreset: string
  onSelectPreset: (id: string) => void
}) {
  const largest = Math.max(...stages.map(stage => stageTokensForPreset(stage, activePreset)), 0)

  return html`
    <aside data-prompt-minimap class="min-w-0 rounded-[var(--r-1)] border border-[rgba(201,162,74,0.24)] bg-[rgba(11,10,8,0.42)] p-3">
      <div class="mb-3 flex items-center gap-2">
        <${MapIcon} size=${14} class="text-[var(--color-accent-fg)]" />
        <div>
          <div class="text-xs font-semibold text-[var(--color-fg-primary)]">Recap minimap</div>
          <div class="text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-disabled)]">source map</div>
        </div>
      </div>
      <div class="grid gap-2">
        ${stages.map(stage => {
          const stagePreset = stagePresetId(stage)
          const selected = selectedPreset === stagePreset
          return html`
            <button
              type="button"
              class=${`grid min-w-0 grid-cols-[10px_minmax(0,1fr)] gap-2 rounded-[var(--r-1)] border p-2 text-left transition-colors ${selected
                ? 'border-[var(--accent-30)] bg-[var(--accent-12)]'
                : 'border-[var(--color-border-default)] bg-[rgba(255,255,255,0.03)] hover:border-[var(--accent-22)] hover:bg-[var(--color-bg-elevated)]'}`}
              onClick=${() => onSelectPreset(stagePreset)}
            >
              <span class=${`block w-2 rounded-full ${stageDotClass(stage)}`} style=${{ height: minimapHeight(stage, activePreset, largest) }}></span>
              <span class="min-w-0">
                <span class="block truncate text-xs font-semibold text-[var(--color-fg-primary)]">${stage.title}</span>
                <span class="mt-0.5 block truncate font-mono text-3xs text-[var(--color-fg-muted)]">
                  ${messageSlotLabel(stage)} · ${stageTokensForPreset(stage, activePreset).toLocaleString()} tok
                </span>
                <span class="mt-1 flex flex-wrap gap-1">
                  ${stage.overrideCount > 0 ? html`<${StatusChip} tone="warn" uppercase=${false}>${stage.overrideCount} edited<//>` : null}
                  ${stage.missingCount > 0 ? html`<${StatusChip} tone="bad" uppercase=${false}>${stage.missingCount} missing<//>` : null}
                </span>
              </span>
            </button>
          `
        })}
      </div>
    </aside>
  `
}

function PromptCodexDocument({
  report,
  activePreset,
  presets,
  onSelectPreset,
}: {
  report: KeeperPromptAssemblyReport
  activePreset: string
  presets: KeeperPromptAssemblyPreset[]
  onSelectPreset: (id: string) => void
}) {
  const visibleStages = stagesForPreset(report, activePreset)
  const visible = presetStats(visibleStages, activePreset)
  const modelStages = report.stages.filter(stage => stage.role === 'model_input')
  const activePresetLabel = presets.find(preset => preset.id === activePreset)?.label ?? '전체'

  return html`
    <section
      data-prompt-route-default
      data-prompt-codex
      class="min-w-0 overflow-hidden rounded-[var(--r-1)] border border-[rgba(201,162,74,0.24)] bg-[linear-gradient(180deg,rgba(34,27,18,0.88),rgba(13,12,10,0.92))] shadow-[0_18px_50px_rgba(0,0,0,0.32)]"
    >
      <div class="border-b border-[rgba(201,162,74,0.18)] px-4 py-4">
        <div class="grid gap-3">
          <div class="min-w-0">
            <div class="mb-2 flex flex-wrap items-center gap-2">
              <${BookOpenText} size=${18} class="text-[var(--color-accent-fg)]" />
              <h3 class="m-0 text-lg font-semibold leading-tight text-[var(--color-fg-primary)]">Prompt Codex</h3>
              <${StatusChip} tone="info" uppercase=${false}>${activePresetLabel}<//>
              <span class="text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-disabled)]">${reportMicrocopy(report)}</span>
            </div>
            <p data-prompt-recipe-intro class="m-0 max-w-3xl text-2xs leading-relaxed text-[var(--color-fg-muted)]">
              Keeper instructions as assembled document sections, with source boundaries and size recap.
            </p>
          </div>
          <${PromptPresetControls} presets=${presets} activePreset=${activePreset} onSelect=${onSelectPreset} />
        </div>
      </div>

      <div class="grid gap-4 p-4 xl:grid-cols-[minmax(0,1fr)_270px]">
        <article class="min-w-0 rounded-[var(--r-1)] border border-[#b58e48]/55 bg-[#ead9b5] p-4 text-[#2b2015] shadow-[0_1px_0_rgba(255,255,255,0.55)_inset,0_18px_46px_rgba(0,0,0,0.28)]">
          <div class="mb-4 grid gap-2 md:grid-cols-4">
            <${CodexMetric} label="Total size" value=${`${formatBytes(report.stats.promptBytes)} · ${report.stats.estimatedTokens.toLocaleString()} tok`} detail="all" tone="neutral" />
            <${CodexMetric} label="Preset size" value=${`${formatBytes(visible.bytes)} · ${visible.estimatedTokens.toLocaleString()} tok`} detail=${activePresetLabel} tone="info" />
            <${CodexMetric} label="Sources" value=${`${visible.rows.length.toLocaleString()} rows`} detail=${`${modelStages.length} model parts`} tone="ok" />
            <${CodexMetric} label="Attention" value=${`${visible.overrides} edited · ${visible.missing} missing`} detail="audit" tone=${visible.missing > 0 ? 'bad' : visible.overrides > 0 ? 'warn' : 'neutral'} />
          </div>

          <div class="mb-5 flex min-w-0 items-start gap-3 border-y border-[rgba(114,97,67,0.24)] py-4">
            <div class="flex size-10 shrink-0 items-center justify-center rounded-full border border-[rgba(114,97,67,0.28)] bg-[rgba(255,251,238,0.48)]">
              <${Brain} size=${20} class="text-[#806331]" />
            </div>
            <div class="min-w-0">
              <div class="text-2xs font-semibold uppercase tracking-[var(--track-caps)] text-[#7d6a4b]">Keeper sees</div>
              <div class="mt-1 text-xl font-semibold leading-tight text-[#2b2015]">A staged instruction manuscript</div>
              <div class="mt-1 text-sm leading-relaxed text-[#6a5a40]">Every block shows where it enters the request, which file or override supplied it, and how much context weight it adds.</div>
            </div>
          </div>

          <div class="grid gap-8">
            ${visibleStages.map(stage => html`
              <${PromptStageDocument} key=${stage.id} stage=${stage} activePreset=${activePreset} />
            `)}
          </div>
        </article>

        <div class="grid content-start gap-3">
          <${PromptCodexMinimap}
            stages=${report.stages}
            activePreset=${activePreset}
            selectedPreset=${activePreset}
            onSelectPreset=${onSelectPreset}
          />
          <div data-prompt-source-roots class="min-w-0 rounded-[var(--r-1)] border border-[rgba(201,162,74,0.24)] bg-[rgba(11,10,8,0.42)] p-3">
            <div class="mb-2 flex items-center gap-2 text-xs font-semibold text-[var(--color-fg-primary)]">
              <${FileText} size=${14} class="text-[var(--color-accent-fg)]" />
              Prompt roots
            </div>
            ${report.activePromptRoots.length > 0 ? report.activePromptRoots.map(root => html`
              <code class="block break-all rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[rgba(255,255,255,0.03)] px-2 py-1.5 font-mono text-3xs leading-relaxed text-[var(--color-fg-secondary)]">${root}</code>
            `) : html`
              <div class="text-2xs text-[var(--color-fg-muted)]">No prompt root resolved.</div>
            `}
          </div>
        </div>
      </div>
    </section>
  `
}

function CleanupDetails({ warnings }: { warnings: KeeperPromptAssemblyWarning[] }) {
  if (warnings.length === 0) return null

  const hasCritical = warnings.some(warning => warning.severity === 'critical')
  const label = `${warnings.length} suggestion${warnings.length === 1 ? '' : 's'}`

  return html`
    <details data-prompt-quality-checks class="mt-3 rounded-[var(--r-1)] border ${hasCritical ? 'border-[var(--bad-20)] bg-[var(--bad-8)]' : 'border-[var(--color-border-default)] bg-[var(--color-bg-surface)]'} v2-monitoring-detail">
      <summary class="flex cursor-pointer list-none items-center justify-between gap-3 px-3 py-2 v2-monitoring-toolbar">
        <span class="flex items-center gap-2 text-xs font-semibold text-[var(--color-fg-primary)]">
          ${hasCritical ? html`<${AlertTriangle} size=${14} />` : null}
          Prompt cleanup
        </span>
        <span class="flex items-center gap-2">
          <${StatusChip} tone=${hasCritical ? 'bad' : 'neutral'}>
            ${label}
          <//>
        </span>
      </summary>
      <div class="grid gap-2 border-t border-[var(--color-border-default)] p-3">
        ${warnings.map(warning => html`
          <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2 v2-monitoring-panel">
            <div class="mb-1 flex flex-wrap items-center gap-2">
              <span class="text-xs font-semibold text-[var(--color-fg-primary)]">${warning.title}</span>
              <${StatusChip} tone=${severityTone(warning.severity)}>${warning.severity}<//>
            </div>
            <div class="text-2xs leading-relaxed text-[var(--color-fg-muted)]">${warning.detail} ${warning.expected}</div>
            <details class="mt-2">
              <summary class="cursor-pointer list-none text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-disabled)]">
                Affected prompts
              </summary>
              <div class="mt-2 flex flex-wrap gap-1">
                ${warning.promptKeys.map(key => html`
                  <span class="rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-1.5 py-0.5 font-mono text-3xs text-[var(--color-fg-secondary)]">${key}</span>
                `)}
              </div>
            </details>
          </div>
        `)}
      </div>
    </details>
  `
}

function SourceEvidenceDetails({ report, compact }: { report: KeeperPromptAssemblyReport; compact: boolean }) {
  if (compact) return null
  const pathSteps = buildPathSteps(report)

  return html`
    <details data-developer-evidence class="mt-3 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] v2-monitoring-detail">
      <summary class="flex cursor-pointer list-none items-center justify-between gap-3 px-3 py-2 v2-monitoring-toolbar">
        <span class="flex items-center gap-2 text-xs font-semibold text-[var(--color-fg-primary)]">
          <${GitCompareArrows} size=${14} />
          Build details
        </span>
        <span class="text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-disabled)]">optional</span>
      </summary>
      <div class="border-t border-[var(--color-border-default)] p-3 pb-16 md:pb-3">
        <div data-source-audit-map class="mb-3">
          <div class="mb-2 text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-disabled)]">build path</div>
          <ol class="border-l border-[var(--accent-22)] pl-3 v2-monitoring-row">
            ${pathSteps.map(step => html`
              <${BuildPathStepRow} key=${step.id} step=${step} />
            `)}
          </ol>
        </div>
        <${CleanupDetails} warnings=${report.warnings} />
        <details data-prompt-file-list class="mt-3 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] v2-monitoring-detail">
          <summary class="flex cursor-pointer list-none items-center justify-between gap-3 px-3 py-2 v2-monitoring-toolbar">
            <span class="text-xs font-semibold text-[var(--color-fg-primary)]">Raw prompt files</span>
            <span class="text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-disabled)]">exact file details</span>
          </summary>
          ${report.activePromptRoots.length > 0 ? html`
            <div class="border-t border-[var(--color-border-default)] px-3 py-2">
              <div class="mb-1 text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-disabled)]">prompt folder</div>
              ${report.activePromptRoots.map(root => html`
                <code class="block break-all text-2xs text-[var(--color-fg-secondary)]">${root}</code>
              `)}
            </div>
          ` : null}
          <div class="overflow-x-auto border-t border-[var(--color-border-default)]">
            <table class="min-w-[860px] w-full border-collapse text-left text-2xs v2-monitoring-table">
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
        </details>
      </div>
    </details>
  `
}

function PromptAssemblyContent({
  report,
  compact = false,
  activePreset,
  presets,
  onSelectPreset,
}: {
  report: KeeperPromptAssemblyReport
  compact?: boolean
  activePreset: string
  presets: KeeperPromptAssemblyPreset[]
  onSelectPreset: (id: string) => void
}) {
  return html`
    <div class="v2-monitoring-panel">
      <${PromptCodexDocument}
        report=${report}
        activePreset=${activePreset}
        presets=${presets}
        onSelectPreset=${onSelectPreset}
      />
      <${SourceEvidenceDetails} report=${report} compact=${compact} />
    </div>
  `
}

export function KeeperPromptAssemblyPanel({
  compact = false,
  prompts: providedPrompts,
  activePreset,
  presets: providedPresets,
  onPresetChange,
}: {
  compact?: boolean
  prompts?: DashboardPromptItem[]
  activePreset?: string
  presets?: KeeperPromptAssemblyPreset[]
  onPresetChange?: (id: string) => void
}) {
  const [loadedPrompts, setLoadedPrompts] = useState<DashboardPromptItem[]>([])
  const [localPreset, setLocalPreset] = useState('all')
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
  const presets = providedPresets?.length ? providedPresets : assemblyPresetOptions(report)
  const requestedPreset = activePreset ?? localPreset
  const selectedPreset = presets.some(preset => preset.id === requestedPreset) ? requestedPreset : 'all'
  function selectPreset(id: string) {
    if (!presets.some(preset => preset.id === id)) return
    if (onPresetChange) {
      onPresetChange(id)
      return
    }
    setLocalPreset(id)
  }
  const showToolbar = ownsFetch || loading

  return html`
    <div class="mb-5 v2-monitoring-panel" data-keeper-prompt-assembly-panel>
      ${showToolbar ? html`<div data-prompt-recipe-toolbar class="mb-2 flex items-center justify-between gap-3 v2-monitoring-toolbar">
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
      </div>` : null}
      ${error ? html`<${ErrorState} message=${error} class="mb-3" />` : null}
      <${PromptAssemblyContent}
        report=${report}
        compact=${compact}
        activePreset=${selectedPreset}
        presets=${presets}
        onSelectPreset=${selectPreset}
      />
    </div>
  `
}
