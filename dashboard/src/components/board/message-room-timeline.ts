import { html } from 'htm/preact'
import { useMemo, useState } from 'preact/hooks'
import { ArrowLeft, AtSign, Braces } from 'lucide-preact'
import { ActionButton } from '../common/button'
import { EmptyState } from '../common/empty-state'
import { RichContent } from '../common/rich-content'
import { TimeAgo } from '../common/time-ago'
import { stripStateBlocks } from '../../keeper-message'
import { navigate } from '../../router'
import { messages } from '../../store'
import type { Message } from '../../types'
import { extractMentionTargets } from './mention-inbox'
import { extractStateBlocks } from './state-block-messages'

interface TimelineRow {
  message: Message
  index: number
  timestampMs: number | null
  mentionTargets: string[]
  stateBlockCount: number
}

interface RoomBucket {
  room: string
  rows: TimelineRow[]
}

export interface MessageRoomModel {
  rooms: RoomBucket[]
  totalMessages: number
  totalMentions: number
  totalStateBlocks: number
}

function normalizeRoom(value: string | null | undefined): string {
  const room = value?.trim().replace(/^#+/, '')
  return room || 'execution'
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

export function buildMessageRoomModel(messageList: readonly Message[]): MessageRoomModel {
  const byRoom = new Map<string, TimelineRow[]>()
  let totalMentions = 0
  let totalStateBlocks = 0

  messageList.forEach((message, index) => {
    const mentionTargets = extractMentionTargets(message.content)
    const stateBlockCount = extractStateBlocks(message.content).length
    totalMentions += mentionTargets.length
    totalStateBlocks += stateBlockCount
    const room = normalizeRoom(message.room)
    const rows = byRoom.get(room) ?? []
    rows.push({
      message,
      index,
      timestampMs: messageTimestampMs(message),
      mentionTargets,
      stateBlockCount,
    })
    byRoom.set(room, rows)
  })

  const rooms = Array.from(byRoom.entries())
    .map(([room, rows]) => ({ room, rows: rows.sort(timelineSort) }))
    .sort((left, right) => {
      if (left.room === 'execution') return -1
      if (right.room === 'execution') return 1
      return left.room.localeCompare(right.room)
    })

  return {
    rooms,
    totalMessages: messageList.length,
    totalMentions,
    totalStateBlocks,
  }
}

function previewContent(message: Message): string {
  return stripStateBlocks(message.content).trim() || message.content.trim() || '(empty)'
}

function rowKey(row: TimelineRow): string {
  return row.message.id ?? `${row.message.seq ?? 'message'}-${row.index}`
}

function TimelineMessage({ row }: { row: TimelineRow }) {
  const preview = previewContent(row.message)
  return html`
    <article class="grid grid-cols-[3rem_minmax(0,1fr)] gap-3 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3.5 py-3">
      <div class="pt-0.5 text-right text-3xs font-semibold tabular-nums uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">
        ${row.message.seq !== undefined ? `#${row.message.seq}` : row.index + 1}
      </div>
      <div class="min-w-0">
        <div class="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1">
          <span class="text-xs font-semibold text-[var(--color-fg-secondary)]">${row.message.from ?? 'system'}</span>
          ${row.message.timestamp
            ? html`<span class="text-2xs tabular-nums text-[var(--color-fg-muted)]"><${TimeAgo} timestamp=${row.message.timestamp} /></span>`
            : null}
          ${row.message.type
            ? html`<span class="rounded-[var(--r-0)] border border-[var(--color-border-default)] px-2 py-0.5 text-3xs font-medium uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">${row.message.type}</span>`
            : null}
          ${row.stateBlockCount > 0
            ? html`
                <span class="inline-flex items-center gap-1 rounded-[var(--r-0)] border border-[var(--color-accent-soft)] bg-[var(--accent-10)] px-2 py-0.5 text-3xs font-medium text-[var(--color-accent-fg)]">
                  <${Braces} size=${11} aria-hidden="true" />
                  STATE ${row.stateBlockCount}
                </span>
              `
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
      </div>
    </article>
  `
}

export function MessageRoomTimeline() {
  const model = useMemo(() => buildMessageRoomModel(messages.value), [messages.value])
  const [selectedRoom, setSelectedRoom] = useState<string | null>(null)
  const activeRoom = model.rooms.some(room => room.room === selectedRoom)
    ? selectedRoom
    : model.rooms[0]?.room ?? null
  const active = activeRoom ? model.rooms.find(room => room.room === activeRoom) ?? null : null

  return html`
    <section class="grid gap-4" aria-labelledby="message-room-timeline-heading">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">Messages</div>
          <h2 id="message-room-timeline-heading" class="mt-1 text-xl font-semibold text-[var(--color-fg-primary)]">Room timeline</h2>
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
          <div class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">Rooms</div>
          <div class="mt-1 text-lg font-semibold tabular-nums text-[var(--color-fg-primary)]">${model.rooms.length}</div>
        </div>
        <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2">
          <div class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">Messages</div>
          <div class="mt-1 text-lg font-semibold tabular-nums text-[var(--color-fg-primary)]">${model.totalMessages}</div>
        </div>
        <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2">
          <div class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">Signals</div>
          <div class="mt-1 text-sm font-semibold tabular-nums text-[var(--color-fg-primary)]">${model.totalMentions} mentions · ${model.totalStateBlocks} state</div>
        </div>
      </div>

      ${model.rooms.length === 0
        ? html`<${EmptyState} message="메시지 타임라인이 없습니다" compact />`
        : html`
            <div class="flex flex-wrap gap-2" role="tablist" aria-label="Message rooms">
              ${model.rooms.map(room => html`
                <button
                  type="button"
                  role="tab"
                  aria-selected=${room.room === activeRoom}
                  class=${`rounded-[var(--r-1)] border px-3 py-1.5 text-xs font-medium transition-colors ${
                    room.room === activeRoom
                      ? 'border-[var(--color-accent)] bg-[var(--accent-10)] text-[var(--color-accent-fg)]'
                      : 'border-[var(--color-border-default)] bg-[var(--color-bg-surface)] text-[var(--color-fg-muted)] hover:bg-[var(--color-bg-hover)] hover:text-[var(--color-fg-primary)]'
                  }`}
                  onClick=${() => setSelectedRoom(room.room)}
                >
                  #${room.room}
                  <span class="ml-2 text-3xs tabular-nums opacity-70">${room.rows.length}</span>
                </button>
              `)}
            </div>
            <section role="tabpanel" aria-label=${active ? `#${active.room} timeline` : 'Message timeline'} class="grid gap-2.5">
              ${active?.rows.map(row => html`<${TimelineMessage} key=${rowKey(row)} row=${row} />`)}
            </section>
          `}
    </section>
  `
}
