// Keeper-v2 messages.jsx `CtxFrom` — the expandable provenance strip above a
// bubble when a turn belongs to a connector channel conversation
// ("#채널 맥락 포함 · 메시지 N개 · HH:MM–HH:MM", 범위 보기 → cf-detail preview).
//
// Live signal: KeeperConversationEntry.surface (RFC-0223 connector
// coordinates: kind / guild_id / channel_id / thread_id / label) plus
// conversation_id grouping and speaker_id/speaker_name identity. The backend
// does not ship a "fetched context scope" payload, so the preview is derived
// from the transcript itself: the channel conversation's own rows in this
// history (same conversation_id, else same channel coordinates). Nothing is
// invented — msgs/range/preview are counts and excerpts of rows the keeper
// actually exchanged on that channel.

import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
import type { VNode } from 'preact'
import type { KeeperConversationEntry } from '../../types'

export interface ChatContextScopeMessage {
  ts: string
  who: string
  text: string
}

export interface ChatContextScope {
  channel: string
  guild: string | null
  via: string
  msgs: number
  range: string | null
  preview: ChatContextScopeMessage[]
}

const PREVIEW_LIMIT = 3
const PREVIEW_TEXT_CHARS = 120

// Connector surfaces that carry channel coordinates. 'dashboard' and 'agent'
// are first-party routes, not channel context, so they never get the strip.
export function chatContextScopeEligible(entry: KeeperConversationEntry): boolean {
  const surface = entry.surface
  if (!surface || !surface.channel_id?.trim()) return false
  return surface.kind !== 'dashboard' && surface.kind !== 'agent'
}

function sameChannelConversation(
  entry: KeeperConversationEntry,
  other: KeeperConversationEntry,
): boolean {
  const conversationId = entry.conversationId?.trim()
  if (conversationId) return other.conversationId?.trim() === conversationId
  const surface = entry.surface
  const otherSurface = other.surface
  if (!surface || !otherSurface) return false
  return (
    otherSurface.kind === surface.kind
    && otherSurface.channel_id === surface.channel_id
    && (otherSurface.thread_id ?? '') === (surface.thread_id ?? '')
  )
}

// Design cf-ts is a 24h mono "HH:MM" column; the shared ko-KR formatter emits
// 12-hour "오후 2:05", so format locally to keep the design vocabulary.
function formatHm(ms: number): string {
  const d = new Date(ms)
  return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`
}

function scopeTimestamp(timestamp?: string | null): string | null {
  if (!timestamp) return null
  const ms = new Date(timestamp).getTime()
  if (Number.isNaN(ms)) return null
  return formatHm(ms)
}

// Design rows show the channel handle ('@sangsu'); speaker_name is the
// display nick, speaker_id the handle. Fall back to the entry label (keeper
// id for assistant rows) when the connector supplied neither.
function previewWho(entry: KeeperConversationEntry): string {
  const handle = entry.speakerName?.trim() || entry.speakerId?.trim()
  if (handle) return handle.startsWith('@') ? handle : `@${handle}`
  return entry.label
}

function previewText(text: string): string {
  const collapsed = text.replace(/\s+/g, ' ').trim()
  return collapsed.length > PREVIEW_TEXT_CHARS
    ? `${collapsed.slice(0, PREVIEW_TEXT_CHARS)}…`
    : collapsed
}

export function buildChatContextScope(
  entry: KeeperConversationEntry,
  transcriptEntries: readonly KeeperConversationEntry[],
): ChatContextScope | null {
  if (!chatContextScopeEligible(entry)) return null
  const surface = entry.surface
  if (!surface) return null

  const scopeEntries = transcriptEntries.filter(other =>
    (other.role === 'user' || other.role === 'assistant')
    && other.text.trim().length > 0
    && sameChannelConversation(entry, other),
  )
  if (scopeEntries.length === 0) return null

  const firstTs = scopeTimestamp(scopeEntries[0]?.timestamp)
  const lastTs = scopeTimestamp(scopeEntries[scopeEntries.length - 1]?.timestamp)
  const range = firstTs && lastTs
    ? firstTs === lastTs ? firstTs : `${firstTs}–${lastTs}`
    : null

  return {
    channel: surface.label?.trim() || `#${surface.channel_id}`,
    guild: surface.guild_id?.trim() || null,
    via: surface.kind,
    msgs: scopeEntries.length,
    range,
    preview: scopeEntries.slice(-PREVIEW_LIMIT).map(other => ({
      ts: scopeTimestamp(other.timestamp) ?? '--:--',
      who: previewWho(other),
      text: previewText(other.text),
    })),
  }
}

// Design: the Message header in messages.jsx renders `<span className="whoh">{handle}</span>`
// when a user row has both a nick and a handle. Live: speaker_name (nick) +
// speaker_id (handle) on RFC-0223 connector rows.
export function speakerHandleLabel(entry: KeeperConversationEntry): string | null {
  if (entry.role !== 'user') return null
  const nick = entry.speakerName?.trim()
  const handle = entry.speakerId?.trim()
  if (!nick || !handle) return null
  return handle.startsWith('@') ? handle : `@${handle}`
}

export function ChatSpeakerHandle({ entry }: { entry: KeeperConversationEntry }): VNode | null {
  const handle = speakerHandleLabel(entry)
  if (!handle) return null
  return html`<span class="whoh">${handle}</span>`
}

// DOM mirrors messages.jsx CtxFrom exactly: KVM.Provenance head
// (ctx-from / cf-ico / cf-view) + expandable cf-detail scope preview.
export function ChatContextScopeRow({ scope }: { scope: ChatContextScope }): VNode {
  const [open, setOpen] = useState(false)
  const hasPreview = scope.preview.length > 0

  const detailHeader = [
    scope.guild,
    scope.channel,
    `${scope.via} 가 가져온 ${scope.msgs}개 중 일부`,
  ].filter((part): part is string => Boolean(part)).join(' · ')

  const head = html`
    <div class="ctx-from">
      <span class="cf-ico">${'⌘'}</span>
      <div>
        <span>
          <b>${scope.channel}</b> 맥락 포함 · 메시지 ${scope.msgs}개${scope.range ? ` · ${scope.range}` : ''}
        </span>
      </div>
      ${hasPreview
        ? html`
            <button
              type="button"
              class="cf-view"
              aria-expanded=${open ? 'true' : 'false'}
              onClick=${() => setOpen(o => !o)}
            >
              ${open ? '접기' : '범위 보기'}
            </button>
          `
        : null}
    </div>
  `

  if (!hasPreview) return head
  return html`
    <div class="ctx-from-wrap">
      ${head}
      ${open
        ? html`
            <div class="cf-detail">
              <div class="cf-detail-h">${detailHeader}</div>
              ${scope.preview.map(message => html`
                <div class="cf-msg" key=${`${message.ts}:${message.who}`}>
                  <span class="cf-ts mono">${message.ts}</span>
                  <span class="cf-who">${message.who}</span>
                  <span class="cf-text">${message.text}</span>
                </div>
              `)}
            </div>
          `
        : null}
    </div>
  `
}
