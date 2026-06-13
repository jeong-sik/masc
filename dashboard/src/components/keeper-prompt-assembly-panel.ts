import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { AlertTriangle, GitCompareArrows, RefreshCw, Route, ShieldAlert } from 'lucide-preact'
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

interface AssemblyStageSpec {
  id: string
  order: number
  title: string
  lane: AssemblyLane
  timing: string
  injection: string
  codeSite: string
  promptKeys: string[]
}

export interface KeeperPromptAssemblyRow {
  id: string
  order: number
  title: string
  lane: AssemblyLane
  timing: string
  injection: string
  codeSite: string
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

export interface KeeperPromptAssemblyReport {
  rows: KeeperPromptAssemblyRow[]
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
    title: 'Registry bootstrap',
    lane: 'registry',
    timing: 'server startup / prompt reload',
    injection: 'Prompt markdown, default, and runtime override are resolved before Keeper run context is built.',
    codeSite: 'Prompt_defaults.bootstrap_runtime -> Prompt_registry',
    promptKeys: ['keeper.world', 'keeper.capabilities', 'keeper.unified.system'],
  },
  {
    id: 'base-system',
    order: 2,
    title: 'Base system prompt',
    lane: 'system_prompt',
    timing: 'Keeper_run_context.prepare_run_context',
    injection: 'Hard identity, raw behavior files, continuity, world, capabilities, and persona profile become the base system prompt.',
    codeSite: 'Keeper_prompt.build_keeper_system_prompt',
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
    title: 'Unified world state',
    lane: 'user_message',
    timing: 'Keeper_unified_prompt.build_prompt',
    injection: 'Turn intent and current world state are rendered as the user-facing world/context prompt.',
    codeSite: 'Keeper_unified_prompt.build_prompt',
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
    title: 'Turn soft context',
    lane: 'extra_system_context',
    timing: 'Keeper_turn.build_turn_prompt callback',
    injection: 'Continuity snapshot, durable memory, skill route, worktree, telemetry feedback, and turn instructions are appended as soft context.',
    codeSite: 'Keeper_turn.build_turn_prompt',
    promptKeys: ['keeper.reply_guidelines'],
  },
  {
    id: 'oas-hook',
    order: 5,
    title: 'OAS pre-turn hook',
    lane: 'oas_hook',
    timing: 'Keeper_run_tools_hooks.before_turn_params',
    injection: 'Temporal summary, claimed-task nudge, retry hint, Memory OS recall, tool filter, and tool choice are finalized before provider dispatch.',
    codeSite: 'Keeper_run_tools_hooks.before_turn_params',
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
    title: 'Manifest edge',
    lane: 'manifest',
    timing: 'Keeper_agent_run.run_turn dispatch',
    injection: 'Prompt metrics, fingerprints, and context_injected edges are recorded after final context assembly.',
    codeSite: 'Keeper_agent_run.append_manifest(context_injected)',
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
    title: 'Legacy playground path example',
    pattern: /\.masc\/playground\//,
    expected: 'Use runtime-provided repo/worktree paths, not playground-era paths.',
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

function laneTone(lane: AssemblyLane): StatusChipTone {
  switch (lane) {
    case 'extra_system_context':
    case 'oas_hook':
      return 'warn'
    case 'system_prompt':
      return 'bad'
    case 'manifest':
      return 'info'
    case 'registry':
      return 'ok'
    default:
      return 'neutral'
  }
}

function severityTone(severity: WarningSeverity): StatusChipTone {
  if (severity === 'critical') return 'bad'
  if (severity === 'warn') return 'warn'
  return 'info'
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
        timing: stage.timing,
        injection: stage.injection,
        codeSite: stage.codeSite,
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
        timing: stage.timing,
        injection: stage.injection,
        codeSite: stage.codeSite,
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
      detail: `${hits.length} prompt(s) still contain ${rule.id}.`,
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

  return {
    rows,
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

function PromptAssemblyContent({ report, compact = false }: { report: KeeperPromptAssemblyReport; compact?: boolean }) {
  const hotspotRows = report.rows.filter(row =>
    row.lane === 'extra_system_context' || row.lane === 'oas_hook' || row.hasOverride || row.missing,
  )
  const visibleRows = compact ? hotspotRows.slice(0, 12) : report.rows

  return html`
    <div
      class="rounded-[var(--r-1)] border border-[var(--warn-30)] p-4"
      style="background:linear-gradient(135deg,var(--bad-10),var(--warn-8) 48%,var(--accent-8));"
    >
      <div class="mb-4 flex flex-wrap items-start justify-between gap-3">
        <div>
          <div class="mb-1 flex items-center gap-2">
            <${Route} size=${16} class="text-[var(--color-status-warn)]" />
            <h3 class="text-sm font-semibold text-[var(--color-fg-primary)]">Keeper 최종 프롬프트 조립표</h3>
            <${StatusChip} tone=${report.stats.criticalCount > 0 ? 'bad' : report.stats.warningCount > 0 ? 'warn' : 'ok'}>
              ${report.stats.criticalCount > 0 ? 'critical drift' : report.stats.warningCount > 0 ? 'watch drift' : 'clean'}
            <//>
          </div>
          <p class="m-0 max-w-3xl text-xs leading-relaxed text-[var(--color-fg-muted)]">
            system prompt, user/world message, OAS extra_system_context, tool hook가 어느 순서로 합쳐지는지 보여줍니다.
            byte/fingerprint는 현재 effective prompt 기준입니다.
          </p>
        </div>
        <div class="grid grid-cols-2 gap-2 text-right sm:grid-cols-4">
          <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2">
            <div class="text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-disabled)]">rows</div>
            <div class="font-mono text-sm text-[var(--color-fg-secondary)]">${report.stats.totalRows}</div>
          </div>
          <div class="rounded-[var(--r-1)] border border-[var(--warn-20)] bg-[var(--warn-10)] px-3 py-2">
            <div class="text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-status-warn)]">warnings</div>
            <div class="font-mono text-sm text-[var(--color-status-warn)]">${report.stats.warningCount}</div>
          </div>
          <div class="rounded-[var(--r-1)] border border-[var(--bad-20)] bg-[var(--bad-10)] px-3 py-2">
            <div class="text-3xs uppercase tracking-[var(--track-caps)] text-[var(--bad-light)]">critical</div>
            <div class="font-mono text-sm text-[var(--bad-light)]">${report.stats.criticalCount}</div>
          </div>
          <div class="rounded-[var(--r-1)] border border-[var(--accent-20)] bg-[var(--accent-10)] px-3 py-2">
            <div class="text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-accent-fg)]">est tokens</div>
            <div class="font-mono text-sm text-[var(--color-accent-fg)]">${report.stats.estimatedTokens.toLocaleString()}</div>
          </div>
        </div>
      </div>

      ${report.activePromptRoots.length > 0 ? html`
        <div class="mb-3 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2">
          <div class="mb-1 flex items-center gap-2 text-2xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">
            <${GitCompareArrows} size=${13} />
            active prompt root
          </div>
          <div class="flex flex-col gap-1">
            ${report.activePromptRoots.map(root => html`
              <code class="break-all text-2xs text-[var(--color-fg-secondary)]">${root}</code>
            `)}
          </div>
        </div>
      ` : null}

      ${report.warnings.length > 0 ? html`
        <div class="mb-4 grid gap-2">
          ${report.warnings.map(warning => html`
            <div class="rounded-[var(--r-1)] border ${warning.severity === 'critical'
              ? 'border-[var(--bad-30)] bg-[var(--bad-10)]'
              : warning.severity === 'warn'
                ? 'border-[var(--warn-30)] bg-[var(--warn-10)]'
                : 'border-[var(--accent-20)] bg-[var(--accent-10)]'} px-3 py-2">
              <div class="mb-1 flex flex-wrap items-center gap-2">
                <${warning.severity === 'critical' ? ShieldAlert : AlertTriangle} size=${14} />
                <span class="text-xs font-semibold text-[var(--color-fg-primary)]">${warning.title}</span>
                <${StatusChip} tone=${severityTone(warning.severity)}>${warning.severity}<//>
              </div>
              <div class="text-2xs leading-relaxed text-[var(--color-fg-muted)]">${warning.detail} ${warning.expected}</div>
              <div class="mt-1 flex flex-wrap gap-1">
                ${warning.promptKeys.map(key => html`
                  <span class="rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-1.5 py-0.5 font-mono text-3xs text-[var(--color-fg-secondary)]">${key}</span>
                `)}
              </div>
            </div>
          `)}
        </div>
      ` : null}

      <div class="overflow-x-auto rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)]">
        <table class="min-w-[980px] w-full border-collapse text-left text-2xs">
          <thead class="bg-[var(--color-bg-elevated)] text-[var(--color-fg-muted)]">
            <tr>
              <th class="px-3 py-2 font-semibold uppercase tracking-[var(--track-caps)]">stage</th>
              <th class="px-3 py-2 font-semibold uppercase tracking-[var(--track-caps)]">lane</th>
              <th class="px-3 py-2 font-semibold uppercase tracking-[var(--track-caps)]">prompt/source</th>
              <th class="px-3 py-2 font-semibold uppercase tracking-[var(--track-caps)]">injection</th>
              <th class="px-3 py-2 font-semibold uppercase tracking-[var(--track-caps)]">size</th>
              <th class="px-3 py-2 font-semibold uppercase tracking-[var(--track-caps)]">fingerprint</th>
            </tr>
          </thead>
          <tbody>
            ${visibleRows.map(row => html`
              <tr class="border-t border-[var(--color-border-default)] ${row.hasOverride
                ? 'bg-[var(--warn-8)]'
                : row.missing
                  ? 'bg-[var(--bad-8)]'
                  : ''}">
                <td class="px-3 py-2 align-top">
                  <div class="font-mono text-[var(--color-fg-disabled)]">#${row.order}</div>
                  <div class="text-xs font-medium text-[var(--color-fg-primary)]">${row.title}</div>
                  <div class="mt-1 text-3xs text-[var(--color-fg-muted)]">${row.timing}</div>
                </td>
                <td class="px-3 py-2 align-top">
                  <${StatusChip} tone=${laneTone(row.lane)} uppercase=${false}>${row.lane}<//>
                  <div class="mt-1 font-mono text-3xs text-[var(--color-fg-disabled)]">${row.codeSite}</div>
                </td>
                <td class="px-3 py-2 align-top">
                  <div class="font-mono text-xs text-[var(--color-fg-secondary)]">${row.promptKey}</div>
                  <div class="mt-1 flex flex-wrap gap-1">
                    <${StatusChip} tone=${row.missing ? 'bad' : row.hasOverride ? 'warn' : row.source === 'file' ? 'ok' : 'neutral'}>${row.source}<//>
                    ${row.hasOverride ? html`<${StatusChip} tone="warn">override<//>` : null}
                  </div>
                  ${row.filePath ? html`<div class="mt-1 max-w-[260px] truncate font-mono text-3xs text-[var(--color-fg-disabled)]" title=${row.filePath}>${row.filePath}</div>` : null}
                </td>
                <td class="px-3 py-2 align-top text-xs leading-relaxed text-[var(--color-fg-muted)]">${row.injection}</td>
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

      ${compact && hotspotRows.length > visibleRows.length ? html`
        <div class="mt-2 text-2xs text-[var(--color-fg-muted)]">
          Showing ${visibleRows.length} hotspot rows out of ${hotspotRows.length}. Open Prompt Registry for the full assembly table.
        </div>
      ` : null}
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
    <div class="mb-5" data-keeper-prompt-assembly-panel>
      <div class="mb-2 flex items-center justify-between gap-3">
        <div class="flex items-center gap-2">
          <span class="text-2xs font-semibold uppercase tracking-wider text-[var(--color-fg-muted)]">Prompt Assembly</span>
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
