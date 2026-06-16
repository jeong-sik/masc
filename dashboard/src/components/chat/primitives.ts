import { html } from 'htm/preact'
import { marked } from 'marked'
import DOMPurify from 'dompurify'
import { JsonViewerCard } from '../common/json-viewer'
import { useEffect, useMemo, useRef, useState } from 'preact/hooks'
import { ActionButton } from '../common/button'
import { useVoiceInput } from './voice-input'
import { formatTimeHms } from '../../lib/format-time'
import { formatCost } from '../../lib/format-number'
import { isSubmitEnter } from '../../lib/keyboard'
import type { KeeperConversationAttachment, KeeperConversationAudioClip, KeeperConversationDetails, KeeperConversationEntry, SurfaceRef } from '../../types'
import type { ToolCallOutputBlob } from '../../api/dashboard'
import { lookupToolCallOutput } from '../../tool-call-output-store'

function surfaceLink(surface?: SurfaceRef | null): { url: string; label: string; icon: string } | null {
  if (!surface || !surface.kind) return null
  switch (surface.kind) {
    case 'discord':
      if (surface.channel_id) {
        const targetId = surface.thread_id || surface.channel_id
        const guild = surface.guild_id || '@me'
        return {
          url: `https://discord.com/channels/${guild}/${targetId}`,
          label: surface.thread_id ? 'Discord Thread' : 'Discord Channel',
          icon: '🎮',
        }
      }
      break
    case 'slack':
      if (surface.channel_id) {
        const team = surface.team_id ? `&team=${surface.team_id}` : ''
        return {
          url: `https://slack.com/app_redirect?channel=${surface.channel_id}${team}`,
          label: 'Slack Channel',
          icon: '💬',
        }
      }
      break
    case 'github':
      if (surface.repo) {
        const path = surface.notification_id ? `/notifications/${surface.notification_id}` : ''
        return {
          url: `https://github.com/${surface.repo}${path}`,
          label: `GitHub: ${surface.repo}`,
          icon: '🐙',
        }
      }
      break
    case 'dashboard':
      return {
        url: '#',
        label: 'Dashboard',
        icon: '💻',
      }
    case 'agent':
      return {
        url: '#',
        label: 'Agent (Self)',
        icon: '🤖',
      }
    case 'gate':
      return {
        url: '#',
        label: `Gate: ${surface.label || 'connector'}`,
        icon: '⚡',
      }
  }
  return null
}

type ChatTranscriptVariant = 'default' | 'messenger'
type ChatTranscriptSize = 'default' | 'primary'

function timeLabel(timestamp?: string | null): string | null {
  if (!timestamp) return null
  const value = new Date(timestamp)
  if (Number.isNaN(value.getTime())) return null
  return formatTimeHms(value.getTime() / 1000)
}

function deliveryLabel(entry: KeeperConversationEntry): string {
  switch (entry.delivery) {
    case 'queued':
      return 'queued'
    case 'sending':
      return 'sending'
    case 'streaming':
      if (entry.streamState === 'thinking') return 'thinking'
      return entry.streamState === 'finalizing' ? 'finalizing' : 'live'
    case 'timeout':
      return 'timeout'
    case 'error':
      return 'error'
    case 'interrupted':
      return 'interrupted'
    case 'history':
      return 'saved'
    default:
      return 'delivered'
  }
}

function liveMessageLabel(entry: KeeperConversationEntry): string | null {
  if (entry.text.trim()) return null
  if (entry.delivery === 'streaming') {
    if (entry.streamState === 'thinking') return '생각 중...'
    return entry.streamState === 'finalizing' ? '응답 마무리 중...' : '응답 작성 중...'
  }
  if (entry.delivery === 'sending') return '응답 연결 중...'
  if (entry.delivery === 'queued') return '응답 대기 중...'
  return null
}

function bubbleTone(entry: KeeperConversationEntry): string {
  if (entry.delivery === 'error' || entry.delivery === 'timeout' || entry.delivery === 'interrupted') return 'error'
  if (entry.role === 'user') return 'user'
  if (entry.role === 'assistant') return 'assistant'
  if (entry.role === 'tool') return 'tool'
  return 'system'
}

function showDeliveryBadge(entry: KeeperConversationEntry, variant: ChatTranscriptVariant): boolean {
  if (variant !== 'messenger') return true
  return entry.delivery !== 'history' && entry.delivery !== 'delivered'
}

function avatarLabel(entry: KeeperConversationEntry): string {
  if (entry.role === 'user') return '사용자'
  if (entry.label.trim()) return entry.label.trim()
  return entry.role
}

function avatarMonogram(entry: KeeperConversationEntry): string {
  const label = avatarLabel(entry)
  return label.slice(0, 2).toUpperCase()
}

function tokenSummary(details: KeeperConversationDetails | null | undefined): string | null {
  const total = details?.usage?.totalTokens
  return typeof total === 'number' && Number.isFinite(total) ? `${total} tok` : null
}

function detailSummary(details: KeeperConversationDetails | null | undefined): string[] {
  if (!details) return []
  return [
    typeof details.latencyMs === 'number' ? `${details.latencyMs} ms` : null,
    tokenSummary(details),
  ].filter((value): value is string => Boolean(value))
}

function formatCurrency(value?: number | null): string | null {
  if (typeof value !== 'number' || !Number.isFinite(value)) return null
  if (value === 0) return '$0.00'
  return formatCost(value) ?? null
}

function stateRows(stateBlock?: string | null): Array<{ label: string; value: string }> {
  if (!stateBlock) return []
  const labels = ['Goal', 'Progress', 'Next', 'Decisions', 'OpenQuestions', 'Constraints'] // state block parsing keys — keep English (API contract)
  return stateBlock
    .split('\n')
    .map(line => line.trim())
    .filter(Boolean)
    .map(line => {
      const match = labels.find(label => line.startsWith(`${label}:`))
      if (!match) return null
      return {
        label: match,
        value: line.slice(match.length + 1).trim(),
      }
    })
    .filter((row): row is { label: string; value: string } => Boolean(row && row.value))
}

function overviewRows(details: KeeperConversationDetails): Array<{ label: string; value: string }> {
  return [
    typeof details.latencyMs === 'number' ? { label: '지연', value: `${details.latencyMs} ms` } : null,
    typeof details.usage?.totalTokens === 'number' ? { label: '토큰', value: `${details.usage.totalTokens}` } : null,
    formatCurrency(details.costUsd) ? { label: '비용', value: formatCurrency(details.costUsd)! } : null,
    details.traceId ? { label: '트레이스', value: details.traceId } : null,
    typeof details.generation === 'number' ? { label: '세대', value: `${details.generation}` } : null,
  ].filter((row): row is { label: string; value: string } => Boolean(row))
}

function formatAttachmentSize(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) return '0 B'
  if (bytes < 1024) return `${Math.round(bytes)} B`
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
}

function isSafeAttachmentHref(attachment: KeeperConversationAttachment): boolean {
  if (attachment.type === 'image') return attachment.data.startsWith('data:image/')
  return (
    attachment.data.startsWith('data:text/')
    || attachment.data.startsWith('data:application/json')
  )
}

function isRenderableImageAttachment(attachment: KeeperConversationAttachment): boolean {
  return attachment.type === 'image' && attachment.data.startsWith('data:image/')
}

function attachmentMeta(attachment: KeeperConversationAttachment): string {
  return [attachment.mimeType, formatAttachmentSize(attachment.size)].filter(Boolean).join(' · ')
}

function LiveMessagePlaceholder({ label }: { label: string }) {
  return html`
    <div
      class="flex items-center gap-2 text-base leading-airy text-[var(--color-fg-secondary)]"
      data-chat-stream-placeholder
    >
      <span>${label}</span>
      <span class="inline-flex items-center gap-1" aria-hidden="true">
        <span class="h-1.5 w-1.5 rounded-full bg-[var(--color-fg-muted)] animate-pulse"></span>
        <span class="h-1.5 w-1.5 rounded-full bg-[var(--color-fg-muted)] animate-pulse"></span>
        <span class="h-1.5 w-1.5 rounded-full bg-[var(--color-fg-muted)] animate-pulse"></span>
      </span>
    </div>
  `
}

function renderAttachmentCard(attachment: KeeperConversationAttachment) {
  const canLink = isSafeAttachmentHref(attachment)
  const meta = attachmentMeta(attachment)
  const content = isRenderableImageAttachment(attachment)
    ? html`
        <img
          src=${attachment.data}
          alt=${attachment.name}
          class="max-h-52 w-full rounded-[var(--r-1)] object-contain"
          loading="lazy"
        />
      `
    : html`
        <div class="flex min-h-18 items-center gap-3 px-3 py-3">
          <span class="inline-flex h-9 w-11 shrink-0 items-center justify-center rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-panel-alt)] text-3xs font-semibold uppercase tracking-3 text-[var(--color-fg-muted)]">
            FILE
          </span>
          <div class="min-w-0">
            <div class="truncate text-xs font-semibold text-[var(--color-fg-secondary)]">${attachment.name}</div>
            <div class="mt-1 text-2xs text-[var(--color-fg-muted)]">${meta}</div>
          </div>
        </div>
      `

  return html`
    <div class="overflow-hidden rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)]">
      ${canLink
        ? html`
            <a
              href=${attachment.data}
              download=${attachment.name}
              class="block hover:bg-[var(--color-bg-hover)]"
              aria-label=${`${attachment.name} 내려받기`}
            >
              ${content}
            </a>
          `
        : content}
      ${isRenderableImageAttachment(attachment)
        ? html`
            <div class="border-t border-[var(--color-border-default)] px-3 py-2">
              <div class="truncate text-xs font-semibold text-[var(--color-fg-secondary)]">${attachment.name}</div>
              <div class="mt-1 text-2xs text-[var(--color-fg-muted)]">${meta}</div>
            </div>
          `
        : null}
    </div>
  `
}

function formatAudioDuration(seconds?: number | null): string {
  if (typeof seconds !== 'number' || !Number.isFinite(seconds) || seconds < 0) return ''
  const totalSec = Math.round(seconds)
  const min = Math.floor(totalSec / 60)
  const sec = totalSec % 60
  return `${min}:${sec.toString().padStart(2, '0')}`
}

// RFC-0235 P1/P3: user-gesture play button for synthesized assistant
// voice clips. Uses the native `<audio controls>` element (no autoplay).
function AudioPlayer({ clip }: { clip: KeeperConversationAudioClip }) {
  const duration = formatAudioDuration(clip.durationSec)
  return html`
    <div
      class="flex items-center gap-2 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2 py-1.5"
      data-chat-audio-clip
    >
      <audio
        controls
        preload="none"
        src=${clip.audioUrl ?? `/api/v1/voice/audio/${encodeURIComponent(clip.token)}`}
        class="h-8 max-w-[16rem]"
        aria-label=${clip.messageText || '음성 메시지'}
      />
      ${duration
        ? html`<span class="text-2xs tabular-nums text-[var(--color-fg-muted)]">${duration}</span>`
        : null}
      ${clip.deviceId
        ? html`<span class="text-2xs text-[var(--color-fg-muted)]" title=${`device: ${clip.deviceId}`}>🔊</span>`
        : null}
    </div>
  `
}

function ChatMessageBubble({
  entry,
  showMetadata = true,
  variant = 'default',
}: {
  entry: KeeperConversationEntry
  showMetadata?: boolean
  variant?: ChatTranscriptVariant
}) {
  const [expandedRaw, setExpandedRaw] = useState(false)
  const [rawExpandedRaw, setRawExpandedRaw] = useState(false)
  const [messageCollapsed, setMessageCollapsed] = useState(true)
  const expanded = showMetadata && expandedRaw
  const rawExpanded = showMetadata && rawExpandedRaw
  const liveLabel = liveMessageLabel(entry)
  const messageText = liveLabel ? '' : entry.text || '(empty reply)'
  const messageLength = messageText.length
  const collapseThreshold = 1200
  const isCollapsible = messageLength > collapseThreshold
  const tone = bubbleTone(entry)
  const isMessenger = variant === 'messenger'
  const detailItems = detailSummary(entry.details)
  const canExpand = showMetadata && !!entry.details
  const overview = entry.details ? overviewRows(entry.details) : []
  const state = stateRows(entry.details?.stateBlock)
  const delivery = deliveryLabel(entry)
  const timestamp = timeLabel(entry.timestamp)
  const attachments = entry.attachments ?? []
  const surfaceInfo = surfaceLink(entry.surface)

  return html`
    <article
      class=${`chat-bubble ${tone} flex w-full flex-col border backdrop-blur-sm ${
        isMessenger
          ? 'max-w-[82%] gap-2.5 rounded-[var(--radius-xl)] px-4 py-3.5'
          : 'max-w-[90%] gap-3 rounded-[var(--r-5)] px-4 py-3'
      }`}
      data-chat-variant=${variant}
    >
      <div class=${`flex justify-between gap-3 ${isMessenger ? 'items-center' : 'items-start'}`}>
        <div class=${`flex min-w-0 flex-1 gap-3 ${isMessenger ? 'items-center' : 'items-start'}`}>
          <div
            class=${`chat-avatar ${tone} flex shrink-0 items-center justify-center border text-2xs font-semibold uppercase tracking-[var(--track-caps)] ${
              isMessenger ? 'size-8 rounded-card' : 'size-10 rounded-[var(--r-1)]'
            }`}
          >
            ${avatarMonogram(entry)}
          </div>
          <div class="min-w-0 flex-1">
            ${isMessenger
              ? html`
                  <div class="flex flex-wrap items-center gap-x-2 gap-y-1">
                    <span class="truncate text-xs font-semibold text-[var(--color-fg-secondary)]">
                      ${avatarLabel(entry)}
                    </span>
                    ${timestamp
                      ? html`<span class="text-2xs tabular-nums text-[var(--color-fg-muted)]">${timestamp}</span>`
                      : null}
                    ${showDeliveryBadge(entry, variant)
                      ? html`
                          <span
                            class="inline-flex items-center rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2 py-0.5 text-3xs font-medium uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]"
                            data-chat-delivery=${delivery}
                          >
                            ${delivery}
                          </span>
                        `
                      : null}
                    ${surfaceInfo && surfaceInfo.url !== '#'
                      ? html`
                          <a
                            href=${surfaceInfo.url}
                            target="_blank"
                            rel="noopener noreferrer"
                            class="inline-flex items-center gap-1 rounded-[var(--r-0)] border border-[var(--accent-20)] bg-[var(--accent-10)] px-2 py-0.5 text-3xs font-medium text-[var(--color-accent-fg)] hover:bg-[var(--accent-20)]"
                            title=${surfaceInfo.label}
                          >
                            <span>${surfaceInfo.icon}</span>
                            <span>${surfaceInfo.label}</span>
                          </a>
                        `
                      : surfaceInfo
                      ? html`
                          <span
                            class="inline-flex items-center gap-1 rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2 py-0.5 text-3xs font-medium text-[var(--color-fg-muted)]"
                            title=${surfaceInfo.label}
                          >
                            <span>${surfaceInfo.icon}</span>
                            <span>${surfaceInfo.label}</span>
                          </span>
                        `
                      : null}
                  </div>
                `
              : html`
                  <div class="flex flex-wrap items-center gap-1.5">
                    <span
                      class=${`chat-role-chip ${tone} inline-flex items-center rounded-[var(--r-0)] border px-2.5 py-1 text-3xs font-semibold uppercase tracking-3`}
                    >
                      ${entry.label}
                    </span>
                    ${showDeliveryBadge(entry, variant)
                      ? html`
                          <span
                            class="inline-flex items-center rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2.5 py-1 text-3xs font-medium uppercase tracking-2 text-[var(--color-fg-muted)]"
                            data-chat-delivery=${delivery}
                          >
                            ${delivery}
                          </span>
                        `
                      : null}
                    ${timestamp
                      ? html`
                          <span class="inline-flex items-center rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-panel-alt)] px-2.5 py-1 text-3xs font-medium tabular-nums text-[var(--color-fg-muted)]">
                            ${timestamp}
                          </span>
                        `
                      : null}
                    ${surfaceInfo && surfaceInfo.url !== '#'
                      ? html`
                          <a
                            href=${surfaceInfo.url}
                            target="_blank"
                            rel="noopener noreferrer"
                            class="inline-flex items-center gap-1 rounded-[var(--r-0)] border border-[var(--accent-20)] bg-[var(--accent-10)] px-2.5 py-1 text-3xs font-medium text-[var(--color-accent-fg)] hover:bg-[var(--accent-20)]"
                            title=${surfaceInfo.label}
                          >
                            <span>${surfaceInfo.icon}</span>
                            <span>${surfaceInfo.label}</span>
                          </a>
                        `
                      : surfaceInfo
                      ? html`
                          <span
                            class="inline-flex items-center gap-1 rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-panel-alt)] px-2.5 py-1 text-3xs font-medium text-[var(--color-fg-muted)]"
                            title=${surfaceInfo.label}
                          >
                            <span>${surfaceInfo.icon}</span>
                            <span>${surfaceInfo.label}</span>
                          </span>
                        `
                      : null}
                  </div>
                  <div class="mt-2 truncate text-sm font-semibold text-[var(--color-fg-secondary)]">
                    ${avatarLabel(entry)}
                  </div>
                `}
          </div>
        </div>
        ${canExpand
          ? html`
              <button
                type="button"
                class=${`border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] text-2xs font-medium text-[var(--color-fg-muted)] transition-colors hover:bg-[var(--color-bg-hover)] hover:text-[var(--color-fg-primary)] ${
                  isMessenger ? 'rounded-[var(--r-1)] px-2.5 py-1' : 'rounded-[var(--r-0)] px-3 py-1'
                }`}
                onClick=${() => { setExpandedRaw(!expandedRaw) }}
                aria-expanded=${expanded}
              >
                ${expanded ? '상세 숨기기' : '상세 보기'}
              </button>
            `
          : null}
      </div>

      ${showMetadata && detailItems.length > 0
        ? html`<div class=${`flex flex-wrap gap-1.5 ${isMessenger ? 'pt-0.5' : ''}`}>
            ${detailItems.map(item => html`
              <span class="inline-flex items-center rounded-[var(--r-0)] border border-[var(--color-accent-soft)] bg-[var(--accent-10)] px-2.5 py-1 text-3xs font-medium text-[var(--color-fg-secondary)]">
                ${item}
              </span>
            `)}
          </div>`
        : null}

      ${liveLabel
        ? html`<${LiveMessagePlaceholder} label=${liveLabel} />`
        : html`
            <div
              class=${`markdown-body whitespace-pre-wrap break-words text-base leading-airy text-[var(--color-fg-primary)] ${isCollapsible && messageCollapsed ? 'max-h-96 overflow-hidden' : ''}`}
              dangerouslySetInnerHTML=${{
                __html: DOMPurify.sanitize(
                  marked.parse(messageText) as string,
                  { ALLOWED_TAGS: ['p', 'br', 'strong', 'em', 'code', 'pre', 'ul', 'ol', 'li', 'h1', 'h2', 'h3', 'h4', 'blockquote', 'a', 'hr'] }
                )
              }}
            />
            ${entry.delivery === 'streaming'
              ? html`<span class="inline-block ml-0.5 animate-pulse text-[var(--color-status-info)]" aria-hidden="true">▍</span>`
              : null}
          `}
      ${isCollapsible
        ? html`
            <button
              type="button"
              class="self-start rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-1 text-2xs font-medium text-[var(--color-fg-muted)] transition-colors hover:bg-[var(--color-bg-hover)] hover:text-[var(--color-fg-primary)]"
              onClick=${() => { setMessageCollapsed(!messageCollapsed) }}
            >
              ${messageCollapsed ? '더 보기' : '접기'}
            </button>
          `
        : null}
      ${attachments.length > 0
        ? html`
            <div class="grid grid-cols-[repeat(auto-fit,minmax(11rem,1fr))] gap-2">
              ${attachments.map(attachment => renderAttachmentCard(attachment))}
            </div>
          `
        : null}
      ${entry.audio
        ? html`<${AudioPlayer} clip=${entry.audio} />`
        : null}
      ${entry.error
        ? html`
            <div class="rounded-[var(--r-1)] border border-[var(--err-border)] bg-[var(--bad-soft)] px-3 py-2 text-xs leading-paragraph text-[var(--bad-light)]">
              ${entry.error}
            </div>
          `
        : null}

      ${expanded && entry.details
        ? html`
            <div class="chat-detail-panel rounded-card border border-[var(--color-border-default)] px-3 py-3">
              ${overview.length > 0
                ? html`
                    <div class="grid grid-cols-[repeat(auto-fit,minmax(116px,1fr))] gap-2">
                      ${overview.map(item => html`
                        <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2.5">
                          <div class="text-3xs font-semibold uppercase tracking-3 text-[var(--color-fg-muted)]">${item.label}</div>
                          <div class="mt-1 text-sm font-semibold text-[var(--color-fg-secondary)]">${item.value}</div>
                        </div>
                      `)}
                    </div>
                  `
                : null}
              ${entry.details.skillPrimary
                ? html`
                    <div class="chat-detail-callout rounded-[var(--r-1)] border border-[var(--ok-border)] px-3 py-3">
                      <div class="text-3xs font-semibold uppercase tracking-3 text-[var(--ok-fg)]">스킬 경로</div>
                      <div class="mt-1 text-sm font-semibold text-[var(--ok-fg)]">${entry.details.skillPrimary}</div>
                      ${entry.details.skillReason
                        ? html`<div class="mt-1 text-xs leading-loose text-[var(--ok-fg)]">${entry.details.skillReason}</div>`
                        : null}
                    </div>
                  `
                : null}
              ${state.length > 0
                ? html`
                    <div class="flex flex-col gap-2">
                      <div class="text-3xs font-semibold uppercase tracking-3 text-[var(--color-fg-muted)]">상태 스냅샷</div>
                      <div class="grid grid-cols-[repeat(auto-fit,minmax(116px,1fr))] gap-2">
                        ${state.map(item => html`
                          <div class="rounded-[var(--r-1)] border border-[var(--color-accent-soft)] bg-[var(--accent-6)] px-3 py-2.5">
                            <div class="text-3xs font-semibold uppercase tracking-2 text-[var(--color-accent-fg)]">${item.label}</div>
                            <div class="mt-1 text-xs leading-paragraph text-[var(--color-fg-primary)]">${item.value}</div>
                          </div>
                        `)}
                      </div>
                    </div>
                  `
                : null}
              ${entry.details.rawPayload
                ? html`
                    <div class="flex flex-col gap-2">
                      <button
                        type="button"
                        class="self-start rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-1 text-2xs font-medium text-[var(--color-fg-muted)] transition-colors hover:bg-[var(--color-bg-hover)] hover:text-[var(--color-fg-primary)]"
                        onClick=${() => { setRawExpandedRaw(!rawExpandedRaw) }}
                      >
                        ${rawExpanded ? '원본 숨기기' : '원본 보기'}
                      </button>
                      ${rawExpanded
                        ? html`<div class="mt-2"><${JsonViewerCard} data=${entry.details.rawPayload} /></div>`
                        : null}
                    </div>
                  `
                : null}
            </div>
          `
        : null}
    </article>
  `
}

// Pretty-print a JSON-looking string; leave anything else untouched. Shared by
// the argument and output renderers so both read consistently.
function prettyJsonish(text: string): string {
  const trimmed = text.trimStart()
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
    try {
      return JSON.stringify(JSON.parse(text), null, 2)
    } catch {
      // not valid JSON — show as-is
    }
  }
  return text
}

// Reduce a tool-call output (inline string or externalised blob descriptor)
// to display text. Large outputs (e.g. keeper_context_status) are externalised
// to the blob store and only a ~200-char preview is persisted (#20910); the
// chat surfaces that preview and flags it truncated. The full bytes remain in
// the dedicated tool-call inspector via on-demand artifact hydration.
function toolOutputDisplay(
  output: string | ToolCallOutputBlob,
): { text: string; truncated: boolean } {
  if (typeof output === 'object' && output !== null && '_blob' in output) {
    return { text: prettyJsonish(output._blob.preview), truncated: true }
  }
  return { text: prettyJsonish(typeof output === 'string' ? output : ''), truncated: false }
}

const EMPTY_ARG_TEXTS = new Set(['', '{}', '[]'])
const TOOL_BUBBLE_PREVIEW_MAX = 120

// Compact collapsible card for tool call entries in the chat transcript.
// `entry.text` carries the tool call's INPUT arguments only — accumulated
// arg JSON from TOOL_CALL_ARGS (keeper-stream.ts) or the persisted arg row
// (keeper-state.ts:507 "text = accumulated argument JSON"). The tool's
// OUTPUT (result) is NOT in this entry; it lands in the live trace via
// `appendLiveToolCall` (sse.ts) and is joined below from the tool-call output
// store. Without an explicit "입력" (input) label and an empty-args marker, a
// no-argument tool like keeper_tools_list renders as `▸ {}`, which reads as
// "empty result". This surface labels args as input and renders `{}` as
// "입력 없음".
function ToolCallBubble({ entry }: { entry: KeeperConversationEntry }) {
  const [expanded, setExpanded] = useState(false)
  const timestamp = timeLabel(entry.timestamp)
  const toolName = entry.label || 'tool'
  const displayArgs = prettyJsonish(entry.text || '')
  const isEmptyArgs = EMPTY_ARG_TEXTS.has(displayArgs.trim())

  // Tool results never travel on the chat stream — they are joined here from
  // the tool-call output store by this row's id (`tool-<tool_use_id>`). Null
  // until that hydration lands, or for rows whose call had no provider id.
  const outputEntry = lookupToolCallOutput(entry.id)
  const outputView = outputEntry ? toolOutputDisplay(outputEntry.output) : null
  const hasOutput = outputView !== null && outputView.text.trim() !== ''

  // Collapsed glance prefers the result (the useful part for no-argument tools
  // like keeper_context_status, whose args are just `{}`); falls back to the
  // arguments until the output arrives. Empty args are labelled explicitly.
  const previewSource = hasOutput
    ? outputView.text
    : isEmptyArgs
      ? '입력 없음'
      : displayArgs
  const preview =
    previewSource.length > TOOL_BUBBLE_PREVIEW_MAX
      ? previewSource.slice(0, TOOL_BUBBLE_PREVIEW_MAX) + '...'
      : previewSource

  return html`
    <article
      class="chat-bubble tool flex w-full flex-col rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)]"
      data-chat-variant="tool-call"
    >
      <button
        type="button"
        class="flex w-full items-center gap-2 px-3 py-2 text-left hover:bg-[var(--color-bg-hover)] transition-colors"
        onClick=${() => { setExpanded(!expanded) }}
        aria-expanded=${expanded}
      >
        <span class="inline-flex size-5 shrink-0 items-center justify-center rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-panel-alt)] text-3xs font-mono font-bold text-[var(--color-fg-muted)]">T</span>
        <span class="font-mono text-xs font-medium text-[var(--color-accent-fg)] truncate">${toolName}</span>
        <span class="rounded-[var(--r-0)] border border-[var(--color-border-default)] px-1.5 py-0.5 text-3xs font-medium text-[var(--color-fg-muted)]">입력</span>
        ${outputEntry
          ? html`<span
              class=${`text-2xs ${outputEntry.success ? 'text-[var(--color-ok-fg)]' : 'text-[var(--color-status-err)]'}`}
              title=${outputEntry.success ? 'tool succeeded' : 'tool failed'}
              aria-label=${outputEntry.success ? 'tool succeeded' : 'tool failed'}
            >${outputEntry.success ? '✓' : '✗'}</span>`
          : null}
        ${timestamp
          ? html`<span class="ml-auto text-2xs tabular-nums text-[var(--color-fg-muted)]">${timestamp}</span>`
          : null}
        <span class="ml-1 text-xs text-[var(--color-fg-muted)]">${expanded ? '▾' : '▸'}</span>
      </button>
      ${expanded
        ? html`
            <div class="flex flex-col gap-2 border-t border-[var(--color-border-default)] px-3 py-2">
              ${isEmptyArgs
                ? html`<div class="text-2xs font-mono text-[var(--color-fg-muted)]">입력 없음 (매개변수가 없는 도구)</div>`
                : html`
                    <div>
                      <div class="mb-1 text-3xs font-semibold uppercase tracking-5 text-[var(--color-fg-muted)]">arguments</div>
                      <pre class="text-2xs font-mono whitespace-pre-wrap break-all text-[var(--color-fg-secondary)] max-h-48 overflow-y-auto">${displayArgs}</pre>
                    </div>
                  `}
              ${hasOutput
                ? html`
                    <div>
                      <div class="mb-1 flex items-center gap-1 text-3xs font-semibold uppercase tracking-5 text-[var(--color-fg-muted)]">
                        <span>output</span>
                        ${outputView.truncated
                          ? html`<span class="font-normal normal-case text-[var(--color-fg-muted)]">· truncated, see tool inspector</span>`
                          : null}
                      </div>
                      <pre class="text-2xs font-mono whitespace-pre-wrap break-all text-[var(--color-fg-secondary)] max-h-64 overflow-y-auto">${outputView.text}</pre>
                    </div>
                  `
                : null}
              ${!hasOutput
                ? isEmptyArgs
                  ? html`<div class="text-2xs text-[var(--color-fg-muted)]">출력 대기 중…</div>`
                  : html`<div class="text-3xs text-[var(--color-fg-muted)]">출력(결과)은 도구 실행 추적 패널에서 확인</div>`
                : null}
            </div>
          `
        : html`
            <div class="px-3 pb-2">
              <div class="truncate text-2xs font-mono text-[var(--color-fg-muted)]">${preview}</div>
            </div>
          `
      }
    </article>
  `
}

// A reader within this distance of the bottom is considered "pinned":
// new content keeps auto-scrolling. Scrolling further up unpins so the
// transcript stops yanking the viewport while old messages are read.
const STICK_TO_BOTTOM_THRESHOLD_PX = 80

export function ChatTranscript({
  entries,
  emptyText,
  showMetadata,
  variant = 'default',
  size = 'default',
}: {
  entries: KeeperConversationEntry[]
  emptyText: string
  showMetadata?: boolean
  variant?: ChatTranscriptVariant
  size?: ChatTranscriptSize
}) {
  const scrollerRef = useRef<HTMLDivElement | null>(null)
  const pinnedRef = useRef(true)
  const [unread, setUnread] = useState(false)
  const lastSignature = useMemo(
    () => entries.map(entry => `${entry.id}:${entry.text.length}:${entry.delivery}:${entry.streamState ?? ''}`).join('|'),
    [entries],
  )

  const scrollToBottom = () => {
    const el = scrollerRef.current
    if (!el) return
    el.scrollTop = el.scrollHeight
    pinnedRef.current = true
    setUnread(false)
  }

  const handleScroll = () => {
    const el = scrollerRef.current
    if (!el) return
    const distance = el.scrollHeight - el.scrollTop - el.clientHeight
    const pinned = distance <= STICK_TO_BOTTOM_THRESHOLD_PX
    pinnedRef.current = pinned
    if (pinned) setUnread(false)
  }

  useEffect(() => {
    const el = scrollerRef.current
    if (!el) return
    if (pinnedRef.current) {
      el.scrollTop = el.scrollHeight
    } else {
      setUnread(true)
    }
  }, [lastSignature])

  const isPrimary = size === 'primary'
  const heightClass = isPrimary
    ? 'min-h-0 flex-1'
    : 'min-h-75 max-h-130'

  return html`
    <div class=${`relative flex min-h-0 flex-col ${isPrimary ? 'flex-1' : ''}`}>
      <div
        class=${`chat-transcript ${isPrimary ? 'chat-transcript-airy' : ''} flex ${heightClass} flex-col overflow-y-auto ${
          isPrimary
            ? 'gap-5 rounded-[var(--r-2)] border border-transparent px-0 py-2 shadow-none'
            : variant === 'messenger'
            ? 'gap-4 rounded-[var(--radius-xl)] px-4 py-5 sm:px-5'
            : 'gap-3 rounded-[var(--radius-xl)] px-3 py-4'
        }`}
        data-chat-variant=${variant}
        data-chat-size=${size}
        ref=${scrollerRef}
        onScroll=${handleScroll}
      >
        ${entries.length === 0
          ? html`
              <div class="flex min-h-55 flex-col items-center justify-center rounded-card border border-dashed border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-6 text-center">
                <div class="text-2xs font-semibold uppercase tracking-5 text-[var(--color-fg-muted)]">직접 메시지 없음</div>
                <div class="mt-3 max-w-[34rem] text-sm leading-airy text-[var(--color-fg-secondary)]">${emptyText}</div>
              </div>
            `
          : entries.map(entry => entry.role === 'tool'
              ? html`<${ToolCallBubble} key=${entry.id} entry=${entry} />`
              : html`<${ChatMessageBubble} key=${entry.id} entry=${entry} showMetadata=${showMetadata !== false} variant=${variant} />`
          )}
      </div>
      ${unread
        ? html`
            <button
              type="button"
              class="absolute bottom-3 left-1/2 -translate-x-1/2 inline-flex items-center gap-1.5 rounded-full border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-3.5 py-1.5 text-2xs font-medium text-[var(--color-fg-primary)] shadow-[var(--shadow-raised)] transition-colors hover:bg-[var(--color-bg-hover)]"
              onClick=${scrollToBottom}
              data-chat-jump-latest
            >
              새 메시지 ↓
            </button>
          `
        : null}
    </div>
  `
}

// Streaming with no SSE event for longer than this is surfaced as a
// stall so the operator can tell "slow model" from "dead transport".
export const STREAM_STALL_THRESHOLD_S = 15

export function ChatComposer({
  draft,
  placeholder,
  disabled,
  streaming,
  streamStartedAt,
  lastEventAt,
  queueEnabled = false,
  queueCount = 0,
  onDraftChange,
  onSend,
  onAbort,
  layout = 'default',
}: {
  draft: string
  placeholder: string
  disabled: boolean
  streaming: boolean
  streamStartedAt?: number | null
  /** Wall-clock ms of the most recent stream event; drives the stall hint. */
  lastEventAt?: number | null
  /** When true, sending stays enabled during streaming — the host panel
   *  enqueues the message instead of dispatching it immediately. */
  queueEnabled?: boolean
  queueCount?: number
  onDraftChange: (value: string) => void
  onSend: () => void
  onAbort?: () => void
  layout?: 'default' | 'primary'
}) {
  const [elapsed, setElapsed] = useState(0)

  // RFC-0236 P1: speak to compose. Transcribed text appends to the draft at a
  // newline; an empty draft is replaced outright. Send stays manual (no
  // auto-send) so the operator can correct a transcription before it lands.
  const voice = useVoiceInput({
    onTranscribed: (text) => {
      onDraftChange(draft.trim() === '' ? text : `${draft}\n${text}`)
    },
  })

  useEffect(() => {
    if (!streaming || !streamStartedAt) {
      setElapsed(0)
      return
    }
    const tick = () => setElapsed(Math.round((Date.now() - streamStartedAt) / 1000))
    tick()
    const id = setInterval(tick, 1000)
    return () => clearInterval(id)
  }, [streaming, streamStartedAt])

  // Derived from the 1 s elapsed tick above — no extra interval needed.
  const sinceLastEvent =
    streaming && typeof lastEventAt === 'number'
      ? Math.round((Date.now() - lastEventAt) / 1000)
      : null
  const isStalled = sinceLastEvent !== null && sinceLastEvent >= STREAM_STALL_THRESHOLD_S

  const canQueue = queueEnabled && streaming
  const streamLabel = streaming
    ? canQueue
      ? '대기열 추가'
      : `응답 중${elapsed > 0 ? ` ${elapsed}s` : ''}`
    : '보내기'
  const isStreamWarning = streaming && elapsed > 60
  const sendDisabled = disabled || draft.trim() === '' || (streaming && !queueEnabled)

  const isPrimary = layout === 'primary'

  return html`
    <div class="chat-composer flex flex-col gap-3">
      ${isPrimary ? null : html`
        <div class="flex flex-wrap items-center justify-between gap-2">
          <div class="text-2xs font-semibold uppercase tracking-4 text-[var(--color-fg-muted)]">메시지</div>
          <div class="text-2xs text-[var(--color-fg-muted)]">Enter로 전송, Shift+Enter로 줄바꿈</div>
        </div>
      `}
      <textarea
        class=${isPrimary
          ? 'control-textarea min-h-30 rounded-[var(--r-2)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)] px-4 py-4 text-base leading-loose'
          : 'control-textarea min-h-24 rounded-card border border-[var(--color-border-default)] bg-[var(--color-bg-panel-alt)] px-3 py-3 text-base leading-loose'}
        placeholder=${placeholder}
        aria-label="메시지 입력"
        value=${draft}
        onInput=${(event: Event) => { onDraftChange((event.target as HTMLTextAreaElement).value) }}
        onKeyDown=${(event: KeyboardEvent) => {
          if (isSubmitEnter(event) && !event.shiftKey) {
            event.preventDefault()
            if (!sendDisabled) {
              onSend()
            }
          }
        }}
        disabled=${disabled}
      ></textarea>
      <div class="flex flex-wrap items-center justify-between gap-2">
        <div class="flex min-w-0 flex-col gap-1">
          <div class="text-2xs leading-paragraph text-[var(--color-fg-muted)]">
            ${streaming
              ? canQueue
                ? '응답 스트리밍 중 — 지금 보내는 메시지는 대기열에 쌓였다가 차례로 전달됩니다.'
                : '키퍼 응답 스트림이 활성 상태입니다. 멈춘 것 같으면 중지할 수 있습니다.'
              : '직접 메시지만 이 레인에 표시됩니다. 내부 키퍼 프롬프트는 숨겨집니다.'}
          </div>
          ${isStalled
            ? html`
                <div class="text-2xs font-medium text-[var(--color-status-warn)]" data-chat-stall-hint>
                  마지막 수신 ${sinceLastEvent}초 전 — 스트림이 지연되고 있습니다. 계속 멈춰 있으면 중지 후 다시 시도하세요.
                </div>
              `
            : null}
        </div>
        <div class="flex gap-2 items-center">
        ${queueCount > 0
          ? html`
              <span
                class="inline-flex items-center rounded-full border border-[var(--accent-20)] bg-[var(--accent-10)] px-2.5 py-1 text-2xs font-medium text-[var(--color-fg-secondary)]"
                data-chat-queue-count
              >
                대기 ${queueCount}
              </span>
            `
          : null}
        ${voice.supported ? html`
          <${ActionButton}
            variant=${voice.state === 'recording' ? 'danger' : 'ghost'}
            onClick=${() => (voice.state === 'recording' ? voice.stop() : voice.start())}
            disabled=${voice.state === 'transcribing' || disabled}
            aria-label=${voice.state === 'recording' ? '녹음 중지' : '음성으로 입력'}
            title=${voice.state === 'recording' ? '녹음 중지' : voice.state === 'transcribing' ? '음성 인식 중' : '음성으로 입력'}
          >${voice.state === 'recording' ? '■ 녹음중' : voice.state === 'transcribing' ? '전사 중…' : '🎤 음성'}<//>
        ` : null}
        <${ActionButton}
          variant=${isStreamWarning && !canQueue ? 'danger' : 'primary'}
          onClick=${onSend}
          disabled=${sendDisabled}
        >
          ${streamLabel}
        <//>
        ${streaming && onAbort
          ? html`
              <${ActionButton}
                variant="ghost"
                onClick=${onAbort}
              >
                중지${elapsed > 0 ? ` (${elapsed}s)` : ''}
              <//>
            `
          : null}
        </div>
      </div>
    </div>
  `
}
