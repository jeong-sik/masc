import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import type { Keeper, Task } from '../../types'
import { keepers, tasks } from '../../store'
import { KeeperBadge } from '../keeper-badge'
import {
  canonicalKeeperName,
  keeperIdentityKeys,
} from '../common/keeper-identity'
import { cursorOverlaySignal, getKeeperColor, type KeeperCursor } from './keeper-cursor-overlay'

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

  const [overlay, setOverlay] = useState(cursorOverlaySignal.value)
  useEffect(() => {
    const unsub = cursorOverlaySignal.subscribe(v => setOverlay(v))
    return () => unsub()
  }, [])

  const cursor = resolveKeeperCursor(keeperName, overlay.cursors)

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
        ${PresenceIndicator(cursor)}
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

function resolveKeeperCursor(
  keeperName: string,
  cursors: Map<string, KeeperCursor>,
): KeeperCursor | null {
  if (!keeperName) return null
  const target = keeperName.toLowerCase().trim()
  // 1. Exact key match (cursorOverlaySignal map keys are canonical keeper ids).
  // 2. Cursor payload's own keeper_id (server-emitted identity, may differ
  //    from the map key when the SSE source key is e.g. a session id).
  // Substring/includes fallbacks were removed because they pick the wrong
  // cursor when ids share prefixes/suffixes (e.g. "kim" matches "kimchi").
  for (const [id, cursor] of cursors) {
    if (id.toLowerCase() === target) return cursor
    if (cursor.keeper_id && cursor.keeper_id.toLowerCase() === target) return cursor
  }
  return null
}

function PresenceIndicator(cursor: KeeperCursor | null) {
  if (!cursor) return null
  // Defensive: SSE parser can emit file_path='' (not-yet-set) and
  // last_update timestamps that are 0 or in the future. Without these
  // guards the card renders ":<line>" with no filename and "-99m ago".
  if (!cursor.file_path) return null
  const color = getKeeperColor(cursor.keeper_id)
  const fileName = cursor.file_path.split('/').pop() ?? cursor.file_path
  const rawAge = Math.round((Date.now() - cursor.last_update) / 1000)
  const ageSec = Math.max(0, rawAge)
  const isEditing = cursor.focus_mode === 'editing'
  return html`
    <div
      class="ide-keeper-presence"
      role="status"
      aria-label="Keeper presence"
      style=${{
        display: 'grid',
        gap: 'var(--sp-1)',
        padding: 'var(--sp-2)',
        background: 'var(--color-bg-surface)',
        border: '1px solid var(--color-border-default)',
        borderRadius: 'var(--r-2)',
      }}
    >
      <div style=${{ display: 'flex', alignItems: 'center', gap: 'var(--sp-1)' }}>
        <span
          aria-hidden="true"
          style=${{
            width: '6px',
            height: '6px',
            borderRadius: '50%',
            background: color.cursor,
            display: 'inline-block',
            boxShadow: isEditing ? `0 0 4px ${color.cursor}` : 'none',
          }}
        />
        <span style=${{
          fontSize: 'var(--fs-11)',
          letterSpacing: '0.05em',
          color: isEditing ? 'var(--color-status-err)' : 'var(--color-fg-muted)',
          fontWeight: 600,
        }}>${cursor.focus_mode.toUpperCase()}</span>
        ${cursor.tool_name
          ? html`<span style=${{ fontSize: 'var(--fs-11)', color: 'var(--color-fg-secondary)', marginLeft: 'auto' }}>${cursor.tool_name}</span>`
          : null}
      </div>
      <div style=${{
        fontSize: 'var(--fs-11)',
        fontFamily: 'var(--font-mono)',
        color: 'var(--color-fg-secondary)',
        overflow: 'hidden',
        textOverflow: 'ellipsis',
        whiteSpace: 'nowrap',
      }} title=${cursor.file_path}>
        ${fileName}:${cursor.line}${cursor.selection_end ? `-${cursor.selection_end.line}` : ''}
      </div>
      ${cursor.turn != null
        ? html`
          <div style=${{ display: 'flex', gap: 'var(--sp-2)', fontSize: 'var(--fs-11)', color: 'var(--color-fg-muted)' }}>
            <span>turn ${cursor.turn}</span>
            <span style=${{ marginLeft: 'auto' }}>${ageSec < 60 ? `${ageSec}s ago` : `${Math.round(ageSec / 60)}m ago`}</span>
          </div>
        `
        : null}
    </div>
  `
}
