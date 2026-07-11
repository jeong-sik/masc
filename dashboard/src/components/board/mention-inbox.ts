import { html } from 'htm/preact'
import { useMemo } from 'preact/hooks'
import { ArrowLeft, AtSign } from 'lucide-preact'
import { ActionButton } from '../common/button'
import { EmptyState } from '../common/feedback-state'
import { RichContent } from '../common/rich-content'
import { TimeAgo } from '../common/time-ago'
import { SYSTEM_MESSAGE_FROM, boardMessageRowKey, previewBoardMessage } from '../../lib/board-utils'
import { currentDashboardActorName } from '../../lib/dashboard-session-actor'
import { MENTION_RE } from '../../lib/mention-utils'
import { messages, shellAuthSummary } from '../../store'
import type { DashboardShellAuthSummary, Message } from '../../types'
import { navigateBoard } from './board-route'

interface MentionInboxRow {
  message: Message
  mentionTargets: string[]
  isForMe: boolean
  index: number
  timestampMs: number | null
}

export interface MentionInboxModel {
  forMe: MentionInboxRow[]
  others: MentionInboxRow[]
}

function normalizeTarget(value: string | null | undefined): string | null {
  const normalized = value?.trim().replace(/^@+/, '').toLowerCase()
  return normalized || null
}

export function extractMentionTargets(content: string): string[] {
  const seen = new Set<string>()
  const targets: string[] = []
  for (const match of content.matchAll(MENTION_RE)) {
    const target = match[2]
    if (!target) continue
    const key = normalizeTarget(target)
    if (!key || seen.has(key)) continue
    seen.add(key)
    targets.push(target)
  }
  return targets
}

export function mentionTargetCandidates(
  auth: DashboardShellAuthSummary | null,
  actorName: string,
): string[] {
  const values = [
    auth?.effective_agent,
    auth?.token_agent,
    auth?.requested_agent,
    actorName,
    'dashboard',
    'operator',
  ]
  const seen = new Set<string>()
  const targets: string[] = []
  for (const value of values) {
    const key = normalizeTarget(value)
    if (!key || seen.has(key)) continue
    seen.add(key)
    targets.push(key)
  }
  return targets
}

function messageTimestampMs(message: Message): number | null {
  if (!message.timestamp) return null
  const parsed = Date.parse(message.timestamp)
  return Number.isFinite(parsed) ? parsed : null
}

function messageMentions(message: Message): boolean {
  return extractMentionTargets(message.content).length > 0 || message.type?.toLowerCase().includes('mention') === true
}

export function buildMentionInboxModel(
  messageList: readonly Message[],
  currentTargets: readonly string[],
): MentionInboxModel {
  const targetSet = new Set(
    currentTargets
      .map(normalizeTarget)
      .filter((target): target is string => target !== null),
  )
  const rows = messageList
    .map((message, index): MentionInboxRow | null => {
      if (!messageMentions(message)) return null
      const mentionTargets = extractMentionTargets(message.content)
      const isForMe = mentionTargets.some(target => {
        const key = normalizeTarget(target)
        return key ? targetSet.has(key) : false
      })
      return {
        message,
        mentionTargets,
        isForMe,
        index,
        timestampMs: messageTimestampMs(message),
      }
    })
    .filter((row): row is MentionInboxRow => row !== null)
    .sort((left, right) => {
      if (left.timestampMs !== null && right.timestampMs !== null && left.timestampMs !== right.timestampMs) {
        return right.timestampMs - left.timestampMs
      }
      if (left.message.seq !== undefined && right.message.seq !== undefined && left.message.seq !== right.message.seq) {
        return right.message.seq - left.message.seq
      }
      return right.index - left.index
    })

  return {
    forMe: rows.filter(row => row.isForMe),
    others: rows.filter(row => !row.isForMe),
  }
}

function MessageRow({ row }: { row: MentionInboxRow }) {
  const preview = previewBoardMessage(row.message)
  return html`
    <article class="v2-workspace-row rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-3.5 py-3 hover:border-[var(--color-border-strong)] transition-colors">
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
    </article>
  `
}

function MentionLane({
  title,
  rows,
  emptyMessage,
}: {
  title: string
  rows: MentionInboxRow[]
  emptyMessage: string
}) {
  return html`
    <section class="min-w-0" aria-label=${title}>
      <div class="mb-2 flex items-center justify-between gap-2">
        <h3 class="text-sm font-bold text-[var(--color-fg-primary)]">${title}</h3>
        <span class="rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-panel-alt)] px-2 py-0.5 text-2xs font-medium tabular-nums text-[var(--color-fg-secondary)]">${rows.length}</span>
      </div>
      ${rows.length === 0
        ? html`<${EmptyState} message=${emptyMessage} compact />`
        : html`<div class="grid gap-2.5">${rows.map(row => html`<${MessageRow} key=${boardMessageRowKey(row.message, row.index)} row=${row} />`)}</div>`}
    </section>
  `
}

export function MentionInbox() {
  const actorName = currentDashboardActorName()
  const targetCandidates = mentionTargetCandidates(shellAuthSummary.value, actorName)
  const targetKey = targetCandidates.join('|')
  const model = useMemo(
    () => buildMentionInboxModel(messages.value, targetCandidates),
    [targetKey, messages.value],
  )
  const total = model.forMe.length + model.others.length

  return html`
    <section class="grid gap-4" aria-labelledby="mention-inbox-heading">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="text-2xs font-bold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-secondary)]">Messages</div>
          <h2 id="mention-inbox-heading" class="mt-1 text-xl font-bold text-[var(--color-fg-primary)]">Mention inbox</h2>
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
          <div class="text-2xs font-bold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-secondary)]">For me</div>
          <div class="mt-1 text-lg font-bold tabular-nums text-[var(--color-fg-primary)]">${model.forMe.length}</div>
        </div>
        <div class="v2-workspace-card rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-3 py-2">
          <div class="text-2xs font-bold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-secondary)]">Other mentions</div>
          <div class="mt-1 text-lg font-bold tabular-nums text-[var(--color-fg-primary)]">${model.others.length}</div>
        </div>
        <div class="v2-workspace-card rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-3 py-2">
          <div class="text-2xs font-bold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-secondary)]">Targets</div>
          <div class="mt-1 truncate text-sm font-bold text-[var(--color-fg-primary)]">${targetCandidates.map(target => `@${target}`).join(', ')}</div>
        </div>
      </div>

      ${total === 0
        ? html`<${EmptyState} message="멘션 메시지가 없습니다" compact />`
        : html`
            <div class="grid gap-4 xl:grid-cols-2">
              <${MentionLane} title="For me" rows=${model.forMe} emptyMessage="현재 actor 대상 멘션이 없습니다" />
              <${MentionLane} title="Other mentions" rows=${model.others} emptyMessage="다른 대상 멘션이 없습니다" />
            </div>
          `}
    </section>
  `
}

/** Compact mention inbox for the board v2 right-hand detail rail. */
export function MentionInboxPanel() {
  const actorName = currentDashboardActorName()
  const targetCandidates = mentionTargetCandidates(shellAuthSummary.value, actorName)
  const targetKey = targetCandidates.join('|')
  const model = useMemo(
    () => buildMentionInboxModel(messages.value, targetCandidates),
    [targetKey, messages.value],
  )
  const total = model.forMe.length + model.others.length

  if (total === 0) {
    return html`<${EmptyState} message="멘션 메시지가 없습니다" compact />`
  }

  return html`
    <div class="bd-mention-panel" data-testid="bd-mention-panel">
      <div class="bd-mention-stats">
        <div class="bd-mention-stat">
          <div class="k">For me</div>
          <div class="v">${model.forMe.length}</div>
        </div>
        <div class="bd-mention-stat">
          <div class="k">Others</div>
          <div class="v">${model.others.length}</div>
        </div>
      </div>
      <${MentionLane} title="For me" rows=${model.forMe} emptyMessage="현재 actor 대상 멘션이 없습니다" />
      <${MentionLane} title="Other mentions" rows=${model.others} emptyMessage="다른 대상 멘션이 없습니다" />
    </div>
  `
}
