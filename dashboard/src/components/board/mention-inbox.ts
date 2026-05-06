import { html } from 'htm/preact'
import { useMemo } from 'preact/hooks'
import { ArrowLeft, AtSign } from 'lucide-preact'
import { ActionButton } from '../common/button'
import { EmptyState } from '../common/empty-state'
import { RichContent } from '../common/rich-content'
import { TimeAgo } from '../common/time-ago'
import { stripStateBlocks } from '../../keeper-message'
import { currentDashboardActorName } from '../../lib/dashboard-session-actor'
import { navigate } from '../../router'
import { messages, shellAuthSummary } from '../../store'
import type { DashboardShellAuthSummary, Message } from '../../types'

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

const MENTION_RE = /(^|[^A-Za-z0-9._-])@([A-Za-z0-9._-]{1,64})/g

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

function previewContent(message: Message): string {
  return stripStateBlocks(message.content).trim() || message.content.trim() || '(empty)'
}

function rowKey(row: MentionInboxRow): string {
  return row.message.id ?? `${row.message.seq ?? 'message'}-${row.index}`
}

function MessageRow({ row }: { row: MentionInboxRow }) {
  const preview = previewContent(row.message)
  const hasState = row.message.content.includes('[STATE]')
  return html`
    <article class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3.5 py-3">
      <div class="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1">
        <span class="text-xs font-semibold text-[var(--color-fg-secondary)]">${row.message.from ?? 'system'}</span>
        ${row.message.timestamp
          ? html`<span class="text-2xs tabular-nums text-[var(--color-fg-muted)]"><${TimeAgo} timestamp=${row.message.timestamp} /></span>`
          : null}
        ${row.message.type
          ? html`<span class="rounded-[var(--r-0)] border border-[var(--color-border-default)] px-2 py-0.5 text-3xs font-medium uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">${row.message.type}</span>`
          : null}
        ${hasState
          ? html`<span class="rounded-[var(--r-0)] border border-[var(--color-accent-soft)] bg-[var(--accent-10)] px-2 py-0.5 text-3xs font-medium text-[var(--color-accent-fg)]">STATE</span>`
          : null}
      </div>
      <div class="mt-2 text-sm leading-paragraph text-[var(--color-fg-primary)]">
        <${RichContent} text=${preview} previewLimit=${2} />
      </div>
      ${row.mentionTargets.length > 0
        ? html`
            <div class="mt-2 flex flex-wrap gap-1.5">
              ${row.mentionTargets.map(target => html`
                <span class="inline-flex items-center gap-1 rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-panel-alt)] px-2 py-0.5 text-3xs font-medium text-[var(--color-fg-muted)]" key=${target}>
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
        <h3 class="text-sm font-semibold text-[var(--color-fg-secondary)]">${title}</h3>
        <span class="rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-panel-alt)] px-2 py-0.5 text-3xs font-medium tabular-nums text-[var(--color-fg-muted)]">${rows.length}</span>
      </div>
      ${rows.length === 0
        ? html`<${EmptyState} message=${emptyMessage} compact />`
        : html`<div class="grid gap-2.5">${rows.map(row => html`<${MessageRow} key=${rowKey(row)} row=${row} />`)}</div>`}
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
          <div class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">Messages</div>
          <h2 id="mention-inbox-heading" class="mt-1 text-xl font-semibold text-[var(--color-fg-primary)]">Mention inbox</h2>
        </div>
        <${ActionButton}
          variant="ghost"
          size="sm"
          class="inline-flex items-center gap-1.5"
          onClick=${() => navigate('workspace', { section: 'board' })}
          ariaLabel="게시판으로 돌아가기"
        >
          <${ArrowLeft} size=${14} aria-hidden="true" />
          Board
        <//>
      </div>

      <div class="grid grid-cols-[repeat(auto-fit,minmax(9rem,1fr))] gap-2">
        <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2">
          <div class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">For me</div>
          <div class="mt-1 text-lg font-semibold tabular-nums text-[var(--color-fg-primary)]">${model.forMe.length}</div>
        </div>
        <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2">
          <div class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">Other mentions</div>
          <div class="mt-1 text-lg font-semibold tabular-nums text-[var(--color-fg-primary)]">${model.others.length}</div>
        </div>
        <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2">
          <div class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">Targets</div>
          <div class="mt-1 truncate text-sm font-semibold text-[var(--color-fg-primary)]">${targetCandidates.map(target => `@${target}`).join(', ')}</div>
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
