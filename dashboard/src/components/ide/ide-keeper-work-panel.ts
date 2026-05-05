import { html } from 'htm/preact'
import type { Keeper, Task } from '../../types'
import { keepers, tasks } from '../../store'
import { KeeperBadge } from '../keeper-badge'
import {
  canonicalKeeperName,
  keeperIdentityKeys,
} from '../common/keeper-identity'

interface IdeKeeperWorkPanelProps {
  readonly keeperName: string
}

interface KeeperWorkSummary {
  readonly displayName: string
  readonly keeper: Keeper | null
  readonly currentTaskId: string | null
  readonly currentTask: Task | null
  readonly activeTasks: ReadonlyArray<Task>
  readonly activeTaskCount: number
  readonly terminalCode: string | null
  readonly terminalSummary: string | null
  readonly nextAction: string | null
  readonly recentOutput: string | null
  readonly recentTools: ReadonlyArray<string>
  readonly runtimeBlocker: string | null
}

const EMPTY_TOOLS: ReadonlyArray<string> = []

export function IdeKeeperWorkPanel({ keeperName }: IdeKeeperWorkPanelProps) {
  const summary = keeperWorkSummary(keeperName, keepers.value, tasks.value)
  const keeper = summary.keeper
  const currentTask = summary.currentTask
  const attention = Boolean(
    keeper?.needs_attention
    || keeper?.trust?.needs_attention
    || summary.terminalCode
    || summary.runtimeBlocker,
  )

  return html`
    <section
      class="ide-keeper-work"
      role="region"
      aria-label="KEEPER WORK"
      data-attention=${attention ? 'true' : 'false'}
    >
      <div class="ide-keeper-work-head">
        <span>KEEPER WORK</span>
        <span>
          ${summary.displayName
            ? html`<${KeeperBadge} id=${summary.displayName} variant="full" size="sm" />`
            : 'all keepers'}
        </span>
      </div>
      <div class="ide-keeper-work-body">
        <div class="ide-keeper-work-strip">
          ${WorkMetric('phase', keeper?.phase ?? keeper?.status ?? 'unknown')}
          ${WorkMetric('task', summary.currentTaskId ?? 'none')}
          ${WorkMetric('active', String(summary.activeTaskCount))}
        </div>
        ${currentTask
          ? html`
            <div class="ide-keeper-work-card">
              <div class="ide-keeper-work-card-top">
                <span>${currentTask.id}</span>
                <span>${currentTask.status ?? 'unknown'}</span>
              </div>
              <strong title=${currentTask.title}>${currentTask.title}</strong>
              ${currentTask.worktree
                ? html`<span title=${currentTask.worktree.path}>${currentTask.worktree.branch} · ${currentTask.worktree.repo_name}</span>`
                : null}
            </div>
          `
          : summary.currentTaskId
            ? html`
              <div class="ide-keeper-work-card">
                <div class="ide-keeper-work-card-top">
                  <span>${summary.currentTaskId}</span>
                  <span>runtime</span>
                </div>
                <strong>keeper runtime current task</strong>
                <span>task row not present in execution projection</span>
              </div>
            `
          : html`<div class="ide-keeper-work-empty">no active keeper task in dashboard state</div>`}
        ${RuntimeBlock(summary)}
        ${summary.recentOutput
          ? html`<p class="ide-keeper-work-output">${summary.recentOutput}</p>`
          : null}
        ${summary.recentTools.length > 0
          ? html`
            <div class="ide-keeper-work-tools" aria-label="Recent keeper tools">
              ${summary.recentTools.slice(0, 5).map(tool => html`<span>${tool}</span>`)}
            </div>
          `
          : null}
      </div>
    </section>
  `
}

function WorkMetric(label: string, value: string) {
  return html`
    <span class="ide-keeper-work-metric">
      <span>${label}</span>
      <strong title=${value}>${value}</strong>
    </span>
  `
}

function RuntimeBlock(summary: KeeperWorkSummary) {
  const headline = summary.terminalSummary ?? summary.runtimeBlocker
  const action = summary.nextAction
  if (!headline && !action) return null
  return html`
    <div class="ide-keeper-work-runtime" role="status">
      <div>
        <span>${summary.terminalCode ?? 'runtime'}</span>
        <strong>${headline ?? action}</strong>
      </div>
      ${action ? html`<span>${action}</span>` : null}
    </div>
  `
}

export function keeperWorkSummary(
  keeperName: string,
  keeperList: ReadonlyArray<Keeper>,
  taskList: ReadonlyArray<Task>,
): KeeperWorkSummary {
  const displayName = normalizedKeeperName(keeperName)
  const keeper = findKeeper(displayName, keeperList)
  const explicitCurrentTaskId = firstNonEmpty(keeper?.agent?.current_task)
  const assigneeTasks = taskList
    .filter(task => taskMatchesKeeper(task, displayName, keeper))
    .filter(task => task.status !== 'done' && task.status !== 'cancelled')
  const currentTaskById = explicitCurrentTaskId
    ? taskList.find(task => task.id === explicitCurrentTaskId) ?? null
    : null
  const activeTasks = uniqTasks(currentTaskById ? [currentTaskById, ...assigneeTasks] : assigneeTasks)
  const currentTaskId = firstNonEmpty(
    explicitCurrentTaskId,
    activeTasks[0]?.id,
  )
  const currentTask = currentTaskId
    ? activeTasks.find(task => task.id === currentTaskId) ?? null
    : activeTasks[0] ?? null
  const trust = keeper?.trust ?? null
  const latestTerminal = trust?.latest_terminal_reason ?? null
  return {
    displayName,
    keeper,
    currentTaskId,
    currentTask,
    activeTasks,
    activeTaskCount: currentTaskId && activeTasks.length === 0 ? 1 : activeTasks.length,
    terminalCode: firstNonEmpty(latestTerminal?.code, keeper?.runtime_blocker_class),
    terminalSummary: firstNonEmpty(
      latestTerminal?.summary,
      keeper?.runtime_blocker_summary,
      trust?.attention_reason,
      keeper?.attention_reason,
    ),
    nextAction: firstNonEmpty(
      latestTerminal?.next_action,
      trust?.latest_next_action,
      trust?.next_human_action,
      keeper?.next_human_action,
    ),
    recentOutput: firstNonEmpty(keeper?.recent_output_preview, keeper?.recent_input_preview),
    recentTools: keeper?.recent_tool_names ?? keeper?.latest_tool_names ?? EMPTY_TOOLS,
    runtimeBlocker: firstNonEmpty(keeper?.runtime_blocker_summary, keeper?.last_blocker),
  }
}

function findKeeper(name: string, keeperList: ReadonlyArray<Keeper>): Keeper | null {
  const target = name.toLowerCase()
  if (!target) return keeperList[0] ?? null
  return keeperList.find(keeper => {
    const keys = keeperIdentityKeys(keeper.keeper_id, keeper.name, keeper.agent_name)
    return keys.includes(target) || keys.includes(`keeper:${target}`)
  }) ?? null
}

function taskMatchesKeeper(task: Task, keeperName: string, keeper: Keeper | null): boolean {
  if (!task.assignee) return false
  const taskKeys = assigneeKeys(task.assignee)
  const keeperKeys = new Set([
    ...keeperIdentityKeys(keeper?.keeper_id, keeper?.name ?? keeperName, keeper?.agent_name),
    ...assigneeKeys(keeperName),
  ])
  return taskKeys.some(key => keeperKeys.has(key))
}

function assigneeKeys(value: string): string[] {
  const raw = value.trim().toLowerCase()
  const canonical = canonicalKeeperName(value)?.toLowerCase() ?? null
  return [
    raw,
    canonical,
    canonical ? `keeper:${canonical}` : null,
  ].filter((item): item is string => Boolean(item))
}

function uniqTasks(taskList: ReadonlyArray<Task>): Task[] {
  const seen = new Set<string>()
  const result: Task[] = []
  for (const task of taskList) {
    if (task.status === 'done' || task.status === 'cancelled' || seen.has(task.id)) continue
    seen.add(task.id)
    result.push(task)
  }
  return result
}

function normalizedKeeperName(value: string): string {
  return canonicalKeeperName(value) ?? value.trim()
}

function firstNonEmpty(...values: ReadonlyArray<string | null | undefined>): string | null {
  for (const value of values) {
    const trimmed = value?.trim()
    if (trimmed) return trimmed
  }
  return null
}
