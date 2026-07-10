import { html } from 'htm/preact'
import { useMemo, useState } from 'preact/hooks'
import { ArrowLeft, AtSign } from 'lucide-preact'
import { ActionButton } from '../common/button'
import { EmptyState } from '../common/feedback-state'
import { RichContent } from '../common/rich-content'
import { TimeAgo } from '../common/time-ago'
import { SYSTEM_MESSAGE_FROM, boardMessageRowKey, previewBoardMessage } from '../../lib/board-utils'
import { messages } from '../../store'
import type { Message } from '../../types'
import { ComposerV2 } from './composer-v2'
import { extractMentionTargets } from './mention-inbox'
import { navigateBoard } from './board-route'

interface TimelineRow {
  message: Message
  index: number
  timestampMs: number | null
  mentionTargets: string[]
}

interface WorkspaceBucket {
  workspace: string
  rows: TimelineRow[]
}

export interface MessageWorkspaceModel {
  workspaces: WorkspaceBucket[]
  totalMessages: number
  totalMentions: number
}

function normalizeWorkspace(value: string | null | undefined): string {
  const workspace = value?.trim().replace(/^#+/, '')
  return workspace || 'execution'
}

function messageTimestampMs(message: Message): number | null {
  if (!message.timestamp) return null
  const parsed = Date.parse(message.timestamp)
  return Number.isFinite(parsed) ? parsed : null
}

function timelineSort(left: TimelineRow, right: TimelineRow): number {
  if (left.timestampMs !== null && right.timestampMs !== null && left.timestampMs !== right.timestampMs) {
    return left.timestampMs - right.timestampMs
  }
  if (left.message.seq !== undefined && right.message.seq !== undefined && left.message.seq !== right.message.seq) {
    return left.message.seq - right.message.seq
  }
  return left.index - right.index
}

export function buildMessageWorkspaceModel(messageList: readonly Message[]): MessageWorkspaceModel {
  const byWorkspace = new Map<string, TimelineRow[]>()
  let totalMentions = 0

  messageList.forEach((message, index) => {
    const mentionTargets = extractMentionTargets(message.content)
    totalMentions += mentionTargets.length
    const workspace = normalizeWorkspace(message.workspace)
    const rows = byWorkspace.get(workspace) ?? []
    rows.push({
      message,
      index,
      timestampMs: messageTimestampMs(message),
      mentionTargets,
    })
    byWorkspace.set(workspace, rows)
  })

  const workspaces = Array.from(byWorkspace.entries())
    .map(([workspace, rows]) => ({ workspace, rows: rows.sort(timelineSort) }))
    .sort((left, right) => {
      if (left.workspace === 'execution') return -1
      if (right.workspace === 'execution') return 1
      return left.workspace.localeCompare(right.workspace)
    })

  return {
    workspaces,
    totalMessages: messageList.length,
    totalMentions,
  }
}

function TimelineMessage({ row }: { row: TimelineRow }) {
  const preview = previewBoardMessage(row.message)
  return html`
    <article class="v2-workspace-row grid grid-cols-[3rem_minmax(0,1fr)] gap-3 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-3.5 py-3 hover:border-[var(--color-border-strong)] transition-colors">
      <div class="pt-0.5 text-right text-2xs font-bold tabular-nums uppercase tracking-[var(--track-caps)] text-[var(--color-fg-secondary)]">
        ${row.message.seq !== undefined ? `#${row.message.seq}` : row.index + 1}
      </div>
      <div class="min-w-0">
        <div class="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1">
          <span class="text-xs font-bold text-[var(--color-fg-primary)]">${row.message.from ?? SYSTEM_MESSAGE_FROM}</span>
          ${row.message.timestamp
            ? html`<span class="text-2xs tabular-nums text-[var(--color-fg-secondary)]"><${TimeAgo} timestamp=${row.message.timestamp} /></span>`
            : null}
          ${row.message.type
            ? html`<span class="rounded-[var(--r-0)] border border-[var(--color-border-default)] px-2 py-0.5 text-2xs font-medium uppercase tracking-[var(--track-caps)] text-[var(--color-fg-secondary)]">${row.message.type}</span>`
            : null}
        </div>
        <div class="mt-2 text-sm leading-paragraph text-[var(--color-fg-primary)]">
          <${RichContent} text=${preview} previewLimit=${2} />
        </div>
        ${row.mentionTargets.length > 0
          ? html`
              <div class="mt-2 flex flex-wrap gap-1.5">
                ${row.mentionTargets.map(target => html`
                  <span class="inline-flex items-center gap-1 rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-panel-alt)] px-2 py-0.5 text-2xs font-medium text-[var(--color-fg-secondary)]" key=${target}>
                    <${AtSign} size=${11} aria-hidden="true" />
                    @${target}
                  </span>
                `)}
              </div>
            `
          : null}
      </div>
    </article>
  `
}

export function MessageWorkspaceTimeline() {
  const model = useMemo(() => buildMessageWorkspaceModel(messages.value), [messages.value])
  const [selectedWorkspace, setSelectedWorkspace] = useState<string | null>(null)
  const activeWorkspace = model.workspaces.some(workspace => workspace.workspace === selectedWorkspace)
    ? selectedWorkspace
    : model.workspaces[0]?.workspace ?? null
  const active = activeWorkspace ? model.workspaces.find(workspace => workspace.workspace === activeWorkspace) ?? null : null
  const composerWorkspace = activeWorkspace ?? 'default'

  return html`
    <section class="grid gap-4" aria-labelledby="message-workspace-timeline-heading">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="text-2xs font-bold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-secondary)]">Messages</div>
          <h2 id="message-workspace-timeline-heading" class="mt-1 text-xl font-bold text-[var(--color-fg-primary)]">Workspace timeline</h2>
        </div>
        <${ActionButton}
          variant="ghost"
          size="sm"
          class="inline-flex items-center gap-1.5"
          onClick=${() => navigateBoard()}
          ariaLabel="게시판으로 돌아가기"
        >
          <${ArrowLeft} size=${14} aria-hidden="true" />
          Board
        <//>
      </div>

      <div class="grid grid-cols-[repeat(auto-fit,minmax(9rem,1fr))] gap-2">
        <div class="v2-workspace-card rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-3 py-2">
          <div class="text-2xs font-bold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-secondary)]">Workspaces</div>
          <div class="mt-1 text-lg font-bold tabular-nums text-[var(--color-fg-primary)]">${model.workspaces.length}</div>
        </div>
        <div class="v2-workspace-card rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-3 py-2">
          <div class="text-2xs font-bold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-secondary)]">Messages</div>
          <div class="mt-1 text-lg font-bold tabular-nums text-[var(--color-fg-primary)]">${model.totalMessages}</div>
        </div>
        <div class="v2-workspace-card rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-3 py-2">
          <div class="text-2xs font-bold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-secondary)]">Signals</div>
          <div class="mt-1 text-sm font-bold tabular-nums text-[var(--color-fg-primary)]">${model.totalMentions} mentions</div>
        </div>
      </div>

      ${model.workspaces.length === 0
        ? html`
            <${ComposerV2} workspaceId=${composerWorkspace} />
            <${EmptyState} message="메시지 타임라인이 없습니다" compact />
          `
        : html`
            <div class="flex flex-wrap gap-2" role="tablist" aria-label="Message workspaces">
              ${model.workspaces.map(workspace => html`
                <button
                  type="button"
                  role="tab"
                  aria-selected=${workspace.workspace === activeWorkspace}
                  class=${`v2-workspace-action rounded-[var(--r-1)] border px-3 py-1.5 text-xs font-medium transition-colors ${
                    workspace.workspace === activeWorkspace
                      ? 'border-[var(--color-accent)] bg-[var(--accent-10)] text-[var(--color-accent-fg)]'
                      : 'border-[var(--color-border-default)] bg-[var(--color-bg-surface)] text-[var(--color-fg-secondary)] hover:bg-[var(--color-bg-hover)] hover:text-[var(--color-fg-primary)]'
                  }`}
                  onClick=${() => setSelectedWorkspace(workspace.workspace)}
                >
                  #${workspace.workspace}
                  <span class="ml-2 text-2xs tabular-nums text-[var(--color-fg-muted)]">${workspace.rows.length}</span>
                </button>
              `)}
            </div>
            <${ComposerV2} workspaceId=${composerWorkspace} />
            <section role="tabpanel" aria-label=${active ? `#${active.workspace} timeline` : 'Message timeline'} class="grid gap-2.5">
              ${active?.rows.map(row => html`<${TimelineMessage} key=${boardMessageRowKey(row.message, row.index)} row=${row} />`)}
            </section>
          `}
    </section>
  `
}
