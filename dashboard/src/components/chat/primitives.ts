import { html } from 'htm/preact'
import type { ComponentChildren, VNode } from 'preact'
import { JsonViewerCard } from '../common/json-viewer'
import { sanitizeHtml as purifyHtml } from '../../lib/dompurify'
import { escapeHtml } from '../../lib/html-escape'
import { useEffect, useId, useLayoutEffect, useMemo, useRef, useState } from 'preact/hooks'
import { ringFocusClasses } from '../common/ring'
import { ATTACHMENT_INPUT_ACCEPT, collectAttachments } from './attachments'
import { linkifyHtmlReferences } from './chat-linkify'
import { UNREAD_DIVIDER_LABEL, unreadDividerAnchorKey } from './unread-divider'
import { buildChatContextScope, ChatContextScopeRow, ChatSpeakerHandle } from './message-context-scope'
import type { ChatContextScope } from './message-context-scope'
import { showToast } from '../common/toast'
import { copyToClipboard } from '../common/copyable-code'
import { ArrowRight, ExternalLink, Mic, ShieldCheck, Square } from 'lucide-preact'
import { normalizeToolName, prettyJson, toolSubject } from '../tool-call-shared'
import { useVoiceInput } from './voice-input'

const CHAT_FOCUS_RING = ringFocusClasses({ tone: 'accent-medium', width: 2 })
import { formatTimeHms } from '../../lib/format-time'
import { formatCost, formatMsCompact } from '../../lib/format-number'
import { isSubmitEnter } from '../../lib/keyboard'
import { isFailedDelivery } from '../../lib/keeper-delivery'
import { memo } from 'preact/compat'
import { readKeeperDraft, writeKeeperDraft } from '../../keeper-chat-store'
import type { ChatBlock, ChatBroadcastBlock, ChatCalloutBlock, ChatChartBlock, ChatIssueBlock, ChatLinkBlock, ChatMermaidBlock, ChatShellBlock, ChatSuggestionsBlock, ChatTableBlock, ChatTraceStep, ChatTraceToolStep, ChatVoiceBlock, KeeperUserInputBlock } from '../../types'
import type { KeeperApprovalLifecycle, KeeperConversationAttachment, KeeperConversationAudioClip, KeeperConversationDetails, KeeperConversationEntry, KeeperConversationSource, SurfaceRef } from '../../types'
import type { ToolCallEntry, ToolCallOutputBlob } from '../../api/dashboard'
import { fetchBoardPost } from '../../api/board'
import { lookupToolCallOutput, toolCallOutputsByExecutionId } from '../../tool-call-output-store'
import type { ToolCallOutputHydrationContract } from '../../tool-call-output-store'
import { Sigil } from '../common/sigil-chip'
import { SuggestionChip } from '../common/suggestion-chip'
import { StatusDot } from '../common/status-dot'
import { useInViewOnce } from '../common/use-in-view'
import { hasMarkdownRenderCue } from './markdown-cue'
import type { JSX } from 'preact'
import { navigate } from '../../router'
import { normalizeFusionPanelReason } from '../../lib/fusion-meta'
import { fusionDecisionSpec } from '../v2/fusion-constants'
import { STREAMING_THINKING_PREVIEW_CHARS } from '../../config/constants'

/** Keeper identity used by SigilBadge. */
export interface SigilBadgeKeeper {
  slot: number
  id: string
  sigil?: string
}

export interface ChatComposerSendPayload {
  blocks: ChatBlock[]
  userBlocks: KeeperUserInputBlock[]
  clientActionId: string
  /** The trimmed text entered by the operator at send time. Added so hosts can
      read the message without maintaining a mirrored controlled draft state. */
  text: string
}

export interface ChatComposerCommand {
  id: string
  group: string
  label: string
  hint?: string
  glyph?: string
  danger?: boolean
  disabled?: boolean
  disabledReason?: string
  run: () => void | Promise<void>
}

type TraceToolStatus = NonNullable<ChatTraceToolStep['status']>
type TraceSourceBadgeTone = 'stream' | 'tool' | 'reply' | 'warn'

interface TraceSourceBadgeInfo {
  label: string
  title: string
  tone: TraceSourceBadgeTone
}

// Tool 상태 문구 SSOT — TRACE_TOOL_STATUS_UI(TraceToolStatus)와
// TOOL_STATUS_TITLE(ToolTraceDisplayStatus)이 같은 UI 문구를 참조한다.
const TOOL_STATUS_TITLE_PENDING = '출력 대기 중'
const TOOL_STATUS_TITLE_OK = '성공'
const TOOL_STATUS_TITLE_BAD = '실패'

const TRACE_TOOL_STATUS_UI: Record<TraceToolStatus, { className: 'ok' | 'bad' | 'pending'; title: string }> = {
  pending: { className: 'pending', title: TOOL_STATUS_TITLE_PENDING },
  ok: { className: 'ok', title: TOOL_STATUS_TITLE_OK },
  err: { className: 'bad', title: TOOL_STATUS_TITLE_BAD },
}

export const CHAT_SUGGESTIONS_LABEL = '추천 후속 질문'

function traceToolStatusUi(status: ChatTraceToolStep['status']): { className: 'ok' | 'bad' | 'pending'; title: string } {
  return TRACE_TOOL_STATUS_UI[status ?? 'pending']
}

function traceSourceBadge(step: ChatTraceStep): TraceSourceBadgeInfo {
  // The stream content-block index (agentCoreBlockIndex) is provenance detail, not
  // an identity: it stays in the hover title and in the
  // data-chat-trace-agent-core-block-index attribute, while the visible label keeps
  // the stable channel name. An "Agent Core #3" badge told the operator nothing
  // about where the step came from (bug #11).
  if (step.kind === 'think') {
    return {
      label: 'thinking_delta',
      title: step.agentCoreBlockIndex === undefined
        ? 'source: KEEPER_THINKING_DELTA'
        : `source: KEEPER_THINKING_DELTA, content block ${step.agentCoreBlockIndex}`,
      tone: 'stream',
    }
  }
  if (step.kind === 'reason') {
    return {
      label: 'reason_trace',
      title: 'source: trace.kind=reason',
      tone: 'stream',
    }
  }
  if (step.kind === 'progress') {
    return {
      label: 'intermediate_text',
      title: step.agentCoreBlockIndex === undefined
        ? 'source: TEXT_MESSAGE_CONTENT followed by TOOL_CALL_START'
        : `source: TEXT_MESSAGE_CONTENT block ${step.agentCoreBlockIndex}, followed by TOOL_CALL_START`,
      tone: 'stream',
    }
  }
  const callId = step.toolCallId?.trim()
  if (callId) {
    return {
      label: 'tool_call_id',
      title: step.agentCoreBlockIndex === undefined
        ? `source: TOOL_CALL_*, tool_call_id=${callId}`
        : `source: TOOL_CALL_*, tool_call_id=${callId}, content block ${step.agentCoreBlockIndex}`,
      tone: 'tool',
    }
  }
  const executionId = step.executionId?.trim()
  if (executionId) {
    return {
      label: 'execution_id',
      title: `source: trace.kind=tool, execution_id=${executionId}`,
      tone: 'tool',
    }
  }
  return {
    label: 'unlinked_trace',
    title: 'source: trace.kind=tool without provider or canonical identity',
    tone: 'warn',
  }
}

function TraceSourceBadge({ info }: { info: TraceSourceBadgeInfo }) {
  return html`
    <span
      class=${`chat-block-source-badge ${info.tone}`}
      title=${info.title}
      data-chat-trace-provenance=${info.label}
    >
      ${info.label}
    </span>
  `
}

/** Status dot wrapper — maps keeper-v2 status strings to shared StatusDot tones. */
export function ChatStatusDot({ status, pulse }: { status: string; pulse?: boolean }): VNode {
  const state = status === 'run' ? 'ok' : status === 'pause' ? 'warn' : status === 'off' ? 'idle' : status
  const toneClass = `bg-[var(--color-status-${state})]`
  return html`
    <${StatusDot}
      class=${`${toneClass}${pulse ? ' animate-pulse' : ''}`}
      ariaLabel=${state}
    />
  `
}

/** Canonical keeper identity badge — delegates to the shared Sigil primitive. */
export function ChatSigilBadge({ k, size = 18, beat }: { k: SigilBadgeKeeper; size?: number; beat?: boolean }): VNode {
  const monogram = k.sigil ?? k.id.slice(0, 2).toUpperCase()
  return html`
    <${Sigil}
      slot=${k.slot}
      size=${size}
      heartbeat=${beat}
      title=${k.id}
      fontScale=${0.46}
    >${monogram}<//>
  `
}

/** Suggestion chip wrapper — delegates to the shared SuggestionChip primitive. */
export function ChatSuggestionChip({
  pre = '\u2192',
  children,
  ...rest
}: {
  pre?: string
  children?: ComponentChildren
} & JSX.HTMLAttributes<HTMLButtonElement>): VNode {
  return html`<${SuggestionChip} pre=${pre} ...${rest}>${children}<//>`
}

type ChatMetaInfo = {
  url?: string
  label: string
  icon: string
  title: string
  tone?: 'accent' | 'default'
}

function compactIdentifier(value?: string | null, head = 6, tail = 4): string | null {
  const normalized = value?.trim()
  if (!normalized) return null
  if (normalized.length <= head + tail + 1) return normalized
  return `${normalized.slice(0, head)}…${normalized.slice(-tail)}`
}

function compactKeyValues(fields: Array<[string, string | null | undefined]>): string {
  return fields
    .map(([key, value]) => {
      const normalized = value?.trim()
      return normalized ? `${key}=${normalized}` : null
    })
    .filter((value): value is string => value !== null)
    .join(' · ')
}

function gateAddressValue(surface: SurfaceRef, ...keys: string[]): string | null {
  const address = surface.address
  if (!address) return null
  for (const key of keys) {
    const value = address[key]?.trim()
    if (value) return value
  }
  return null
}

function surfaceLink(surface?: SurfaceRef | null): ChatMetaInfo | null {
  if (!surface || !surface.kind) return null
  switch (surface.kind) {
    case 'discord':
      if (surface.channel_id) {
        const targetId = surface.thread_id || surface.channel_id
        const guild = surface.guild_id || '@me'
        const labelTarget = compactIdentifier(targetId) ?? targetId
        const title = compactKeyValues([
          ['surface', surface.thread_id ? 'discord_thread' : 'discord_channel'],
          ['guild_id', surface.guild_id || '@me'],
          ['channel_id', surface.channel_id],
          ['parent_channel_id', surface.parent_channel_id],
          ['thread_id', surface.thread_id],
        ])
        return {
          url: `https://discord.com/channels/${guild}/${targetId}`,
          label: `${surface.thread_id ? 'Discord Thread' : 'Discord Channel'} ${labelTarget}`,
          icon: '🎮',
          title,
          tone: 'accent',
        }
      }
      break
    case 'slack':
      if (surface.channel_id) {
        const team = surface.team_id ? `&team=${surface.team_id}` : ''
        const labelTarget = compactIdentifier(surface.channel_id) ?? surface.channel_id
        const title = compactKeyValues([
          ['surface', 'slack_channel'],
          ['team_id', surface.team_id],
          ['channel_id', surface.channel_id],
          ['thread_ts', surface.thread_ts],
        ])
        return {
          url: `https://slack.com/app_redirect?channel=${surface.channel_id}${team}`,
          label: `Slack Channel ${labelTarget}`,
          icon: '💬',
          title,
          tone: 'accent',
        }
      }
      break
    // dashboard / agent / broadcast / webhook rows carry no link or
    // coordinates beyond what the origin badge (sourceBadgeInfo) already
    // shows, so they render no meta chip — the chip lane is for surfaces
    // with a destination (deep link) or an address to inspect.
    case 'gate':
      {
        const label = surface.label || 'connector'
        const workspace = gateAddressValue(surface, 'workspace_id', 'channel_workspace_id')
        const labelSuffix = compactIdentifier(workspace)
        const titleFields: Array<[string, string | null | undefined]> = [
          ['surface', 'gate'],
          ['label', label],
        ]
        if (surface.address) {
          for (const [key, value] of Object.entries(surface.address)) {
            titleFields.push([key, value])
          }
        }
        return {
          url: '#',
          label: `Gate: ${label}${labelSuffix ? ` · ${labelSuffix}` : ''}`,
          icon: '⚡',
          title: compactKeyValues(titleFields),
        }
      }
  }
  return null
}

function speakerMeta(entry: KeeperConversationEntry): ChatMetaInfo | null {
  const speakerId = entry.speakerId?.trim()
  const speakerName = entry.speakerName?.trim()
  const authority = entry.speakerAuthority?.trim()
  if (!speakerId && !speakerName && !authority) return null
  const label = speakerName || compactIdentifier(speakerId) || authority || 'speaker'
  return {
    label,
    icon: '👤',
    title: compactKeyValues([
      ['speaker_name', speakerName],
      ['speaker_id', speakerId],
      ['speaker_authority', authority],
    ]),
  }
}

function routeMeta(entry: KeeperConversationEntry): ChatMetaInfo | null {
  const conversationId = entry.conversationId?.trim()
  const externalMessageId = entry.externalMessageId?.trim()
  if (!conversationId && !externalMessageId) return null
  const labelId = compactIdentifier(externalMessageId || conversationId)
  return {
    label: labelId ? `ctx ${labelId}` : 'ctx',
    icon: '⌁',
    title: compactKeyValues([
      ['conversation_id', conversationId],
      ['external_message_id', externalMessageId],
    ]),
  }
}

function ChatMetaChip({ info, compact }: { info: ChatMetaInfo | null; compact: boolean }) {
  if (!info) return null
  const paddingClass = compact ? 'px-2 py-0.5' : 'px-2.5 py-1'
  const toneClass = info.tone === 'accent'
    ? `border-[var(--accent-20)] bg-[var(--accent-10)] text-[var(--color-accent-fg)]`
    : `border-[var(--color-border-default)] bg-[var(--color-bg-surface)] text-[var(--color-fg-secondary)]`
  if (info.url && info.url !== '#') {
    return html`
      <a
        href=${info.url}
        target="_blank"
        rel="noopener noreferrer"
        class=${`inline-flex items-center gap-1 rounded-[var(--r-0)] border ${toneClass} ${paddingClass} text-2xs font-semibold hover:bg-[var(--accent-20)] ${CHAT_FOCUS_RING}`}
        title=${info.title}
        data-chat-meta-chip=${info.label}
      >
        <span>${info.icon}</span>
        <span>${info.label}</span>
      </a>
    `
  }
  return html`
    <span
      class=${`inline-flex items-center gap-1 rounded-[var(--r-0)] border ${toneClass} ${paddingClass} text-2xs font-medium`}
      title=${info.title}
      data-chat-meta-chip=${info.label}
    >
      <span>${info.icon}</span>
      <span>${info.label}</span>
    </span>
  `
}

type ChatTranscriptVariant = 'default' | 'messenger'
type ChatTranscriptSize = 'default' | 'primary'
type ChatTranscriptAction = {
  label?: string
  title?: string
  onClick?: (entry: KeeperConversationEntry) => void
}

export const THINKING_TRACE_PREVIEW_CHARS = 2400

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
    case 'cancelled':
      return 'cancelled'
    case 'no_reply':
      return 'no reply'
    case 'error':
      return 'error'
    case 'transport_failure':
      return 'transport failure'
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
  if (isFailedDelivery(entry.delivery)) return 'error'
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

// C2: badge message provenance (#29461). Two axes feed one badge slot:
// 1. Semantic origins that are easy to mistake for a plain turn keep
//    their badge (world-state injection, internal prompt, tool result,
//    system) — they win because the surface says where a row travelled,
//    not what it is.
// 2. Every other row derives its badge from the typed origin the wire
//    already carries: entry.surface.kind × the row's speaker fields.
//    Dashboard rows are the operator's own input (live stores carry
//    owner authority on every dashboard user row), agent rows name the
//    sending keeper, broadcast rows mark workspace fleet fanout, and
//    connector rows name the connector. No surface, no badge — origin
//    is never guessed from content.
interface SourceBadgeInfo {
  label: string
  cls: string
  title?: string
}
const SEMANTIC_SOURCE_BADGE: Partial<Record<KeeperConversationSource, SourceBadgeInfo>> = {
  world_state_prompt: { label: '월드', cls: 'world' },
  internal_assistant: { label: '내부', cls: 'internal' },
  tool_result: { label: '도구', cls: 'tool' },
  system: { label: '시스템', cls: 'system' },
}
function surfaceBadgeTitle(entry: KeeperConversationEntry): string {
  return compactKeyValues([
    ['surface', entry.surface?.kind],
    ['speaker_name', entry.speakerName],
    ['speaker_id', entry.speakerId],
    ['speaker_authority', entry.speakerAuthority],
    ['external_message_id', entry.externalMessageId],
  ])
}
function sourceBadgeInfo(entry: KeeperConversationEntry): SourceBadgeInfo | null {
  const semantic = SEMANTIC_SOURCE_BADGE[entry.source]
  if (semantic) return semantic
  const surface = entry.surface
  if (!surface) return null
  const title = surfaceBadgeTitle(entry)
  switch (surface.kind) {
    case 'dashboard':
      return { label: '사람', cls: 'origin-dashboard', title }
    case 'broadcast':
      return { label: '브로드캐스트', cls: 'origin-broadcast', title }
    case 'discord':
      return { label: 'Discord', cls: 'origin-discord', title }
    case 'slack':
      return { label: 'Slack', cls: 'origin-slack', title }
    case 'agent': {
      const speaker = entry.speakerName?.trim() || entry.speakerId?.trim() || ''
      return { label: speaker || 'keeper', cls: 'origin-agent', title }
    }
    case 'webhook':
      return { label: surface.source?.trim() || 'Webhook', cls: 'origin-webhook', title }
    case 'gate':
      return { label: surface.label?.trim() || 'Gate', cls: 'origin-gate', title }
  }
}

type StreamContractBadgeInfo = {
  label: string
  title: string
  state: 'contract-gap' | 'no-turn-ref' | 'server-replay'
}

function streamContractBadgeInfo(entry: KeeperConversationEntry): StreamContractBadgeInfo | null {
  const contract = entry.streamContract
  if (!contract) return null
  const sourceContext = compactKeyValues([
    ['surface_kind', entry.surface?.kind],
    ['conversation_id', entry.conversationId],
    ['external_message_id', entry.externalMessageId],
    ['speaker_id', entry.speakerId],
    ['speaker_name', entry.speakerName],
  ])
  const title = [
    `source=${contract.source}`,
    `status=${contract.status}`,
    contract.eventName ? `event=${contract.eventName}` : null,
    contract.reason ?? null,
    sourceContext || null,
  ].filter((value): value is string => Boolean(value)).join(' · ')
  switch (contract.status) {
    case 'backend_lifecycle_replay':
      return { label: '서버 replay', title, state: 'server-replay' }
    case 'history_without_turn_ref':
      if (entry.role === 'user') return null
      return { label: '턴 연결 없음', title, state: 'no-turn-ref' }
    case 'contract_gap':
      return { label: '수신 gap', title, state: 'contract-gap' }
    default:
      return null
  }
}

function streamContractBadgeClass(state: StreamContractBadgeInfo['state']): string {
  switch (state) {
    case 'server-replay':
      return 'border-[var(--warn-20)] bg-[var(--warn-10)] text-[var(--color-status-warn)]'
    case 'contract-gap':
      return 'border-[var(--warn-20)] bg-[var(--warn-10)] text-[var(--color-status-warn)]'
    case 'no-turn-ref':
      return 'border-[var(--color-border-default)] bg-[var(--color-bg-surface)] text-[var(--color-fg-secondary)]'
  }
}

function StreamContractBadge({ badge, compact }: { badge: StreamContractBadgeInfo | null; compact: boolean }) {
  if (!badge) return null
  const paddingClass = compact ? 'px-2 py-0.5' : 'px-2.5 py-1'
  return html`
    <span
      class=${`inline-flex items-center rounded-[var(--r-0)] border ${paddingClass} text-2xs font-semibold ${streamContractBadgeClass(badge.state)}`}
      title=${badge.title}
      data-chat-stream-contract-badge=${badge.state}
    >
      ${badge.label}
    </span>
  `
}

// C1: group transcript messages by calendar day for the workspace day divider.
// Absolute "M월 D일" labels (not relative 오늘/어제) so the output is a pure
// function of the timestamp — deterministic and snapshot-test stable.
function dayKey(timestamp?: string | null): string | null {
  if (!timestamp) return null
  const d = new Date(timestamp)
  if (Number.isNaN(d.getTime())) return null
  return `${d.getFullYear()}-${d.getMonth()}-${d.getDate()}`
}
function dayDividerLabel(timestamp?: string | null): string | null {
  if (!timestamp) return null
  const d = new Date(timestamp)
  if (Number.isNaN(d.getTime())) return null
  return `${d.getMonth() + 1}월 ${d.getDate()}일`
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

function overviewRows(details: KeeperConversationDetails): Array<{ label: string; value: string }> {
  return [
    typeof details.latencyMs === 'number' ? { label: '지연', value: `${details.latencyMs} ms` } : null,
    typeof details.usage?.totalTokens === 'number' ? { label: '토큰', value: `${details.usage.totalTokens}` } : null,
    formatCurrency(details.costUsd) ? { label: '비용', value: formatCurrency(details.costUsd)! } : null,
    details.traceId ? { label: '트레이스', value: details.traceId } : null,
    typeof details.generation === 'number' ? { label: '세대', value: `${details.generation}` } : null,
  ].filter((row): row is { label: string; value: string } => Boolean(row))
}

export function formatAttachmentSize(bytes: number): string {
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

let composerActionSeq = 0

function nextComposerClientActionId(): string {
  composerActionSeq += 1
  return `composer-send-${Date.now()}-${composerActionSeq}`
}

const VOICE_WAVE_BARS = [0.32, 0.58, 0.44, 0.82, 0.38, 0.66, 0.92, 0.5, 0.72, 0.4, 0.86, 0.56, 0.7, 0.46, 0.78, 0.36]

function formatVoiceClock(seconds: number): string {
  const whole = Math.max(0, Math.floor(seconds))
  const minutes = Math.floor(whole / 60)
  const secs = whole % 60
  return `${minutes}:${String(secs).padStart(2, '0')}`
}

function dataUriToText(data: string): string | null {
  const comma = data.indexOf(',')
  if (comma === -1 || !data.startsWith('data:')) return null
  const header = data.slice(0, comma)
  const body = data.slice(comma + 1)
  if (header.includes(';base64')) {
    try {
      return atob(body)
    } catch {
      return null
    }
  }
  try {
    return decodeURIComponent(body)
  } catch {
    return null
  }
}

function dataUriToBlob(data: string): Blob | null {
  const comma = data.indexOf(',')
  if (comma === -1 || !data.startsWith('data:')) return null
  const header = data.slice(0, comma)
  const body = data.slice(comma + 1)
  const mime = header.replace(/^data:/, '').replace(/;base64$/, '') || 'application/octet-stream'
  const isBase64 = header.includes(';base64')
  try {
    if (isBase64) {
      const byteString = atob(body)
      const bytes = new Uint8Array(byteString.length)
      for (let i = 0; i < byteString.length; i += 1) {
        bytes[i] = byteString.charCodeAt(i)
      }
      return new Blob([bytes], { type: mime })
    }
    return new Blob([decodeURIComponent(body)], { type: mime })
  } catch {
    return null
  }
}

function downloadArtifact(data: string, filename: string, mimeType?: string): void {
  const blob = data.startsWith('data:')
    ? dataUriToBlob(data)
    : new Blob([data], { type: mimeType ?? 'application/octet-stream' })
  if (!blob) return
  const href = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = href
  a.download = filename
  a.style.display = 'none'
  document.body.appendChild(a)
  a.click()
  document.body.removeChild(a)
  setTimeout(() => URL.revokeObjectURL(href), 1000)
}

function artifactPreviewType(kind?: string, data?: string, mimeType?: string): 'image' | 'svg' | 'md' | 'code' | 'unknown' {
  const k = (kind ?? '').toLowerCase()
  const mt = (mimeType ?? '').toLowerCase()
  if (k === 'image' || mt.startsWith('image/') || data?.startsWith('data:image/')) return 'image'
  if (k === 'svg' || mt === 'image/svg+xml' || data?.startsWith('data:image/svg')) return 'svg'
  if (k === 'md' || k === 'markdown' || mt.includes('markdown')) return 'md'
  if (
    k === 'code'
    || k === 'json'
    || mt.startsWith('text/')
    || mt === 'application/json'
    || data?.startsWith('data:text/')
    || data?.startsWith('data:application/json')
  ) {
    return 'code'
  }
  return 'unknown'
}

function isPreviewableArtifact(kind?: string, data?: string, mimeType?: string): boolean {
  return !!data && artifactPreviewType(kind, data, mimeType) !== 'unknown'
}

function ChatArtifactPreview({
  kind,
  name,
  data,
  mimeType,
  onClose,
}: {
  kind?: string
  name: string
  data: string
  mimeType?: string
  onClose: () => void
}) {
  const type = artifactPreviewType(kind, data, mimeType)
  if (type === 'image') {
    return html`
      <${ChatPreviewModal} title=${name} onClose=${onClose}>
        <img
          src=${data}
          alt=${name}
          class="max-h-[80vh] max-w-full rounded-[var(--r-1)] object-contain"
        />
      <//>
    `
  }
  if (type === 'svg') {
    return html`
      <${ChatPreviewModal} title=${name} onClose=${onClose}>
        <div
          class="chat-lightbox-svg"
          dangerouslySetInnerHTML=${{ __html: sanitizeHtml(data) }}
        />
      <//>
    `
  }
  const text = dataUriToText(data) ?? data
  if (type === 'md') {
    return html`
      <${ChatPreviewModal} title=${name} onClose=${onClose}>
        <${AsyncMarkdownDiv} text=${text} className="chat-lightbox-md markdown-body" />
      <//>
    `
  }
  return html`
    <${ChatPreviewModal} title=${name} onClose=${onClose}>
      <pre class="chat-lightbox-code"><code>${escapeHtml(text)}</code></pre>
    <//>
  `
}

// --- Keeper v2 rich block helpers -------------------------------------------------

function sanitizeHtml(raw: string): string {
  return purifyHtml(raw)
}

function sanitizeSvg(raw: string): string {
  return purifyHtml(raw, { USE_PROFILES: { svg: true } })
}

type MarkedApi = typeof import('marked')['marked']
type SanitizeConfig = Parameters<typeof purifyHtml>[1]

let markedPromise: Promise<MarkedApi> | null = null

function loadMarked(): Promise<MarkedApi> {
  if (!markedPromise) {
    markedPromise = import('marked')
      .then((module) => module.marked)
      .catch((err) => {
        markedPromise = null
        throw err
      })
  }
  return markedPromise
}

function AsyncMarkdownDiv({
  text,
  className,
  sanitizeConfig,
}: {
  text: string
  className: string
  sanitizeConfig?: SanitizeConfig
}) {
  const [rendered, setRendered] = useState<string | null>(null)

  useEffect(() => {
    let active = true
    setRendered(null)
    void (async () => {
      try {
        const marked = await loadMarked()
        const next = purifyHtml(marked.parse(text) as string, sanitizeConfig)
        if (active) setRendered(next)
      } catch (err) {
        console.warn('[chat] markdown render failed', err instanceof Error ? err.message : err)
        if (active) setRendered(null)
      }
    })()
    return () => { active = false }
  }, [text, sanitizeConfig])

  return rendered === null
    ? html`<div class=${className} dangerouslySetInnerHTML=${renderPlainLinkedHtml(text)} />`
    : html`<div class=${className} dangerouslySetInnerHTML=${{ __html: rendered }} />`
}

function streamingThinkingPreview(text: string): string {
  if (text.length <= STREAMING_THINKING_PREVIEW_CHARS) return text
  return `...\n${text.slice(-STREAMING_THINKING_PREVIEW_CHARS)}`
}

function ChatThinkingText({ text, streaming }: { text: string; streaming: boolean }) {
  if (streaming) {
    return html`
      <div
        class="chat-block-tstep-text markdown-body whitespace-pre-wrap break-words"
        data-chat-thinking-preview=${text.length > STREAMING_THINKING_PREVIEW_CHARS ? 'truncated' : 'full'}
        dangerouslySetInnerHTML=${renderPlainLinkedHtml(streamingThinkingPreview(text))}
      />
    `
  }
  return html`
    <${AsyncMarkdownDiv}
      text=${text}
      className="chat-block-tstep-text markdown-body whitespace-pre-wrap break-words"
    />
  `
}

function renderInlineHtml(raw: string): { __html: string } {
  return { __html: sanitizeHtml(linkifyHtmlReferences(raw)) }
}

function renderPlainLinkedHtml(raw: string): { __html: string } {
  return { __html: sanitizeHtml(linkifyHtmlReferences(escapeHtml(raw))) }
}

function highlightJson(obj: unknown): string {
  let value = obj
  if (typeof obj === 'string') {
    try {
      value = JSON.parse(obj)
    } catch {
      value = obj
    }
  }
  const s = typeof value === 'string' ? value : JSON.stringify(value, null, 2)
  return sanitizeHtml(
    s
      .replace(/("[^"]+"):/g, '<span class="chat-json-key">$1</span>:')
      .replace(/: ("[^"]*")/g, ': <span class="chat-json-str">$1</span>'),
  )
}

function traceDur(trace: ChatTraceStep[]): string | null {
  let sum = 0
  let has = false
  trace.forEach((st) => {
    if (st.kind !== 'tool') return
    const m = st.dur?.match(/([\d.]+)s/)
    if (m?.[1]) {
      sum += parseFloat(m[1])
      has = true
    }
  })
  return has ? `${Math.round(sum * 10) / 10}s` : null
}

function ChatTextBlock({ html: htmlContent }: { html: string }) {
  return html`<p class="mb-2 text-base leading-airy text-[var(--color-fg-primary)]" dangerouslySetInnerHTML=${renderInlineHtml(htmlContent)} />`
}

function ChatHeadingBlock({ html: htmlContent }: { html: string }) {
  return html`<h4 class="mb-1 mt-2 text-sm font-semibold text-[var(--color-fg-secondary)]" dangerouslySetInnerHTML=${renderInlineHtml(htmlContent)} />`
}

function ChatListBlock({ items }: { items: string[] }) {
  return html`
    <ul class="my-1 list-disc pl-5 text-base leading-airy text-[var(--color-fg-primary)]">
      ${items.map((it, i) => html`<li key=${i} dangerouslySetInnerHTML=${renderInlineHtml(it)} />`)}
    </ul>
  `
}

function ChatCalloutBlock({ severity = 'warn', html: htmlContent }: ChatCalloutBlock) {
  const icon = severity === 'bad' ? '✕' : severity === 'info' ? 'ℹ' : '⚠'
  return html`
    <div class="chat-block-callout ${severity}" data-chat-block="callout">
      <span class="shrink-0">${icon}</span>
      <span class="min-w-0" dangerouslySetInnerHTML=${renderInlineHtml(htmlContent)} />
    </div>
  `
}

function ChatTableBlock({ head, rows }: ChatTableBlock) {
  const cell = (c: ChatTableBlock['head'][number]) => (typeof c === 'object' ? c : { v: c })
  return html`
    <table class="chat-block-table" data-chat-block="table">
      <thead>
        <tr>
          ${head.map((h, i) => {
            const c = cell(h)
            return html`<th key=${i} class=${c.num ? 'chat-block-cell-num' : ''} dangerouslySetInnerHTML=${renderInlineHtml(String(c.v))} />`
          })}
        </tr>
      </thead>
      <tbody>
        ${rows.map((row, ri) => html`
          <tr key=${ri}>
            ${row.map((c0, ci) => {
              const c = cell(c0)
              return html`<td key=${ci} class="${c.num ? 'chat-block-cell-num' : ''} ${c.muted ? 'chat-block-cell-muted' : ''}" dangerouslySetInnerHTML=${renderInlineHtml(String(c.v))} />`
            })}
          </tr>
        `)}
      </tbody>
    </table>
  `
}

function ChatPreviewModal({
  title,
  onClose,
  children,
}: {
  title: string
  onClose: () => void
  children: ComponentChildren
}) {
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose()
    }
    document.addEventListener('keydown', handler)
    return () => document.removeEventListener('keydown', handler)
  }, [onClose])

  return html`
    <div
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4 backdrop-blur-sm"
      onClick=${onClose}
      role="dialog"
      aria-modal="true"
      aria-label=${title}
    >
      <div
        class="relative max-h-[90vh] max-w-[90vw] overflow-auto rounded-[var(--r-2)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-4 shadow-[var(--shadow-raised)]"
        onClick=${(e: Event) => e.stopPropagation()}
      >
        <div class="mb-3 flex items-center justify-between gap-4">
          <span class="truncate text-sm font-semibold text-[var(--color-fg-primary)]">${title}</span>
          <button
            type="button"
            class="rounded-[var(--r-0)] px-2 py-1 text-xs text-[var(--color-fg-secondary)] hover:bg-[var(--color-bg-hover)] hover:text-[var(--color-fg-primary)]"
            onClick=${onClose}
            aria-label="닫기"
          >
            ✕
          </button>
        </div>
        <div class="chat-preview-modal-body">${children}</div>
      </div>
    </div>
  `
}

function codeBlockText(htmlContent: string, source?: string): string {
  if (source !== undefined) return source
  if (typeof document !== 'undefined') {
    const el = document.createElement('div')
    el.innerHTML = htmlContent
    return el.textContent ?? htmlContent
  }
  return htmlContent
}

function codeBlockLanguage(cap?: string): string {
  const label = cap?.trim()
  if (!label) return 'text'
  const extension = label.match(/(?:^|[./\\])([a-zA-Z0-9_+-]+)$/)?.[1]
  return extension ?? label
}

// Reuse the canonical clipboard helper (common/copyable-code) — it carries the
// execCommand fallback for non-secure contexts — and just layer the toast on its
// boolean result so the message text matches what was copied.
async function copyWithToast(text: string, successMessage: string): Promise<void> {
  const ok = await copyToClipboard(text)
  showToast(ok ? successMessage : '복사하지 못했습니다', ok ? 'success' : 'error')
}

function ChatCodeBlock({ cap, html: htmlContent, source }: { cap?: string; html: string; source?: string }) {
  const [highlighted, setHighlighted] = useState<string | null>(null)
  const [failed, setFailed] = useState(false)
  const [containerRef, shouldHighlight] = useInViewOnce<HTMLDivElement>('300px')
  const codeId = useId()

  useEffect(() => {
    if (!shouldHighlight) {
      setHighlighted(null)
      setFailed(false)
      return undefined
    }
    let cancelled = false
    const run = async () => {
      try {
        setHighlighted(null)
        setFailed(false)
        const text = codeBlockText(htmlContent, source)
        const { highlightCodeHtml } = await import('../common/shiki-highlighter')
        const next = await highlightCodeHtml(text, codeBlockLanguage(cap))
        if (!cancelled) setHighlighted(next)
      } catch {
        if (!cancelled) setFailed(true)
      }
    }
    void run()
    return () => { cancelled = true }
  }, [htmlContent, cap, source, shouldHighlight])

  const plain = codeBlockText(htmlContent, source)

  return html`
    <div class="chat-block-code ${failed ? 'chat-block-code-fallback' : ''}" data-chat-block="code" ref=${containerRef}>
      <div class="chat-block-code-hd">
        ${cap ? html`<span class="chat-block-code-cap">${cap}</span>` : html`<span class="chat-block-code-cap" />`}
        <button
          type="button"
          class="chat-block-code-copy"
          aria-label="코드 복사"
          title="복사"
          onClick=${() => { void copyWithToast(plain, '코드를 복사했습니다') }}
        >
          복사
        </button>
      </div>
      ${highlighted
        ? html`<div class="m-0 overflow-x-auto p-0 text-2xs leading-relaxed" id=${codeId} dangerouslySetInnerHTML=${{ __html: highlighted }} />`
        : html`<pre class="m-0 overflow-x-auto p-3 text-2xs leading-relaxed" id=${codeId}><code dangerouslySetInnerHTML=${{ __html: htmlContent }} /></pre>`}
    </div>
  `
}

function ChatShellBlock({ title, lines, exit, dur }: ChatShellBlock) {
  return html`
    <div class="chat-block-shell" data-chat-block="shell">
      <div class="chat-block-shell-bar">
        <span class="chat-block-shell-dot r"></span>
        <span class="chat-block-shell-dot y"></span>
        <span class="chat-block-shell-dot g"></span>
        <span class="chat-block-shell-title">${title || 'keeper@worktree'}</span>
      </div>
      <pre class="m-0 p-3 text-2xs leading-relaxed">
        ${lines.map((ln, i) => html`
          <div key=${i} class="chat-block-shell-line ${ln.t || ''}">
            ${ln.t === 'cmd' ? html`<span class="chat-block-shell-prompt">$ </span>` : null}
            <span dangerouslySetInnerHTML=${{ __html: sanitizeHtml(ln.v) }} />
          </div>
        `)}
      </pre>
      ${typeof exit === 'number'
        ? html`<div class="chat-block-shell-exit ${exit === 0 ? 'ok' : 'fail'}">exit ${exit}${dur ? ` · ${dur}` : ''}</div>`
        : null}
    </div>
  `
}

function ChatArtifactBlock({
  kind,
  name,
  size,
  note,
  data,
  mimeType,
}: {
  kind?: string
  name: string
  size?: string
  note?: string
  data?: string
  mimeType?: string
}) {
  const [open, setOpen] = useState(false)
  const hasData = !!data
  const previewable = isPreviewableArtifact(kind, data, mimeType)
  const icon = kind === 'md' ? '⌹' : kind === 'svg' ? '◫' : kind === 'json' ? '{ }' : '⎙'

  const handleDownload = () => {
    if (data) downloadArtifact(data, name, mimeType)
  }

  return html`
    <div class="chat-block-artifact" data-chat-block="artifact">
      <span class="chat-block-artifact-icon">${icon}</span>
      <div class="min-w-0 flex-1">
        <div class="chat-block-artifact-name">${name}</div>
        <div class="chat-block-artifact-sub">
          ${(kind || 'file').toUpperCase()}${size ? ` · ${size}` : ''}${note ? ` · ${note}` : ''}
        </div>
      </div>
      <button
        type="button"
        class="chat-block-artifact-btn"
        disabled=${!previewable}
        onClick=${() => previewable && setOpen(true)}
        aria-label="열기"
      >
        열기
      </button>
      <button
        type="button"
        class="chat-block-artifact-btn"
        disabled=${!hasData}
        onClick=${handleDownload}
        aria-label="다운로드"
      >
        다운로드
      </button>
      ${open && previewable
        ? html`
            <${ChatArtifactPreview}
              kind=${kind}
              name=${name}
              data=${data}
              mimeType=${mimeType}
              onClose=${() => setOpen(false)}
            />
          `
        : null}
    </div>
  `
}

function ChatChartBlock({ title, series, labels, xLabel, yMax }: ChatChartBlock) {
  const width = 540
  const height = 180
  const pad = { top: 18, right: 16, bottom: 34, left: 36 }
  const chartW = width - pad.left - pad.right
  const chartH = height - pad.top - pad.bottom

  const allValues = series.flatMap((s) => s.values)
  const computedMax = allValues.length > 0 ? Math.max(...allValues) : 0
  const maxY = Math.max(yMax ?? 0, computedMax, 1)
  const niceMax = Math.ceil(maxY / 10) * 10 || 10

  const xFor = (i: number, len: number): number =>
    pad.left + (len <= 1 ? chartW / 2 : (i / (len - 1)) * chartW)
  const yFor = (v: number): number => pad.top + chartH - (v / niceMax) * chartH

  const ticks = [0, niceMax / 2, niceMax]
  const labelCount = labels?.length ?? Math.max(...series.map((s) => s.values.length), 0)

  return html`
    <div class="chat-block-chart" data-chat-block="chart">
      <div class="chat-block-chart-title">${title}</div>
      <svg
        viewBox=${`0 0 ${width} ${height}`}
        role="img"
        aria-label=${title}
        class="chat-block-chart-svg"
      >
        ${ticks.map((t) => {
          const y = yFor(t)
          return html`
            <g key=${`grid-${t}`}>
              <line
                x1=${pad.left}
                y1=${y}
                x2=${width - pad.right}
                y2=${y}
                class="chat-block-chart-grid"
              />
              <text x=${pad.left - 6} y=${y + 3} class="chat-block-chart-ytick">${Math.round(t)}</text>
            </g>
          `
        })}
        <line
          x1=${pad.left}
          y1=${pad.top + chartH}
          x2=${width - pad.right}
          y2=${pad.top + chartH}
          class="chat-block-chart-axis"
        />
        ${series.map((s, si) => {
          const points = s.values.map((v, i) => `${xFor(i, s.values.length)},${yFor(v)}`).join(' ')
          const color = s.color ?? (si === 0 ? 'var(--accent-brass-bright)' : 'var(--text-dim)')
          return html`
            <g key=${si}>
              <polyline
                fill="none"
                stroke=${color}
                stroke-width="2"
                stroke-linecap="round"
                stroke-linejoin="round"
                points=${points}
              />
              ${s.values.map((v, i) => html`
                <circle
                  key=${i}
                  cx=${xFor(i, s.values.length)}
                  cy=${yFor(v)}
                  r="3"
                  fill=${color}
                />
              `)}
            </g>
          `
        })}
        ${labels && labelCount > 0
          ? html`
              <text
                x=${width - pad.right}
                y=${height - 6}
                class="chat-block-chart-xlabel"
                text-anchor="end"
              >
                ${xLabel ? `${xLabel} →` : '→'}
              </text>
            `
          : null}
      </svg>
      <div class="chat-block-chart-legend">
        ${series.map((s, i) => html`
          <span key=${i} class="chat-block-chart-legend-item">
            <span
              class="chat-block-chart-legend-swatch"
              style=${{ background: s.color ?? (i === 0 ? 'var(--accent-brass-bright)' : 'var(--text-dim)') }}
            />
            <span>${s.label}</span>
          </span>
        `)}
      </div>
    </div>
  `
}

function ChatSuggestionsBlock({ items }: ChatSuggestionsBlock) {
  const labelId = useId()
  // Mirrors the keeper-v2 prototype suggestion block: label above a chip row.
  // The label is a readability cue for inline message-bubble content.
  return html`
    <div class="chat-block-suggestions" data-chat-block="suggestions">
      <span class="chat-block-suggestions-label" id=${labelId}>${CHAT_SUGGESTIONS_LABEL}</span>
      <div class="chat-block-suggestions-row suggest-row" role="group" aria-labelledby=${labelId}>
        ${items.map((it, i) => html`
          <${ChatSuggestionChip}
            key=${i}
            pre=${it.icon ?? '\u25b8'}
            class="chat-block-suggestion-chip"
            data-action=${it.action ?? ''}
          >${it.label}<//>
        `)}
      </div>
    </div>
  `
}

function ChatIssueBlock({ repo, number, title, status, url, meta }: ChatIssueBlock) {
  const safeUrl = isSafeUrl(url ?? '') ? url : '#'
  const unsafe = safeUrl === '#'
  return html`
    <a
      class="chat-block-issue ${status}"
      href=${safeUrl}
      target="_blank"
      rel=${unsafe ? undefined : 'noopener noreferrer'}
      data-chat-block="issue"
      onClick=${unsafe ? (e: MouseEvent) => { e.preventDefault() } : undefined}
    >
      <span class="chat-block-issue-icon">⚇</span>
      <span class="chat-block-issue-body">
        <span class="chat-block-issue-repo">${repo} #${number}</span>
        <span class="chat-block-issue-title">${title}</span>
        <span class="chat-block-issue-meta">
          <span class="chat-block-issue-status ${status}">${status.toUpperCase()}</span>
          ${meta ? html`<span>${meta}</span>` : null}
        </span>
      </span>
      <span class="chat-block-issue-go">↗</span>
    </a>
  `
}

function ChatAttachBlock({
  name,
  dims,
  src,
  svg,
  ph,
  via,
  size,
  id,
  kind,
  mimeType,
  sizeBytes,
}: {
  name: string
  dims?: string
  src?: string
  svg?: string
  ph?: string
  via?: string
  size?: string
  id?: string
  kind?: string
  mimeType?: string
  sizeBytes?: number
}) {
  const safeSrc = src && isSafeMediaUrl(src, ['data:image/']) ? src : null
  return html`
    <figure
      class="chat-block-attach"
      data-chat-block="attach"
      data-chat-multimodal-source="server_block"
      data-chat-multimodal-kind=${kind || undefined}
      data-chat-multimodal-attachment-id=${id || undefined}
      data-chat-multimodal-mime=${mimeType || undefined}
      data-chat-multimodal-size-bytes=${sizeBytes ?? undefined}
      data-chat-attach-via=${via || undefined}
    >
      <div class="chat-block-attach-hd">
        <span>◫</span>
        <span class="chat-block-attach-name">${name}</span>
        ${dims ? html`<span class="chat-block-attach-dims">${dims}</span>` : null}
      </div>
      <div class="chat-block-attach-frame">
        ${safeSrc
          ? html`<img src=${safeSrc} alt=${name} class="chat-block-attach-img" />`
          : svg
            ? html`<span dangerouslySetInnerHTML=${{ __html: sanitizeSvg(svg) }} />`
            : html`<div class="chat-block-attach-ph">${ph || '첨부를 표시할 수 없습니다'}${src ? ' (unsafe URL)' : ''}</div>`}
      </div>
      <figcaption class="chat-block-attach-cap">
        <span>첨부</span>${via ? ` · ${via}` : ''}${size ? ` · ${size}` : ''}
      </figcaption>
    </figure>
  `
}

function isSafeUrl(url: string): boolean {
  try {
    const u = new URL(url, typeof window !== 'undefined' ? window.location.href : 'http://localhost')
    return u.protocol === 'http:' || u.protocol === 'https:' || u.protocol === 'blob:'
  } catch {
    return false
  }
}

function isSafeMediaUrl(url: string, dataPrefixes: string[]): boolean {
  if (isSafeUrl(url)) return true
  const lower = url.slice(0, 64).toLowerCase()
  return dataPrefixes.some((prefix) => lower.startsWith(prefix))
}

function ChatVoiceBlock(b: ChatVoiceBlock) {
  const secs = b.secs
  const safeSrc = b.src && isSafeMediaUrl(b.src, ['data:audio/']) ? b.src : null
  const bars = b.wave ?? []
  const fmt = (s: number) => `${Math.floor(s / 60)}:${String(Math.round(s) % 60).padStart(2, '0')}`

  return html`
    <div class="chat-block-voice" data-chat-block="voice">
      ${safeSrc || bars.length > 0 || typeof secs === 'number'
        ? html`
            <div class="chat-block-voice-row">
              ${safeSrc
                ? html`
                    <audio
                      controls
                      preload="none"
                      src=${safeSrc}
                      class="h-8 max-w-[16rem]"
                      aria-label=${b.transcript || '음성 메시지'}
                    />
                  `
                : null}
              ${bars.length > 0
                ? html`
                    <div class="chat-block-voice-wave">
                      ${bars.map((h, i) => html`
                        <span
                          key=${i}
                          class="chat-block-vbar"
                          style=${{ height: `${Math.round(5 + h * 21)}px` }}
                        />
                      `)}
                    </div>
                  `
                : null}
              ${typeof secs === 'number'
                ? html`<span class="chat-block-voice-dur">${fmt(secs)}</span>`
                : null}
            </div>
          `
        : null}
      ${b.via || b.size
        ? html`
            <div class="chat-block-voice-meta">
              ${b.via ? html`<span>◌ ${b.via}</span>` : null}
              ${b.size ? html`<span>${b.size}</span>` : null}
            </div>
          `
        : null}
      ${b.transcript
        ? html`
            <div class="chat-block-voice-tx">
              <span>받아쓰기</span>
              <span>${b.transcript}</span>
            </div>
          `
        : null}
    </div>
  `
}

function ChatImageBlock({ src, ph, cap }: { src?: string; ph?: string; cap?: string }) {
  const [open, setOpen] = useState(false)
  const safeSrc = src && isSafeMediaUrl(src, ['data:image/']) ? src : null
  // Keeper-v2 messages.jsx image block: figure.img-out > .img-frame > img | .img-ph.
  // chat-block-media-frame stays alongside img-frame — it owns the dashboard-only
  // extras the design never had to solve (placeholder min-height, img max-height cap).
  return html`
    <figure class="img-out" data-chat-block="image">
      <div class="chat-block-media-frame img-frame ${safeSrc ? 'cursor-zoom-in' : ''}" onClick=${() => safeSrc && setOpen(true)}>
        ${safeSrc
          ? html`<img src=${safeSrc} alt=${cap || ''} class="max-h-52 w-full rounded-[var(--r-1)] object-contain" />`
          : html`<div class="chat-block-media-ph img-ph">${ph || '실행 화면'}${src ? ' (unsafe URL)' : ''}</div>`}
      </div>
      ${cap ? html`<figcaption>${cap}</figcaption>` : null}
      ${open && safeSrc
        ? html`
            <${ChatPreviewModal} title=${cap || '이미지'} onClose=${() => setOpen(false)}>
              <img
                src=${safeSrc}
                alt=${cap || ''}
                class="max-h-[80vh] max-w-full rounded-[var(--r-1)] object-contain"
              />
            <//>
          `
        : null}
    </figure>
  `
}

function ChatSvgBlock({ svg, cap }: { svg: string; cap?: string }) {
  const [open, setOpen] = useState(false)
  const clean = useMemo(() => sanitizeHtml(svg), [svg])
  // Keeper-v2 messages.jsx svg block: figure.svg-out > .svg-frame (sanitized inline svg).
  return html`
    <figure class="svg-out" data-chat-block="svg">
      <div
        class="chat-block-media-frame svg-frame cursor-zoom-in"
        onClick=${() => setOpen(true)}
        dangerouslySetInnerHTML=${{ __html: clean }}
      />
      ${cap ? html`<figcaption>${cap}</figcaption>` : null}
      ${open
        ? html`
            <${ChatPreviewModal} title=${cap || 'SVG'} onClose=${() => setOpen(false)}>
              <div class="chat-preview-modal-body-svg" dangerouslySetInnerHTML=${{ __html: clean }} />
            <//>
          `
        : null}
    </figure>
  `
}

function ChatMermaidBlock({ source, caption }: ChatMermaidBlock) {
  const id = useId()
  const [containerRef, shouldRender] = useInViewOnce<HTMLElement>('200px')
  const [svg, setSvg] = useState<string | null>(null)
  const [error, setError] = useState(false)

  useEffect(() => {
    if (!shouldRender) return undefined
    setError(false)
    setSvg(null)
    let active = true
    const run = async () => {
      try {
        // Use the shared mermaid path: it initializes once, serializes renders
        // to avoid SVG corruption, and returns DOMPurify-sanitized output.
        // Re-running DOMPurify per chat block added ~1s+ of main-thread work
        // for large diagrams (see dashboard perf audit).
        const { renderMermaidSvg } = await import('../common/mermaid-graph')
        const rendered = await renderMermaidSvg(source, `mermaid-${id}`)
        if (active) setSvg(rendered)
      } catch {
        if (active) setError(true)
      }
    }
    void run()
    return () => { active = false }
  }, [source, id, shouldRender])

  if (error) {
    return html`<${ChatCodeBlock} cap="mermaid" html=${escapeHtml(source)} source=${source} />`
  }

  return html`
    <figure class="chat-block-media" data-chat-block="mermaid" ref=${containerRef}>
      <div class="chat-block-mermaid">
        ${svg
          ? html`<div dangerouslySetInnerHTML=${{ __html: svg }} />`
          : html`<div class="chat-block-media-ph">${shouldRender ? '다이어그램 렌더링 중…' : '다이어그램 (스크롤 시 렌더링)'}</div>`}
      </div>
      ${caption ? html`<figcaption class="chat-block-media-cap">${caption}</figcaption>` : null}
    </figure>
  `
}

function ChatTraceStep({
  step,
  streaming = false,
  orderIndex,
}: {
  step: ChatTraceStep
  streaming?: boolean
  orderIndex?: number
}) {
  const [open, setOpen] = useState(false)
  const sourceBadge = traceSourceBadge(step)

  if (step.kind === 'think' && step.contentWithheld) {
    // The server admitted the step without its reasoning (RFC-0358 §2), so
    // there is nothing to preview, expand, or stream — only the fact and its
    // timestamp. The wording lives here because the read boundary is a policy
    // of this surface, not a property of the run.
    return html`
      <div
        class="chat-block-tstep think"
        data-chat-trace-step="think"
        data-chat-trace-content-withheld="true"
        data-chat-turn-order-index=${orderIndex ?? undefined}
        data-chat-turn-order-kind="trace"
        data-chat-trace-provenance=${sourceBadge.label}
        data-chat-trace-ts=${step.ts ?? undefined}
      >
        <span class="chat-block-tnode"></span>
        <div class="min-w-0 flex-1">
          <div class="chat-block-tstep-row">
            <span class="chat-block-tstep-kind">Thinking</span>
            <${TraceSourceBadge} info=${sourceBadge} />
          </div>
          <div class="chat-block-tstep-text">내부 판단 단계 (내용 비공개)</div>
        </div>
      </div>
    `
  }

  if (step.kind === 'think') {
    const longThinking = !streaming && step.text.length > THINKING_TRACE_PREVIEW_CHARS
    const previewText = longThinking
      ? `${step.text.slice(0, THINKING_TRACE_PREVIEW_CHARS).trimEnd()}\n\n... ${step.text.length - THINKING_TRACE_PREVIEW_CHARS} chars hidden`
      : step.text
    return html`
      <div
        class="chat-block-tstep think"
        data-chat-trace-step="think"
        data-chat-turn-order-index=${orderIndex ?? undefined}
        data-chat-turn-order-kind="trace"
        data-chat-trace-provenance=${sourceBadge.label}
        data-chat-trace-agent-core-block-index=${step.agentCoreBlockIndex ?? undefined}
        data-chat-trace-ts=${step.ts ?? undefined}
      >
        <span class="chat-block-tnode"></span>
        <div class="min-w-0 flex-1">
          <div class="chat-block-tstep-row">
            <span class="chat-block-tstep-kind">Thinking</span>
            <${TraceSourceBadge} info=${sourceBadge} />
            ${longThinking
              ? html`
                  <button
                    type="button"
                    class="chat-block-tstep-chev"
                    aria-expanded=${open}
                    onClick=${() => setOpen((o) => !o)}
                  >
                    ${open ? '접기' : '전체 보기'}
                  </button>
                `
              : null}
          </div>
          ${streaming
            ? html`<${ChatThinkingText} text=${step.text} streaming=${true} />`
            : longThinking && !open
            ? html`
                <div
                  class="chat-block-tstep-text markdown-body whitespace-pre-wrap break-words"
                  dangerouslySetInnerHTML=${renderPlainLinkedHtml(previewText)}
                />
              `
            : html`
                <${AsyncMarkdownDiv}
                  text=${step.text}
                  className="chat-block-tstep-text markdown-body whitespace-pre-wrap break-words"
                />
              `}
        </div>
      </div>
    `
  }

  if (step.kind === 'reason') {
    const exp = !!step.detail
    return html`
      <div
        class="chat-block-tstep reason ${open ? 'exp' : ''}"
        data-chat-trace-step="reason"
        data-chat-turn-order-index=${orderIndex ?? undefined}
        data-chat-turn-order-kind="trace"
        data-chat-trace-provenance=${sourceBadge.label}
        data-chat-trace-ts=${step.ts ?? undefined}
      >
        <span class="chat-block-tnode"></span>
        <div class="min-w-0 flex-1">
          <div class="chat-block-tstep-row ${exp ? 'click' : ''}" onClick=${() => { if (exp) setOpen((o) => !o) }}>
            <span class="chat-block-tstep-kind">Reasoning</span>
            <${TraceSourceBadge} info=${sourceBadge} />
            <span class="chat-block-tstep-text" dangerouslySetInnerHTML=${{ __html: sanitizeHtml(step.text) }} />
            ${exp ? html`<span class="chat-block-tstep-chev">▶</span>` : null}
          </div>
          ${exp && open
            ? html`<div class="chat-block-reason-detail" dangerouslySetInnerHTML=${{ __html: sanitizeHtml(step.detail ?? '') }} />`
            : null}
        </div>
      </div>
    `
  }

  if (step.kind === 'progress') {
    return html`
      <div
        class="chat-block-tstep progress ${open ? 'exp' : ''}"
        data-chat-trace-step="progress"
        data-chat-turn-order-index=${orderIndex ?? undefined}
        data-chat-turn-order-kind="trace"
        data-chat-trace-provenance=${sourceBadge.label}
        data-chat-trace-agent-core-block-index=${step.agentCoreBlockIndex ?? undefined}
        data-chat-trace-ts=${step.ts ?? undefined}
      >
        <span class="chat-block-tnode"></span>
        <div class="min-w-0 flex-1">
          <button
            type="button"
            class="chat-block-tstep-row click w-full text-left"
            aria-expanded=${open}
            onClick=${() => setOpen((o) => !o)}
          >
            <span class="chat-block-tstep-kind">Progress</span>
            <${TraceSourceBadge} info=${sourceBadge} />
            <span class="chat-block-tstep-text min-w-0 flex-1 truncate">${step.text}</span>
            <span class="chat-block-tstep-chev">${open ? '▼' : '▶'}</span>
          </button>
          ${open
            ? html`<${AsyncMarkdownDiv}
                text=${step.text}
                className="chat-block-reason-detail markdown-body whitespace-pre-wrap break-words"
              />`
            : null}
        </div>
      </div>
    `
  }

  const statusUi = traceToolStatusUi(step.status)
  // The name alone repeats: six `Execute` rows read identically. The subject is
  // the argument that tells them apart, and it is already on the step.
  const subject = toolSubject(step.args)

  return html`
    <div
      class="chat-block-tstep tool ${open ? 'exp' : ''}"
      data-chat-trace-step="tool"
      data-chat-turn-order-index=${orderIndex ?? undefined}
      data-chat-turn-order-kind="tool"
      data-chat-trace-provenance=${sourceBadge.label}
      data-chat-trace-tool-call-id=${step.toolCallId?.trim() || undefined}
      data-chat-trace-execution-id=${step.executionId?.trim() || undefined}
      data-chat-trace-agent-core-block-index=${step.agentCoreBlockIndex ?? undefined}
      data-chat-trace-link-state=${step.executionId?.trim() ? 'trace-only' : 'unlinked'}
      data-chat-trace-output-state=${step.status ?? 'pending'}
      data-chat-trace-ts=${step.ts ?? undefined}
    >
      <span class="chat-block-tnode"></span>
      <div class="min-w-0 flex-1">
        <div class="chat-block-tstep-row click" onClick=${() => setOpen((o) => !o)}>
          <span class="chat-block-tstep-kind">Tool</span>
          <${TraceSourceBadge} info=${sourceBadge} />
          <span class="chat-block-tstep-name">${step.name}</span>
          ${subject
            ? html`<span class="chat-block-tstep-subject" title=${subject}>${subject}</span>`
            : null}
          <span
            class="chat-block-tstep-status ${statusUi.className}"
            title=${statusUi.title}
            aria-label=${statusUi.title}
          ></span>
          <span class="chat-block-tstep-dur">${step.dur}</span>
          <span class="chat-block-tstep-chev">▶</span>
        </div>
        ${open
          ? html`
              <div class="chat-block-tool-body">
                ${step.args !== undefined
                  ? html`
                      <div class="chat-block-tool-label">args</div>
                      <pre class="m-0 overflow-x-auto text-2xs" dangerouslySetInnerHTML=${{ __html: highlightJson(step.args) }} />
                    `
                  : null}
                ${step.result !== undefined
                  ? html`
                      <div class="chat-block-tool-label">result</div>
                      <pre class="m-0 overflow-x-auto text-2xs" dangerouslySetInnerHTML=${{ __html: sanitizeHtml(step.result) }} />
                    `
                  : null}
              </div>
            `
          : null}
      </div>
    </div>
  `
}

function ChatTraceBlock({ trace, omitted = 0 }: { trace: ChatTraceStep[]; omitted?: number }) {
  const [open, setOpen] = useState(true)
  const toolN = trace.filter((s) => s.kind === 'tool').length
  const dur = traceDur(trace)

  return html`
    <div class="chat-block-trace ${open ? 'open' : ''}" data-chat-block="trace">
      <button
        type="button"
        class="chat-block-trace-hd"
        onClick=${() => setOpen((o) => !o)}
        aria-expanded=${open}
      >
        <span class="chat-block-trace-chev">${open ? '▾' : '▸'}</span>
        <span>◈</span>
        <span class="chat-block-trace-label">작업 과정</span>
        <span class="chat-block-trace-count">${trace.length}단계</span>
        <!-- A nested template literal inside an htm template corrupts its
             parse and breaks unrelated components in the same module, so the
             two counts are separate spans rather than one interpolated
             string. -->
        ${omitted > 0
          ? html`<span class="chat-block-trace-count" data-chat-trace-omitted=${omitted}>앞 ${omitted}단계 생략</span>`
          : null}
        <span class="chat-block-trace-meta">
          ${toolN > 0 ? html`<span>도구 ${toolN}</span>` : null}
          ${dur ? html`<span class="tnum">${dur}</span>` : null}
        </span>
      </button>
      ${open
        ? html`
            <div class="chat-block-trace-steps">
              <span class="chat-block-trace-rail"></span>
              ${omitted > 0
                ? html`<div class="chat-block-tstep-text" data-chat-trace-omitted=${omitted}>
                    이 턴의 앞 ${omitted}단계는 대화 화면에 싣지 않았습니다 — 전체는 Turn
                    Inspector의 raw trace에서 확인합니다.
                  </div>`
                : null}
              ${trace.map((s, i) => html`<${ChatTraceStep} key=${i} step=${s} />`)}
            </div>
          `
        : null}
    </div>
  `
}

function ChatLinkBlock(b: ChatLinkBlock) {
  let host = b.meta
  try {
    host = new URL(b.url).hostname.replace(/^www\./, '')
  } catch {
    host = b.meta
  }
  const safeUrl = isSafeUrl(b.url) ? b.url : '#'
  const unsafe = safeUrl === '#'
  // Keeper-v2 messages.jsx LinkCard vocabulary (linkcard / -fav / -body / -title /
  // -desc / -meta mono / -go); skin is vendored in keeper-v2/v2.css. The
  // chat-block-linkcard-unsafe hook is dashboard-only: the design has no unsafe-URL
  // state, and the live renderer refuses javascript:/data: hrefs.
  return html`
    <a
      class="linkcard ${b.kind || ''} ${unsafe ? 'chat-block-linkcard-unsafe' : ''}"
      href=${safeUrl}
      target="_blank"
      rel=${unsafe ? undefined : 'noopener noreferrer'}
      data-chat-block="link"
      onClick=${unsafe ? (e: MouseEvent) => { e.preventDefault() } : undefined}
    >
      <span class="linkcard-fav">${b.fav || (host ? host.slice(0, 1).toUpperCase() : '↗')}</span>
      <span class="linkcard-body">
        <span class="linkcard-title">${b.title}</span>
        ${b.desc ? html`<span class="linkcard-desc">${b.desc}</span>` : null}
        <span class="linkcard-meta mono">${unsafe ? 'unsafe URL' : (b.meta || host)}</span>
      </span>
      <span class="linkcard-go">↗</span>
    </a>
  `
}

const BROADCAST_ACK_LABEL: Record<string, string> = { acked: '확인함', read: '읽음', delivered: '전달됨' }

function ChatBroadcastBlock(b: ChatBroadcastBlock) {
  const ackN = b.recipients.filter((r) => r.ack === 'acked').length
  return html`
    <div class="chat-block-broadcast" data-chat-block="broadcast">
      <div class="chat-block-broadcast-hd">
        <span>⊚ 브로드캐스트</span>
        <span class="chat-block-broadcast-scope">${b.scope}</span>
        <span class="chat-block-broadcast-via">${b.via}</span>
        <span class="chat-block-broadcast-count">${ackN}/${b.recipients.length} 확인</span>
      </div>
      <div class="chat-block-broadcast-note">${b.note}</div>
      <div class="chat-block-broadcast-rcpts">
        ${b.recipients.map((r, i) => html`
          <div key=${i} class="chat-block-broadcast-rcpt ${r.ack}">
            <span class="chat-block-broadcast-avatar">${r.id.slice(0, 2).toUpperCase()}</span>
            <span class="chat-block-broadcast-id">${r.id}</span>
            <span class="chat-block-broadcast-ack">
              ${BROADCAST_ACK_LABEL[r.ack] || r.ack}${r.at ? ` · ${r.at}` : ''}
            </span>
          </div>
        `)}
      </div>
    </div>
  `
}

// RFC-0252: fusion deliberation card. The board post (created by
// fusion_sink.ml) holds the full panel answers + judge synthesis in its
// meta_json; the chat message only carries the board_post_id. We lazy-fetch
// the post the first time the card is expanded so a collapsed transcript does
// no extra network. meta is a loose Record on the wire, so we narrow defensively.
type FusionPanelEntry = {
  model: string
  status: string
  answer?: string
  reason?: string
  outputTokens?: number
}

type FusionJudgeView = {
  status: string
  decision?: string
  // synthesis is render_judge's markdown (consensus/contradictions/blind-spots
  // + resolved answer) — the actual deliberation value. Prefer it; fall back to
  // resolvedAnswer for older posts written before synthesis was serialized.
  synthesis?: string
  resolvedAnswer?: string
  error?: string
}

function stringOrUndef(v: unknown): string | undefined {
  if (typeof v !== 'string') return undefined
  const trimmed = v.trim()
  return trimmed || undefined
}

function numOrUndef(v: unknown): number | undefined {
  return typeof v === 'number' && Number.isFinite(v) ? v : undefined
}

function asFusionPanel(meta: unknown): FusionPanelEntry[] {
  if (!meta || typeof meta !== 'object') return []
  const panel = (meta as Record<string, unknown>).panel
  if (!Array.isArray(panel)) return []
  return panel.flatMap((raw) => {
    if (!raw || typeof raw !== 'object') return []
    const r = raw as Record<string, unknown>
    const model = stringOrUndef(r.model) ?? '?'
    const reason = stringOrUndef(r.reason_detail) ?? stringOrUndef(r.reason)
    return [{
      model,
      status: stringOrUndef(r.status) ?? 'unknown',
      answer: stringOrUndef(r.answer),
      reason: normalizeFusionPanelReason(model, reason),
      outputTokens: numOrUndef(r.output_tokens),
    }]
  })
}

function asFusionJudge(meta: unknown): FusionJudgeView | null {
  if (!meta || typeof meta !== 'object') return null
  const judge = (meta as Record<string, unknown>).judge
  if (!judge || typeof judge !== 'object') return null
  const r = judge as Record<string, unknown>
  return {
    status: typeof r.status === 'string' ? r.status : 'unknown',
    decision: typeof r.decision === 'string' ? r.decision : undefined,
    synthesis: typeof r.synthesis === 'string' ? r.synthesis : undefined,
    resolvedAnswer: typeof r.resolved_answer === 'string' ? r.resolved_answer : undefined,
    error: typeof r.error === 'string' ? r.error : undefined,
  }
}

function asFusionTotalOutputTokens(meta: unknown): number | undefined {
  if (!meta || typeof meta !== 'object') return undefined
  const usage = (meta as Record<string, unknown>).observed_usage
  if (!usage || typeof usage !== 'object') return undefined
  return numOrUndef((usage as Record<string, unknown>).output_tokens)
}

// Render untrusted model/judge markdown through the same sanitized path the rest
// of the transcript uses (DOMPurify over marked) — never inject raw model output.
// Marked is loaded lazily so closed fusion panels do not tax initial keeper load.
function FusionMarkdown({ text }: { text: string }) {
  return html`<${AsyncMarkdownDiv} text=${text} className="markdown-body text-xs leading-relaxed" />`
}

// One panel model's contribution. Collapsed by default so three verbose model
// answers stay scannable — the judge synthesis above is the conclusion, these
// are the evidence the reader opens on demand. Failed panels show their short
// reason inline (nothing to collapse).
function FusionPanelRow({ entry }: { entry: FusionPanelEntry }) {
  const [open, setOpen] = useState(false)
  const failed = entry.status !== 'answered'
  const tok = entry.outputTokens !== undefined ? ` · ${entry.outputTokens.toLocaleString()} tok` : ''
  const canToggle = !!entry.answer
  return html`
    <div
      class="rounded border ${failed ? 'border-[var(--color-danger,#e06c75)]/40' : 'border-[var(--color-border,#30363d)]'} px-2 py-1.5"
      data-fusion-panel
    >
      ${canToggle
        ? html`
          <button
            type="button"
            class="w-full flex items-center gap-1.5 text-left text-2xs font-mono text-[var(--color-fg-secondary,#9da7b3)] ${CHAT_FOCUS_RING}"
            aria-expanded=${open}
            onClick=${() => setOpen((v) => !v)}
          >
            <span aria-hidden="true">${open ? '▾' : '▸'}</span>
            <span>${entry.model} · ${entry.status}${tok}</span>
          </button>`
        : html`<div class="text-2xs font-mono text-[var(--color-fg-secondary,#9da7b3)]">${entry.model} · ${entry.status}${tok}</div>`}
      ${entry.answer && open
        ? html`<div class="mt-1 max-h-64 overflow-y-auto"><${FusionMarkdown} text=${entry.answer} /></div>`
        : null}
      ${entry.reason
        ? html`<div class="text-xs mt-1 text-[var(--color-danger,#e06c75)]">${entry.reason}</div>`
        : null}
    </div>
  `
}

function ChatFusionCard({ boardPostId, runId, fallbackText }: { boardPostId: string; runId?: string; fallbackText?: string }) {
  const [expanded, setExpanded] = useState(false)
  const [state, setState] = useState<{
    status: 'idle' | 'loading' | 'loaded' | 'error'
    panel: FusionPanelEntry[]
    judge: FusionJudgeView | null
    totalOutputTokens?: number
    error?: string
  }>({ status: 'idle', panel: [], judge: null })
  // Fetch-once guard. state.status must NOT be in the effect deps: the
  // setState('loading') below would otherwise re-run the effect, whose cleanup
  // flips `alive` false and drops the in-flight result (the card stays on
  // "loading" forever). A ref keeps the trigger out of the dependency array.
  const fetchedRef = useRef(false)

  useEffect(() => {
    if (!expanded || fetchedRef.current) return
    fetchedRef.current = true
    let alive = true
    setState((s) => ({ ...s, status: 'loading' }))
    fetchBoardPost(boardPostId)
      .then((post) => {
        if (!alive) return
        setState({
          status: 'loaded',
          panel: asFusionPanel(post.meta),
          judge: asFusionJudge(post.meta),
          totalOutputTokens: asFusionTotalOutputTokens(post.meta),
        })
      })
      .catch((err: unknown) => {
        if (!alive) return
        setState({ status: 'error', panel: [], judge: null, error: err instanceof Error ? err.message : '불러오기 실패' })
      })
    return () => { alive = false }
  }, [expanded, boardPostId])

  const answeredCount = state.panel.filter((p) => p.status === 'answered').length
  const usageLabel =
    state.totalOutputTokens !== undefined ? ` · ${state.totalOutputTokens.toLocaleString()} tok` : ''
  // Keeper-v2 messages.jsx fusion block: .msg-fusion > .msg-fusion-h (tag · run ·
  // decision badge) + .msg-fusion-ans + .msg-fusion-foot (panel count · run link).
  // Skin is vendored in keeper-v2/fusion.css. The decision badge/answer only render
  // once the board post is lazy-fetched on expand — before that the live signal
  // does not exist locally and nothing is fabricated for them.
  const decSpec = state.status === 'loaded' && state.judge?.decision
    ? fusionDecisionSpec(state.judge.decision)
    : null
  return html`
    <div class=${`msg-fusion${decSpec?.cls ? ` dec-${decSpec.cls}` : ''}`} data-fusion-card>
      <button
        type="button"
        class="msg-fusion-h w-full text-left ${CHAT_FOCUS_RING}"
        aria-expanded=${expanded}
        onClick=${() => setExpanded((v) => !v)}
      >
        <span aria-hidden="true">${expanded ? '▾' : '▸'}</span>
        <span class="msg-fusion-tag">◈ Fusion 심의</span>
        <span class="text-[var(--color-fg-secondary,#9da7b3)]">
          ${state.status === 'loaded'
            ? `패널 ${answeredCount}/${state.panel.length} 합의${usageLabel}`
            : '패널 합의 상세'}
        </span>
        ${runId ? html`<span class="msg-fusion-run mono">${runId.slice(0, 12)}</span>` : null}
        ${decSpec
          ? html`<span class=${`fus-dec-badge ${decSpec.cls}`}>${decSpec.glyph} ${decSpec.lbl}</span>`
          : null}
      </button>
      <div class="msg-fusion-foot">
        ${state.status === 'loaded'
          ? html`<span>패널 ${state.panel.length}개 · 심판 종합</span>`
          : null}
        <button
          type="button"
          class="inline-flex items-center gap-1 rounded-[var(--r-0,4px)] border border-[var(--color-brass-border,#3a3a2a)] bg-[var(--color-bg-surface,#111827)] px-2 py-1 text-2xs font-medium text-[var(--color-fg-secondary,#9da7b3)] hover:text-[var(--color-fg-primary,#f3f4f6)] ${CHAT_FOCUS_RING}"
          onClick=${() => navigate('board', { post: boardPostId })}
          data-testid="fusion-chat-open-board"
        >
          <${ExternalLink} size=${12} aria-hidden="true" />
          <span>Board</span>
        </button>
        ${runId
          ? html`
            <button
              type="button"
              class="msg-fusion-link"
              onClick=${() => navigate('fusion', { run_id: runId })}
              data-testid="fusion-chat-open-run"
            >전체 패널·심판 보기 →</button>
          `
          : null}
      </div>
      ${expanded
        ? html`
          <div class="px-3 pb-3 flex flex-col gap-3" data-fusion-detail>
            ${state.status === 'loading'
              ? html`<div class="text-xs text-[var(--color-fg-secondary,#9da7b3)]">불러오는 중…</div>`
              : null}
            ${state.status === 'error'
              ? html`
                <div class="text-xs text-[var(--color-danger,#e06c75)]">상세를 불러오지 못했습니다: ${state.error}</div>
                ${fallbackText && fallbackText.trim()
                  ? html`<div class="mt-1" data-fusion-fallback><${FusionMarkdown} text=${fallbackText} /></div>`
                  : null}
              `
              : null}
            ${state.status === 'loaded'
              ? html`
                ${state.judge
                  ? html`
                    <div class="rounded border border-[var(--color-brass-border,#3a3a2a)] px-2 py-1.5" data-fusion-judge>
                      <div class="text-2xs font-mono text-[var(--color-fg-secondary,#9da7b3)]">
                        judge · ${state.judge.status}${state.judge.decision ? html` · ${state.judge.decision}` : null}
                      </div>
                      ${state.judge.synthesis
                        ? html`<div class="msg-fusion-ans"><${FusionMarkdown} text=${state.judge.synthesis} /></div>`
                        : state.judge.resolvedAnswer
                          ? html`<div class="msg-fusion-ans"><${FusionMarkdown} text=${state.judge.resolvedAnswer} /></div>`
                          : state.judge.error
                            ? html`<div class="msg-fusion-ans"><${FusionMarkdown} text=${state.judge.error} /></div>`
                            : null}
                    </div>
                  `
                  : null}
                ${state.panel.length > 0
                  ? html`
                    <div class="flex flex-col gap-2">
                      <div class="text-2xs font-mono uppercase tracking-wide text-[var(--color-fg-secondary,#9da7b3)]">패널 ${state.panel.length}</div>
                      ${state.panel.map((p, i) => html`<${FusionPanelRow} key=${i} entry=${p} />`)}
                    </div>
                  `
                  : null}
                ${state.panel.length === 0 && !state.judge
                  ? fallbackText && fallbackText.trim()
                    ? html`<div class="mt-1" data-fusion-fallback><${FusionMarkdown} text=${fallbackText} /></div>`
                    : html`<div class="text-xs text-[var(--color-fg-secondary,#9da7b3)]">패널/심판 상세가 비어 있습니다.</div>`
                  : null}
              `
              : null}
            <div class="text-2xs text-[var(--color-fg-muted,#6b7280)]" data-fusion-retention>심의 상세는 board 보관 기간이 지나면 만료됩니다.</div>
          </div>
        `
        : null}
    </div>
  `
}

function ChatPersistedThinkingBlock({ content, redacted }: { content: string; redacted: boolean }) {
  if (!redacted) {
    return html`
      <div class="chat-block-trace" data-chat-block="thinking" data-chat-thinking-redacted="false">
        <${ChatTraceStep} step=${{ kind: 'think', text: content }} />
      </div>
    `
  }
  return html`
    <div class="chat-block-trace" data-chat-block="thinking" data-chat-thinking-redacted="true">
      <div class="chat-block-tstep think">
        <span class="chat-block-tnode"></span>
        <div class="min-w-0 flex-1">
          <div class="chat-block-tstep-row">
            <span class="chat-block-tstep-kind">Thinking</span>
          </div>
          <div class="chat-block-tstep-text">Thinking 본문은 provider 서명으로만 제공되어 표시할 수 없습니다.</div>
        </div>
      </div>
    </div>
  `
}

function ChatBlock({ block, fallbackText }: { block: ChatBlock; fallbackText?: string }) {
  switch (block.t) {
    case 'p': return html`<${ChatTextBlock} html=${block.html} />`
    case 'h4': return html`<${ChatHeadingBlock} html=${block.html} />`
    case 'ul': return html`<${ChatListBlock} items=${block.items} />`
    case 'callout': return html`<${ChatCalloutBlock} severity=${block.severity} html=${block.html} />`
    case 'table': return html`<${ChatTableBlock} head=${block.head} rows=${block.rows} />`
    case 'code': return html`<${ChatCodeBlock} cap=${block.cap} html=${block.html} source=${block.source} />`
    case 'shell': return html`<${ChatShellBlock} title=${block.title} lines=${block.lines} exit=${block.exit} dur=${block.dur} />`
    case 'artifact': return html`<${ChatArtifactBlock} kind=${block.kind} name=${block.name} size=${block.size} note=${block.note} data=${block.data} mimeType=${block.mimeType} />`
    case 'chart': return html`<${ChatChartBlock} title=${block.title} series=${block.series} labels=${block.labels} xLabel=${block.xLabel} yMax=${block.yMax} />`
    case 'suggestions': return html`<${ChatSuggestionsBlock} items=${block.items} />`
    case 'issue': return html`<${ChatIssueBlock} repo=${block.repo} number=${block.number} title=${block.title} status=${block.status} url=${block.url} meta=${block.meta} />`
    case 'attach': return html`<${ChatAttachBlock} name=${block.name} dims=${block.dims} src=${block.src} svg=${block.svg} ph=${block.ph} via=${block.via} size=${block.size} id=${block.id} kind=${block.kind} mimeType=${block.mimeType} sizeBytes=${block.sizeBytes} />`
    case 'voice': return html`<${ChatVoiceBlock} secs=${block.secs} wave=${block.wave} via=${block.via} size=${block.size} transcript=${block.transcript} src=${block.src} />`
    case 'image': return html`<${ChatImageBlock} src=${block.src} ph=${block.ph} cap=${block.cap} />`
    case 'svg': return html`<${ChatSvgBlock} svg=${block.svg} cap=${block.cap} />`
    case 'mermaid': return html`<${ChatMermaidBlock} source=${block.source} caption=${block.caption} />`
    case 'trace': return html`<${ChatTraceBlock} trace=${block.trace} omitted=${block.omitted} />`
    case 'thinking': return html`<${ChatPersistedThinkingBlock} content=${block.content} redacted=${block.redacted} />`
    case 'link': return html`<${ChatLinkBlock} url=${block.url} title=${block.title} desc=${block.desc} meta=${block.meta} fav=${block.fav} kind=${block.kind} />`
    case 'broadcast': return html`<${ChatBroadcastBlock} scope=${block.scope} via=${block.via} note=${block.note} recipients=${block.recipients} />`
    case 'fusion': return html`<${ChatFusionCard} boardPostId=${block.board_post_id} runId=${block.run_id} fallbackText=${fallbackText} />`
    default: return null
  }
}

// How much body a block list renders, near enough to decide whether the reader
// needs a fold. Serialized size rather than a per-variant character count:
// there are seventeen block shapes and a new one must not silently stop
// counting. The number is an approximation of volume, not of characters, so it
// is compared against its own threshold.
const blockBodyWeight = (blocks: ChatBlock[]): number =>
  blocks
    .filter(block => block.t !== 'thinking')
    .reduce((total, block) => total + JSON.stringify(block).length, 0)

function ChatBlocks({ blocks, fallbackText }: { blocks: ChatBlock[]; fallbackText?: string }) {
  return html`
    <div class="flex flex-col gap-3" data-chat-blocks>
      ${blocks.map((b, i) => html`<${ChatBlock} key=${i} block=${b} fallbackText=${fallbackText} />`)}
    </div>
  `
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

function renderStructuredFailureText(text: string): Array<string | VNode> {
  return text.split(/(\s+)/).map((part, index) => {
    if (!part || /^\s+$/.test(part)) return part
    return html`<span class="chat-error-token" key=${index}>${part}</span>`
  })
}

/** Typed failure card for kind=transport_failure rows.
 *
 * The discriminator is the writer-declared row kind (normalized to the closed
 * delivery='transport_failure' variant), never a string match on the content.
 * The raw error text is diagnostic payload, shown collapsed. The reassurance line states
 * what the backend guarantees: a Transport_failure row is watermark-neutral
 * (keeper_chat_store), so the user message it failed to answer stays pending
 * for the keeper's next turn. */
function ChatFailureCard({ diagnostic }: { diagnostic: string }) {
  const [detailOpen, setDetailOpen] = useState(false)
  return html`
    <div
      class="flex flex-col gap-2 rounded-[var(--r-1)] border border-[var(--color-status-error)]/40 bg-[var(--color-bg-surface)] p-3"
      data-chat-structured-error
      data-chat-failure-card
    >
      <div class="flex flex-wrap items-center gap-2">
        <span
          class="inline-flex items-center rounded-[var(--r-0)] bg-[var(--color-status-error)]/15 px-2 py-0.5 text-2xs font-bold uppercase tracking-[var(--track-caps)] text-[var(--color-status-error)]"
        >
          응답 실패
        </span>
        <span class="text-sm font-semibold text-[var(--color-fg-primary)]">
          이 턴은 응답을 만들지 못했습니다
        </span>
      </div>
      <p class="m-0 text-sm leading-airy text-[var(--color-fg-secondary)]" data-chat-failure-reassurance>
        보낸 메시지는 사라지지 않았습니다. 이 실패 기록은 처리 완료로 간주되지 않으며, keeper가 이후 정상 응답하기 전까지 다시 처리 대상에 남습니다.
      </p>
      <div class="flex items-center gap-2">
        <button
          type="button"
          class="self-start rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2.5 py-1 text-xs font-medium text-[var(--color-fg-secondary)] transition-colors hover:bg-[var(--color-bg-hover)] hover:text-[var(--color-fg-primary)] ${CHAT_FOCUS_RING}"
          aria-expanded=${detailOpen}
          data-chat-failure-detail-toggle
          onClick=${() => { setDetailOpen(open => !open) }}
        >
          ${detailOpen ? '상세 접기' : '오류 상세 보기'}
        </button>
        <button
          type="button"
          class="self-start rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2.5 py-1 text-xs font-medium text-[var(--color-fg-secondary)] transition-colors hover:bg-[var(--color-bg-hover)] hover:text-[var(--color-fg-primary)] ${CHAT_FOCUS_RING}"
          data-chat-failure-copy
          onClick=${() => { void copyWithToast(diagnostic, '오류 내용을 복사했습니다') }}
        >
          오류 복사
        </button>
      </div>
      ${detailOpen
        ? html`
            <pre class="chat-error-text" data-chat-failure-detail>${renderStructuredFailureText(diagnostic)}</pre>
          `
        : null}
    </div>
  `
}

function ApprovalLifecycleCard({ lifecycle }: { lifecycle: KeeperApprovalLifecycle }) {
  const spec = (() => {
    switch (lifecycle.phase) {
      case 'resolved_approved':
        return { badge: '승인됨', title: '실행 권한이 승인되었습니다', detail: '외부 효과는 아직 적용 확인 전입니다.', tone: 'var(--color-status-info)' }
      case 'resolved_rejected':
        return { badge: '거절됨', title: '실행 요청이 거절되었습니다', detail: '외부 효과는 실행되지 않습니다.', tone: 'var(--color-status-error)' }
      case 'replay_applied':
        return { badge: '적용 완료', title: '승인된 작업이 적용되었습니다', detail: '호스트 replay 결과가 영속 기록되었습니다.', tone: 'var(--color-status-success)' }
      case 'replay_applied_with_warning':
        return { badge: '적용 경고', title: '작업은 적용됐지만 경고가 있습니다', detail: '상세 결과는 replay 증거를 확인하세요.', tone: 'var(--color-status-warning)' }
      case 'replay_failed':
        return { badge: '적용 실패', title: '승인된 작업을 적용하지 못했습니다', detail: '실패 결과가 영속 기록되었으며 자동 재실행하지 않습니다.', tone: 'var(--color-status-error)' }
      case 'replay_indeterminate':
        return { badge: '적용 불명', title: '작업 적용 여부를 확정할 수 없습니다', detail: '효과가 이미 발생했을 수 있어 자동 재실행하지 않습니다.', tone: 'var(--color-status-warning)' }
      case 'continuation_recorded':
        return { badge: '이어감', title: '승인 후 후속 작업을 이어갔습니다', detail: 'replay 결과를 받은 Keeper 턴이 완료되거나 안전하게 checkpoint되었습니다.', tone: 'var(--color-status-success)' }
    }
  })()
  return html`
    <div
      class="flex flex-col gap-2 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3"
      data-chat-approval-lifecycle=${lifecycle.phase}
      data-chat-approval-id=${lifecycle.approvalId}
    >
      <div class="flex flex-wrap items-center gap-2">
        <span
          class="inline-flex items-center rounded-[var(--r-0)] px-2 py-0.5 text-2xs font-bold uppercase tracking-[var(--track-caps)]"
          style=${{ color: spec.tone, backgroundColor: `color-mix(in srgb, ${spec.tone} 15%, transparent)` }}
        >${spec.badge}</span>
        <span class="text-sm font-semibold text-[var(--color-fg-primary)]">${spec.title}</span>
      </div>
      <p class="m-0 text-sm leading-airy text-[var(--color-fg-secondary)]">${spec.detail}</p>
      <div class="flex flex-wrap gap-2 text-2xs text-[var(--color-fg-muted)]">
        <code>${lifecycle.approvalId}</code>
        ${lifecycle.toolName ? html`<span>${lifecycle.toolName}</span>` : null}
        ${lifecycle.artifactSha256 ? html`<code>${lifecycle.artifactSha256.slice(0, 12)}</code>` : null}
      </div>
    </div>
  `
}

function AttachmentCard({ attachment }: { attachment: KeeperConversationAttachment }) {
  const [open, setOpen] = useState(false)
  const canDownload = isSafeAttachmentHref(attachment)
  const meta = attachmentMeta(attachment)
  const isImage = isRenderableImageAttachment(attachment)
  const multimodalKind = userInputMediaKindForAttachment(attachment)

  return html`
    <div
      class="overflow-hidden rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)]"
      data-chat-attachment-card=${attachment.id}
      data-chat-multimodal-source="persisted_attachment"
      data-chat-multimodal-kind=${multimodalKind}
      data-chat-multimodal-attachment-id=${attachment.id}
      data-chat-multimodal-mime=${attachment.mimeType}
      data-chat-multimodal-size-bytes=${attachment.size}
    >
      ${isImage
        ? html`
            <button
              type="button"
              class="block w-full text-left hover:bg-[var(--color-bg-hover)]"
              onClick=${() => setOpen(true)}
              aria-label=${`${attachment.name} 미리보기`}
            >
              <img
                src=${attachment.data}
                alt=${attachment.name}
                class="max-h-52 w-full rounded-[var(--r-1)] object-contain"
                loading="lazy"
              />
            </button>
          `
        : canDownload
          ? html`
              <a
                href=${attachment.data}
                download=${attachment.name}
                class="block hover:bg-[var(--color-bg-hover)]"
                aria-label=${`${attachment.name} 날려받기`}
              >
                <div class="flex min-h-18 items-center gap-3 px-3 py-3">
                  <span class="inline-flex h-9 w-11 shrink-0 items-center justify-center rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-panel-alt)] text-2xs font-bold uppercase tracking-2 text-[var(--color-fg-secondary)]">
                    FILE
                  </span>
                  <div class="min-w-0">
                    <div class="truncate text-sm font-bold text-[var(--color-fg-primary)]">${attachment.name}</div>
                    <div class="mt-1 text-xs text-[var(--color-fg-secondary)]">${meta}</div>
                  </div>
                </div>
              </a>
            `
          : html`
              <div class="flex min-h-18 items-center gap-3 px-3 py-3">
                <span class="inline-flex h-9 w-11 shrink-0 items-center justify-center rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-panel-alt)] text-2xs font-bold uppercase tracking-2 text-[var(--color-fg-secondary)]">
                  FILE
                </span>
                <div class="min-w-0">
                  <div class="truncate text-sm font-bold text-[var(--color-fg-primary)]">${attachment.name}</div>
                  <div class="mt-1 text-xs text-[var(--color-fg-secondary)]">${meta}</div>
                </div>
              </div>
            `}
      <div class="flex items-center justify-between gap-2 border-t border-[var(--color-border-default)] px-3 py-2">
        <div class="min-w-0">
          <div class="truncate text-sm font-bold text-[var(--color-fg-primary)]">${attachment.name}</div>
          <div class="mt-1 text-xs text-[var(--color-fg-secondary)]">${meta}</div>
        </div>
        ${canDownload
          ? html`
              <a
                href=${attachment.data}
                download=${attachment.name}
                class="chat-block-artifact-btn shrink-0"
                aria-label=${`${attachment.name} 날려받기`}
              >
                ↓
              </a>
            `
          : null}
      </div>
      ${open && isImage
        ? html`
            <${ChatPreviewModal} title=${attachment.name} onClose=${() => setOpen(false)}>
              <img
                src=${attachment.data}
                alt=${attachment.name}
                class="max-h-[80vh] max-w-full rounded-[var(--r-1)] object-contain"
              />
            <//>
          `
        : null}
    </div>
  `
}

function userInputMediaKindForAttachment(
  attachment: KeeperConversationAttachment,
): Exclude<KeeperUserInputBlock['type'], 'text'> {
  if (attachment.type === 'image') return 'image'
  if (attachment.mimeType.startsWith('audio/')) return 'audio'
  return 'document'
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
  const [loadError, setLoadError] = useState(false)
  if (clip.expired) {
    return html`
      <div class="chat-audio-clip" data-chat-audio-clip>
        <div class="chat-audio-wave" aria-hidden="true">
          ${Array.from({ length: 24 }, (_, i) => html`
            <span
              key=${i}
              class="chat-audio-bar"
              style=${{ height: `${6 + (i % 7) * 3}px` }}
            />
          `)}
        </div>
        <span class="chat-audio-error">음성이 만료되었습니다.</span>
        ${clip.messageText
          ? html`<span class="chat-audio-caption">${clip.messageText}</span>`
          : null}
      </div>
    `
  }
  const fallbackPath = `/api/v1/voice/audio/${encodeURIComponent(clip.token)}`
  const fallbackSrc = typeof window !== 'undefined'
    ? new URL(fallbackPath, window.location.href).href
    : fallbackPath
  const audioSrc = clip.audioUrl ?? fallbackSrc
  const duration = formatAudioDuration(clip.durationSec)
  return html`
    <div class="chat-audio-clip" data-chat-audio-clip>
      <div class="chat-audio-wave" aria-hidden="true">
        ${Array.from({ length: 24 }, (_, i) => html`
          <span
            key=${i}
            class="chat-audio-bar"
            style=${{ height: `${6 + (i % 7) * 3}px` }}
          />
        `)}
      </div>
      <audio
        controls
        preload="none"
        src=${audioSrc}
        aria-label=${clip.messageText || '음성 메시지'}
        onError=${() => { setLoadError(true) }}
      />
      ${duration
        ? html`<span class="chat-audio-dur">${duration}</span>`
        : null}
      ${clip.deviceId
        ? html`<span class="chat-audio-device" title=${`device: ${clip.deviceId}`}>🔊</span>`
        : null}
      ${clip.messageText
        ? html`<span class="chat-audio-caption">${clip.messageText}</span>`
        : null}
      ${loadError
        ? html`<span class="chat-audio-error">음성을 불러올 수 없습니다.</span>`
        : null}
    </div>
  `
}

// Block types that parseMarkdownToBlocks cannot reproduce from message text:
// synthesized voice clips, attachments, fusion deliberation cards, artifacts,
// broadcasts, traces, and shell transcripts. When an assistant/system message
// carries one of these the server blocks are rendered as-is; otherwise the
// prose is re-parsed richly. (Complement of the
// markdown-derived block set:
// p/h4/ul/callout/table/code/mermaid/image/svg/link.)
const CARD_BLOCK_TYPES: ReadonlySet<ChatBlock['t']> = new Set([
  'voice',
  'attach',
  'fusion',
  'artifact',
  'chart',
  'suggestions',
  'issue',
  'broadcast',
  'trace',
  'shell',
  'status',
])

type ChatControlStatus = 'continuation_checkpoint' | 'external_effect_pending' | 'external_effect_completed'

function chatControlStatus(entry: KeeperConversationEntry): ChatControlStatus | null {
  const persistedStatus = (entry.blocks ?? []).find(
    (block): block is Extract<ChatBlock, { t: 'status' }> => block.t === 'status',
  )
  if (persistedStatus) return persistedStatus.kind
  const turnOutcome = entry.details?.turnOutcome
  return turnOutcome === 'continuation_checkpoint'
    || turnOutcome === 'external_effect_pending'
    || turnOutcome === 'external_effect_completed'
    ? turnOutcome
    : null
}

function ChatControlStatusCard({
  entry,
  action,
}: {
  entry: KeeperConversationEntry
  action?: ChatTranscriptAction
}) {
  const status = chatControlStatus(entry)
  if (!status) return null
  const timestamp = timeLabel(entry.timestamp)
  const supportingBlocks = (entry.blocks ?? []).filter(block => block.t !== 'status')

  if (status === 'continuation_checkpoint') {
    return html`
      <article
        class="w-full rounded-[var(--r-2)] border border-[var(--color-border-default)] bg-[var(--color-bg-subtle)] px-4 py-3.5"
        role="status"
        aria-live="polite"
        data-chat-control-status="continuation_checkpoint"
        data-chat-entry-id=${entry.id}
        data-chat-turn-ref=${entry.turnRef ?? undefined}
      >
        <div class="flex items-start gap-3">
          <div
            class="mt-0.5 flex size-9 shrink-0 items-center justify-center rounded-full border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] text-[var(--color-fg-secondary)]"
            aria-hidden="true"
          >
            <${ShieldCheck} size=${18} />
          </div>
          <div class="min-w-0 flex-1">
            <div class="flex flex-wrap items-center gap-x-2 gap-y-1">
              <strong class="text-sm font-semibold text-[var(--color-fg-primary)]">이어가기 예약됨</strong>
              ${timestamp
                ? html`<span class="text-2xs tabular-nums text-[var(--color-fg-muted)]">${timestamp}</span>`
                : null}
            </div>
            <p class="mt-1 text-sm leading-paragraph text-[var(--color-fg-secondary)]">
              작업이 체크포인트에 저장되었습니다.
            </p>
            <p class="mt-0.5 text-xs leading-paragraph text-[var(--color-fg-muted)]">
              Keeper가 다음 주기에 이어서 처리합니다.
            </p>
          </div>
        </div>
        ${supportingBlocks.length > 0
          ? html`<div class="mt-3"><${ChatBlocks} blocks=${supportingBlocks} fallbackText="" /></div>`
          : null}
      </article>
    `
  }

  if (status === 'external_effect_completed') {
    // The delivery target names where the terminal surface post actually
    // landed; legacy events without it keep the generic connector copy.
    const target = entry.details?.externalEffectTarget ?? null
    const copy = (() => {
      if (target?.kind === 'dashboard') {
        return {
          title: '대시보드에 게시 완료',
          body: 'Keeper의 답변이 이 대시보드 채팅에 게시되었습니다.',
          hint: '위 대화에서 확인할 수 있습니다.',
        }
      }
      if (target?.kind === 'slack') {
        return {
          title: 'Slack으로 답변 완료',
          body: target.threadTs
            ? `Keeper의 답변이 Slack 채널 ${target.channelId}의 스레드로 전송되었습니다.`
            : `Keeper의 답변이 Slack 채널 ${target.channelId}로 전송되었습니다.`,
          hint: '답변 내용은 해당 채널에서 확인할 수 있습니다.',
        }
      }
      if (target?.kind === 'discord') {
        return {
          title: 'Discord로 답변 완료',
          body: `Keeper의 답변이 Discord 채널 ${target.channelId}로 전송되었습니다.`,
          hint: '답변 내용은 해당 채널에서 확인할 수 있습니다.',
        }
      }
      return {
        title: '커넥터로 답변 완료',
        body: 'Keeper의 답변이 외부 커넥터(Slack/Discord)로 전송되었습니다.',
        hint: '답변 내용은 해당 채널에서 확인할 수 있습니다.',
      }
    })()
    return html`
      <article
        class="w-full rounded-[var(--r-2)] border border-[var(--color-border-default)] bg-[var(--color-bg-subtle)] px-4 py-3.5"
        role="status"
        aria-live="polite"
        data-chat-control-status="external_effect_completed"
        data-chat-effect-target=${target?.kind ?? undefined}
        data-chat-entry-id=${entry.id}
        data-chat-turn-ref=${entry.turnRef ?? undefined}
      >
        <div class="flex items-start gap-3">
          <div
            class="mt-0.5 flex size-9 shrink-0 items-center justify-center rounded-full border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] text-[var(--color-fg-secondary)]"
            aria-hidden="true"
          >
            <${ExternalLink} size=${18} />
          </div>
          <div class="min-w-0 flex-1">
            <div class="flex flex-wrap items-center gap-x-2 gap-y-1">
              <strong class="text-sm font-semibold text-[var(--color-fg-primary)]">${copy.title}</strong>
              ${timestamp
                ? html`<span class="text-2xs tabular-nums text-[var(--color-fg-muted)]">${timestamp}</span>`
                : null}
            </div>
            <p class="mt-1 text-sm leading-paragraph text-[var(--color-fg-secondary)]">
              ${copy.body}
            </p>
            <p class="mt-0.5 text-xs leading-paragraph text-[var(--color-fg-muted)]">
              ${copy.hint}
            </p>
          </div>
        </div>
        ${supportingBlocks.length > 0
          ? html`<div class="mt-3"><${ChatBlocks} blocks=${supportingBlocks} fallbackText="" /></div>`
          : null}
      </article>
    `
  }

  return html`
    <article
      class="w-full rounded-[var(--r-2)] border border-[var(--warn-35)] bg-[var(--warn-10)] px-4 py-3.5"
      role="status"
      aria-live="polite"
      data-chat-control-status="external_effect_pending"
      data-chat-entry-id=${entry.id}
      data-chat-turn-ref=${entry.turnRef ?? undefined}
    >
      <div class="flex items-start gap-3">
        <div
          class="mt-0.5 flex size-9 shrink-0 items-center justify-center rounded-full border border-[var(--warn-35)] bg-[var(--color-bg-surface)] text-[var(--color-status-warn)]"
          aria-hidden="true"
        >
          <${ShieldCheck} size=${18} />
        </div>
        <div class="min-w-0 flex-1">
          <div class="flex flex-wrap items-center gap-x-2 gap-y-1">
            <strong class="text-sm font-semibold text-[var(--color-fg-primary)]">승인 요청됨</strong>
            ${timestamp
              ? html`<span class="text-2xs tabular-nums text-[var(--color-fg-muted)]">${timestamp}</span>`
              : null}
          </div>
          <p class="mt-1 text-sm leading-paragraph text-[var(--color-fg-secondary)]">
            외부 작업을 실행하기 위한 확인 요청이 기록되었습니다.
          </p>
          <p class="mt-0.5 text-xs leading-paragraph text-[var(--color-fg-muted)]">
            현재 승인 상태는 승인 화면에서 확인할 수 있습니다.
          </p>
          <div class="mt-3 flex flex-wrap gap-2">
            <button
              type="button"
              class="inline-flex items-center gap-1.5 rounded-[var(--r-1)] border border-[var(--warn-35)] bg-[var(--color-bg-surface)] px-3 py-1.5 text-xs font-semibold text-[var(--color-fg-primary)] transition-colors hover:bg-[var(--color-bg-hover)] ${CHAT_FOCUS_RING}"
              onClick=${() => navigate('command', { section: 'operations', view: 'gate' })}
            >
              승인 화면 열기
              <${ArrowRight} size=${13} aria-hidden="true" />
            </button>
            ${action?.onClick
              ? html`
                  <button
                    type="button"
                    class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-transparent px-3 py-1.5 text-xs font-medium text-[var(--color-fg-secondary)] transition-colors hover:bg-[var(--color-bg-hover)] hover:text-[var(--color-fg-primary)] ${CHAT_FOCUS_RING}"
                    onClick=${() => action.onClick?.(entry)}
                  >
                    ${action.label ?? '턴 상세'}
                  </button>
                `
              : null}
          </div>
        </div>
      </div>
      ${supportingBlocks.length > 0
        ? html`<div class="mt-3"><${ChatBlocks} blocks=${supportingBlocks} fallbackText="" /></div>`
        : null}
    </article>
  `
}

// Memoized message bubble. A streaming reply re-renders the conversation panel
// on every SSE event; the transcript reconcile preserves the entry reference of
// every settled message (keeper-state.ts), and KeeperConversationPanel hoists
// the `action` object to a useMemo, so a settled bubble's props are all
// referentially stable across a stream chunk and its body is skipped.
//
// The `action` stabilization is the load-bearing half: without it the inline
// `{ ...onClick }` literal is a new reference each render and the bubble re-runs
// regardless of memo (the test 're-renders the settled bubble when action is a
// new object…' locks this).
//
// Tool/thinking turns render through TurnWorkBundle. buildChatRenderUnits
// rebuilds `tools` arrays each render, so the bundle comparator compares entry
// references inside those arrays instead of the array object itself.
const ChatMessageBubble = memo(function ChatMessageBubble({
  entry,
  showMetadata = true,
  variant = 'default',
  showSourceBadge = false,
  contextScope = null,
  action,
}: {
  entry: KeeperConversationEntry
  showMetadata?: boolean
  variant?: ChatTranscriptVariant
  showSourceBadge?: boolean
  // Keeper-v2 CtxFrom strip, precomputed by ChatTranscript from the transcript's
  // own channel rows (null for non-connector entries). Precomputed upstream so
  // this memo's shallow compare sees a stable object across unrelated re-renders.
  contextScope?: ChatContextScope | null
  action?: ChatTranscriptAction
}) {
  if (
    entry.delivery === 'no_reply'
    && !entry.text.trim()
    && !entry.blocks?.length
    && !entry.attachments?.length
  ) {
    return null
  }

  const [expandedRaw, setExpandedRaw] = useState(false)
  const [rawExpandedRaw, setRawExpandedRaw] = useState(false)
  const [messageCollapsed, setMessageCollapsed] = useState(true)
  const expanded = showMetadata && expandedRaw
  const rawExpanded = showMetadata && rawExpandedRaw
  const [bubbleRef, bubbleInView] = useInViewOnce<HTMLElement>('300px')
  const liveLabel = liveMessageLabel(entry)
  const messageText = liveLabel ? '' : entry.text || '(empty reply)'
  const messageLength = messageText.length
  // keeper-state.ts maps the writer-declared kind=transport_failure to its own
  // closed delivery variant; only that durable row renders the typed
  // failure card, because its reassurance ("보낸 메시지는 사라지지 않았습니다")
  // holds only when the keeper never answered. interrupted/timeout keep any
  // partial text and render as prose plus the diagnostic banner below.
  const isFailureMessage =
    entry.delivery === 'transport_failure' && !!entry.error?.trim()
  const richTextRole = entry.role === 'assistant' || entry.role === 'system'
  const hasRealText = !liveLabel && !!entry.text && entry.text.trim().length > 0
  const traceOwnsIntermediateText = !hasRealText && (entry.traceSteps?.length ?? 0) > 0
  const hasCardBlock = (entry.blocks ?? []).some((b) => CARD_BLOCK_TYPES.has(b.t))
  const shouldParseRichBlocks =
    !isFailureMessage
    && richTextRole
    && hasRealText
    && !hasCardBlock
    && bubbleInView
    && hasMarkdownRenderCue(entry.text ?? '')
  // Re-parse assistant/system prose so markdown (code fences, tables, callouts)
  // renders as structured blocks. The backend persists only a line-based parse
  // (lib/keeper/keeper_chat_blocks.ml -> escaped <p>), so without this the rich
  // renderer never receives a code/table block. Skipped when the message owns a
  // card/clip the text cannot reproduce (CARD_BLOCK_TYPES) — those server blocks
  // render as-is.
  const [parsedBlocks, setParsedBlocks] = useState<ChatBlock[] | null>(null)
  useEffect(() => {
    let active = true
    if (!shouldParseRichBlocks) {
      setParsedBlocks(null)
      return () => { active = false }
    }
    void (async () => {
      try {
        const { parseMarkdownToBlocks } = await import('./markdown-blocks')
        const next = parseMarkdownToBlocks(entry.text ?? '')
        if (active) setParsedBlocks(next)
      } catch (err) {
        console.warn('[chat] rich markdown parse failed', err instanceof Error ? err.message : err)
        if (active) setParsedBlocks(null)
      }
    })()
    return () => { active = false }
  }, [shouldParseRichBlocks, entry.text])
  const persistedThinkingBlocks = (entry.blocks ?? [])
    .filter((block): block is Extract<ChatBlock, { t: 'thinking' }> => block.t === 'thinking')
  const renderedServerBlocks = parsedBlocks !== null
    ? [...persistedThinkingBlocks, ...parsedBlocks]
    : (entry.blocks ?? [])
  const effectiveBlocks = isFailureMessage ? [] : renderedServerBlocks
  const hasEffectiveBlocks = effectiveBlocks.length > 0
  const hasNonThinkingBlocks = effectiveBlocks.some(block => block.t !== 'thinking')
  const collapseThreshold = hasNonThinkingBlocks ? 2400 : 1200
  // A long body is a long body whether the server sent it as blocks or as
  // plain text. The clamp used to hang off the plain-text div alone, so a
  // message carrying any non-thinking block — which is most keeper output —
  // rendered through ChatBlocks with no way to fold it. Measure whichever
  // body this message actually renders.
  const collapsibleLength = hasNonThinkingBlocks
    ? blockBodyWeight(effectiveBlocks)
    : messageLength
  const isCollapsible = collapsibleLength > collapseThreshold
  const tone = bubbleTone(entry)
  const isMessenger = variant === 'messenger'
  const detailItems = detailSummary(entry.details)
  const canExpand = showMetadata && !!entry.details
  const overview = entry.details ? overviewRows(entry.details) : []
  const delivery = deliveryLabel(entry)
  const timestamp = timeLabel(entry.timestamp)
  const sourceBadge = showSourceBadge ? sourceBadgeInfo(entry) : null
  const streamContractBadge = streamContractBadgeInfo(entry)
  const attachments = entry.attachments ?? []
  const attachBlocks = effectiveBlocks.filter((block): block is Extract<ChatBlock, { t: 'attach' }> => block.t === 'attach')
  const persistedAttachmentKinds = attachments.map(userInputMediaKindForAttachment)
  const serverAttachKinds = attachBlocks
    .map(block => block.kind?.trim())
    .filter((value): value is string => Boolean(value))
  const multimodalKinds = Array.from(new Set([...persistedAttachmentKinds, ...serverAttachKinds]))
  const multimodalSources = [
    attachments.length > 0 ? 'persisted_attachment' : null,
    attachBlocks.length > 0 ? 'server_block' : null,
  ].filter((value): value is string => value !== null)
  const surfaceInfo = surfaceLink(entry.surface)
  const speakerInfo = speakerMeta(entry)
  const routeInfo = routeMeta(entry)

  // Keeper-v2 messages.jsx Message row vocabulary: the operator avatar is
  // `.msg-av.op` (keeper rows draw the sigil badge in the design, so msg-av
  // goes on user rows only); msg-col/msg-hd mark the content column and the
  // header row. The row keeps the dashboard's chat-bubble chrome — delivery,
  // stream-contract and meta chips are live signals the design has no slot for.
  return html`
    <article
      ref=${bubbleRef}
      class=${`chat-bubble ${tone} flex w-full flex-col backdrop-blur-sm ${
        isMessenger
          ? 'max-w-[82%] gap-2.5 rounded-[var(--radius-xl)] px-4 py-3.5'
          : 'max-w-[90%] gap-3 rounded-[var(--r-5)] px-4 py-3'
      }`}
      data-chat-variant=${variant}
      data-chat-entry-id=${entry.id}
      data-chat-role=${entry.role}
      data-chat-source=${entry.source}
      data-chat-delivery-state=${entry.delivery}
      data-chat-stream-state=${entry.streamState ?? 'complete'}
      data-chat-stream-contract-source=${entry.streamContract?.source ?? 'unspecified'}
      data-chat-stream-contract-status=${entry.streamContract?.status ?? 'unspecified'}
      data-chat-stream-contract-event=${entry.streamContract?.eventName ?? undefined}
      data-chat-stream-contract-request-id=${entry.streamContract?.requestId ?? undefined}
      data-chat-stream-contract-turn-ref=${entry.streamContract?.turnRef ?? undefined}
      data-chat-stream-contract-trace-events=${entry.streamContract?.traceEventCount ?? undefined}
      data-chat-stream-contract-lifecycle-events=${entry.streamContract?.lifecycleEvents?.join(',') ?? undefined}
      data-chat-stream-contract-reason=${entry.streamContract?.reason ?? undefined}
      data-chat-stream-contract-badge-state=${streamContractBadge?.state ?? undefined}
      data-chat-surface-kind=${entry.surface?.kind ?? undefined}
      data-chat-surface-address=${entry.surface?.address ? JSON.stringify(entry.surface.address) : undefined}
      data-chat-conversation-id=${entry.conversationId ?? undefined}
      data-chat-external-message-id=${entry.externalMessageId ?? undefined}
      data-chat-speaker-id=${entry.speakerId ?? undefined}
      data-chat-speaker-name=${entry.speakerName ?? undefined}
      data-chat-speaker-authority=${entry.speakerAuthority ?? undefined}
      data-chat-turn-ref=${entry.turnRef ?? undefined}
      data-chat-attachment-count=${attachments.length}
      data-chat-server-attach-block-count=${attachBlocks.length}
      data-chat-multimodal-sources=${multimodalSources.length > 0 ? multimodalSources.join(',') : undefined}
      data-chat-multimodal-kinds=${multimodalKinds.length > 0 ? multimodalKinds.join(',') : undefined}
    >
      <div class=${`flex justify-between gap-3 ${isMessenger ? 'items-center' : 'items-start'}`}>
        <div class=${`flex min-w-0 flex-1 gap-3 ${isMessenger ? 'items-center' : 'items-start'}`}>
          <div
            class=${`chat-avatar ${tone}${entry.role === 'user' ? ' msg-av op' : ''} flex shrink-0 items-center justify-center whitespace-nowrap text-xs font-bold uppercase tracking-[var(--track-caps)] ${
              isMessenger ? 'size-8 rounded-card' : 'size-10 rounded-[var(--r-1)]'
            }`}
          >
            ${avatarMonogram(entry)}
          </div>
          <div class="msg-col min-w-0 flex-1">
            ${isMessenger
              ? html`
                  <div class="msg-hd flex flex-wrap items-center gap-x-2 gap-y-1">
                    <span class="truncate text-sm font-semibold text-[var(--color-fg-primary)]">
                      ${avatarLabel(entry)}
                    </span>
                    <${ChatSpeakerHandle} entry=${entry} />
                    ${timestamp
                      ? html`<span class="text-2xs font-medium tabular-nums text-[var(--color-fg-secondary)]">${timestamp}</span>`
                      : null}
                    ${sourceBadge
                      ? html`<span
                          class=${`kw-src-badge ${sourceBadge.cls}`}
                          title=${sourceBadge.title || undefined}
                        >${sourceBadge.label}</span>`
                      : null}
                    ${showDeliveryBadge(entry, variant)
                      ? html`
                          <span
                            class="inline-flex items-center rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2 py-0.5 text-2xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-secondary)]"
                            data-chat-delivery=${delivery}
                          >
                            ${delivery}
                          </span>
                        `
                      : null}
                    <${StreamContractBadge} badge=${streamContractBadge} compact=${true} />
                    <${ChatMetaChip} info=${surfaceInfo} compact=${true} />
                    <${ChatMetaChip} info=${speakerInfo} compact=${true} />
                    <${ChatMetaChip} info=${routeInfo} compact=${true} />
                  </div>
                `
              : html`
                  <div class="msg-hd flex flex-wrap items-center gap-1.5">
                    <span
                      class=${`chat-role-chip ${tone} inline-flex items-center rounded-[var(--r-0)] px-2.5 py-1 text-2xs font-bold uppercase tracking-2`}
                    >
                      ${entry.label}
                    </span>
                    <${ChatSpeakerHandle} entry=${entry} />
                    ${showDeliveryBadge(entry, variant)
                      ? html`
                          <span
                            class="inline-flex items-center rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2.5 py-1 text-2xs font-semibold uppercase tracking-2 text-[var(--color-fg-secondary)]"
                            data-chat-delivery=${delivery}
                          >
                            ${delivery}
                          </span>
                        `
                      : null}
                    ${timestamp
                      ? html`
                          <span class="inline-flex items-center rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-panel-alt)] px-2.5 py-1 text-2xs font-medium tabular-nums text-[var(--color-fg-secondary)]">
                            ${timestamp}
                          </span>
                        `
                      : null}
                    <${StreamContractBadge} badge=${streamContractBadge} compact=${false} />
                    <${ChatMetaChip} info=${surfaceInfo} compact=${false} />
                    <${ChatMetaChip} info=${speakerInfo} compact=${false} />
                    <${ChatMetaChip} info=${routeInfo} compact=${false} />
                  </div>
                  <div class="mt-2 truncate text-sm font-bold text-[var(--color-fg-primary)]">
                    ${avatarLabel(entry)}
                  </div>
                `}
          </div>
        </div>
        ${action?.label && action.onClick
          ? html`
              <button
                type="button"
                class=${`border border-[var(--accent-20)] bg-[var(--accent-10)] text-xs font-semibold text-[var(--color-accent-fg)] transition-colors hover:bg-[var(--accent-20)] ${CHAT_FOCUS_RING} ${
                  isMessenger ? 'rounded-[var(--r-1)] px-2.5 py-1' : 'rounded-[var(--r-0)] px-3 py-1'
                }`}
                onClick=${() => action.onClick!(entry)}
                title=${action.title ?? action.label}
                data-testid="chat-message-action"
              >
                ${action.label}
              </button>
            `
          : null}
        ${richTextRole && hasRealText
          ? html`
              <button
                type="button"
                class=${`border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] text-xs font-medium text-[var(--color-fg-secondary)] transition-colors hover:bg-[var(--color-bg-hover)] hover:text-[var(--color-fg-primary)] ${CHAT_FOCUS_RING} ${
                  isMessenger ? 'rounded-[var(--r-1)] px-2.5 py-1' : 'rounded-[var(--r-0)] px-3 py-1'
                }`}
                onClick=${() => { void copyWithToast(entry.text, '메시지를 복사했습니다') }}
                title="메시지 복사"
                aria-label="메시지 복사"
                data-testid="chat-message-copy"
              >
                복사
              </button>
            `
          : null}
        ${canExpand
          ? html`
              <button
                type="button"
                class=${`border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] text-xs font-medium text-[var(--color-fg-secondary)] transition-colors hover:bg-[var(--color-bg-hover)] hover:text-[var(--color-fg-primary)] ${CHAT_FOCUS_RING} ${
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

      ${contextScope ? html`<${ChatContextScopeRow} scope=${contextScope} />` : null}

      ${showMetadata && detailItems.length > 0
        ? html`<div class=${`flex flex-wrap gap-1.5 ${isMessenger ? 'pt-0.5' : ''}`}>
            ${detailItems.map(item => html`
              <span class="inline-flex items-center rounded-[var(--r-0)] border border-[var(--color-accent-soft)] bg-[var(--accent-10)] px-2.5 py-1 text-2xs font-semibold text-[var(--color-fg-primary)]">
                ${item}
              </span>
            `)}
          </div>`
        : null}

      ${liveLabel
        ? html`<${LiveMessagePlaceholder} label=${liveLabel} />`
        : html`
            ${entry.approvalLifecycle
              ? html`<${ApprovalLifecycleCard} lifecycle=${entry.approvalLifecycle} />`
              : isFailureMessage
              ? html`<${ChatFailureCard}
                  diagnostic=${entry.error?.trim() ? entry.error : messageText}
                />`
              : hasEffectiveBlocks
              ? html`
                  <div class=${isCollapsible && messageCollapsed ? 'max-h-96 overflow-hidden' : ''}>
                    <${ChatBlocks} blocks=${effectiveBlocks} fallbackText=${entry.text} />
                  </div>
                  ${hasRealText && !hasNonThinkingBlocks
                    ? html`
                        <div
                          class=${`markdown-body whitespace-pre-wrap break-words text-base leading-airy text-[var(--color-fg-primary)] ${isCollapsible && messageCollapsed ? 'max-h-96 overflow-hidden' : ''}`}
                          dangerouslySetInnerHTML=${renderPlainLinkedHtml(messageText)}
                        />
                      `
                    : null}
                `
              : traceOwnsIntermediateText
              ? null
              : html`
                  <div
                    class=${`markdown-body whitespace-pre-wrap break-words text-base leading-airy text-[var(--color-fg-primary)] ${isCollapsible && messageCollapsed ? 'max-h-96 overflow-hidden' : ''}`}
                    dangerouslySetInnerHTML=${renderPlainLinkedHtml(messageText)}
                  />
                `}
            ${entry.delivery === 'streaming'
              ? html`<span class="inline-block ml-0.5 animate-pulse text-[var(--color-status-info)]" aria-hidden="true">▍</span>`
              : null}
          `}
      ${isCollapsible
        ? html`
            <button
              type="button"
              class="self-start rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-1 text-xs font-medium text-[var(--color-fg-secondary)] transition-colors hover:bg-[var(--color-bg-hover)] hover:text-[var(--color-fg-primary)] ${CHAT_FOCUS_RING}"
              onClick=${() => { setMessageCollapsed(!messageCollapsed) }}
            >
              ${messageCollapsed ? '더 보기' : '접기'}
            </button>
          `
        : null}
      ${attachments.length > 0
        ? html`
            <div class="grid grid-cols-[repeat(auto-fit,minmax(11rem,1fr))] gap-2">
              ${attachments.map(attachment => html`<${AttachmentCard} key=${attachment.id} attachment=${attachment} />`)}
            </div>
          `
        : null}
      ${entry.audio
        ? html`<${AudioPlayer} clip=${entry.audio} />`
        : null}
      ${entry.error && !isFailureMessage
        ? html`
            <div class="rounded-[var(--r-1)] border border-[var(--err-border)] bg-[var(--bad-soft)] px-3 py-2 text-sm font-medium leading-paragraph text-[var(--bad-light)]">
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
                          <div class="text-2xs font-bold uppercase tracking-2 text-[var(--color-fg-secondary)]">${item.label}</div>
                          <div class="mt-1 text-sm font-bold text-[var(--color-fg-primary)]">${item.value}</div>
                        </div>
                      `)}
                    </div>
                  `
                : null}
              ${entry.details.rawPayload
                ? html`
                    <div class="flex flex-col gap-2">
                      <button
                        type="button"
                        class="self-start rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-1 text-xs font-medium text-[var(--color-fg-secondary)] transition-colors hover:bg-[var(--color-bg-hover)] hover:text-[var(--color-fg-primary)] ${CHAT_FOCUS_RING}"
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
})

function ChatMessageSurface({
  entry,
  showMetadata = true,
  variant = 'default',
  showSourceBadge = false,
  contextScope = null,
  action,
}: {
  entry: KeeperConversationEntry
  showMetadata?: boolean
  variant?: ChatTranscriptVariant
  showSourceBadge?: boolean
  contextScope?: ChatContextScope | null
  action?: ChatTranscriptAction
}) {
  return chatControlStatus(entry)
    ? html`<${ChatControlStatusCard} entry=${entry} action=${action} />`
    : html`
        <${ChatMessageBubble}
          entry=${entry}
          showMetadata=${showMetadata}
          variant=${variant}
          showSourceBadge=${showSourceBadge}
          contextScope=${contextScope}
          action=${action}
        />
      `
}

// Pretty-print a JSON-looking string; leave anything else untouched. Shared by
// the argument and output renderers so both read consistently.
function prettyJsonish(text: string): string {
  const trimmed = text.trimStart()
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
    const pretty = prettyJson(text)
    if (pretty !== null) return pretty
    // not valid JSON — show as-is
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
  const toolCallId = entry.toolCallId?.trim() ? entry.toolCallId : null
  const displayArgs = prettyJsonish(entry.text || '')
  const isEmptyArgs = EMPTY_ARG_TEXTS.has(displayArgs.trim())
  // Same reason as the trace-step row: the name repeats, the subject does not.
  const subject = isEmptyArgs ? null : toolSubject(displayArgs)

  // Tool results never travel on the chat stream — they are joined here from
  // the tool-call output store by canonical execution_id. Null until result
  // readiness and output hydration have both landed.
  const outputEntry = lookupToolCallOutput(entry.executionId)
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
      data-chat-entry-id=${entry.id}
      data-chat-role=${entry.role}
      data-chat-source=${entry.source}
      data-chat-delivery-state=${entry.delivery}
      data-chat-stream-state=${entry.streamState ?? 'complete'}
      data-chat-stream-contract-source=${entry.streamContract?.source ?? 'unspecified'}
      data-chat-stream-contract-status=${entry.streamContract?.status ?? 'unspecified'}
      data-chat-stream-contract-event=${entry.streamContract?.eventName ?? undefined}
      data-chat-stream-contract-request-id=${entry.streamContract?.requestId ?? undefined}
      data-chat-stream-contract-turn-ref=${entry.streamContract?.turnRef ?? undefined}
      data-chat-stream-contract-trace-events=${entry.streamContract?.traceEventCount ?? undefined}
      data-chat-stream-contract-lifecycle-events=${entry.streamContract?.lifecycleEvents?.join(',') ?? undefined}
      data-chat-stream-contract-reason=${entry.streamContract?.reason ?? undefined}
      data-chat-turn-ref=${entry.turnRef ?? undefined}
      data-chat-tool-call-id=${toolCallId ?? undefined}
      data-chat-tool-execution-id=${entry.executionId ?? undefined}
    >
      <button
        type="button"
        class="flex w-full items-center gap-2 px-3 py-2 text-left hover:bg-[var(--color-bg-hover)] transition-colors ${CHAT_FOCUS_RING}"
        onClick=${() => { setExpanded(!expanded) }}
        aria-expanded=${expanded}
      >
        <span class="inline-flex size-5 shrink-0 items-center justify-center rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-panel-alt)] text-2xs font-mono font-bold text-[var(--color-fg-secondary)]">T</span>
        <span class="font-mono text-sm font-semibold text-[var(--color-accent-fg)] truncate">${toolName}</span>
        ${subject
          ? html`<span class="chat-block-tstep-subject" title=${subject}>${subject}</span>`
          : null}
        <span class="rounded-[var(--r-0)] border border-[var(--color-border-default)] px-1.5 py-0.5 text-2xs font-semibold text-[var(--color-fg-secondary)]">입력</span>
        ${outputEntry
          ? html`<span
              class=${`text-xs font-semibold ${outputEntry.success ? 'text-[var(--color-ok-fg)]' : 'text-[var(--color-status-err)]'}`}
              title=${outputEntry.success ? 'tool succeeded' : 'tool failed'}
              aria-label=${outputEntry.success ? 'tool succeeded' : 'tool failed'}
            >${outputEntry.success ? '✓' : '✗'}</span>`
          : null}
        ${timestamp
          ? html`<span class="ml-auto text-xs font-medium tabular-nums text-[var(--color-fg-secondary)]">${timestamp}</span>`
          : null}
        <span class="ml-1 text-sm text-[var(--color-fg-secondary)]">${expanded ? '▾' : '▸'}</span>
      </button>
      ${expanded
        ? html`
            <div class="flex flex-col gap-2 border-t border-[var(--color-border-default)] px-3 py-2">
              ${isEmptyArgs
                ? html`<div class="text-xs font-mono text-[var(--color-fg-secondary)]">입력 없음 (매개변수가 없는 도구)</div>`
                : html`
                    <div>
                      <div class="mb-1 text-2xs font-bold uppercase tracking-4 text-[var(--color-fg-secondary)]">arguments</div>
                      <pre class="text-xs font-mono whitespace-pre-wrap break-all text-[var(--color-fg-primary)] max-h-48 overflow-y-auto">${displayArgs}</pre>
                    </div>
                  `}
              ${hasOutput
                ? html`
                    <div>
                      <div class="mb-1 flex items-center gap-1 text-2xs font-bold uppercase tracking-4 text-[var(--color-fg-secondary)]">
                        <span>output</span>
                        ${outputView.truncated
                          ? html`<span class="font-normal normal-case text-[var(--color-fg-secondary)]">· truncated, see tool inspector</span>`
                          : null}
                      </div>
                      <pre class="text-xs font-mono whitespace-pre-wrap break-all text-[var(--color-fg-primary)] max-h-64 overflow-y-auto">${outputView.text}</pre>
                    </div>
                  `
                : null}
              ${!hasOutput
                ? isEmptyArgs
                  ? html`<div class="text-xs text-[var(--color-fg-secondary)]">출력 대기 중…</div>`
                  : html`<div class="text-2xs text-[var(--color-fg-secondary)]">출력(결과)은 도구 실행 추적 패널에서 확인</div>`
                : null}
            </div>
          `
        : html`
            <div class="px-3 pb-2">
              <div class="truncate text-xs font-mono text-[var(--color-fg-secondary)]">${preview}</div>
            </div>
          `
      }
    </article>
  `
}

type ToolTraceDisplayStatus = 'pending' | 'missing' | 'coverage-gap' | 'hydration-failed' | 'unlinked' | 'ok' | 'bad'
type ToolOutputCoverageState = 'not-hydrated' | 'hydrating' | 'hydration-failed' | 'covered' | 'coverage-gap' | 'not-applicable'

const TOOL_STATUS_TITLE: Record<ToolTraceDisplayStatus, string> = {
  pending: TOOL_STATUS_TITLE_PENDING,
  missing: '결과 누락 — 턴이 끝났는데 출력이 도착하지 않음',
  'coverage-gap': '출력 tail 범위 밖 — 결과 누락 여부를 확정할 수 없음',
  'hydration-failed': '출력 hydration 실패 — 결과 누락 여부를 확정할 수 없음',
  unlinked: '실행 ID 없음 — 출력 조인 불가',
  ok: TOOL_STATUS_TITLE_OK,
  bad: TOOL_STATUS_TITLE_BAD,
}

// A tool call's output is legitimately "pending" while its turn is still
// streaming, or before the separate tool-output hydration surface has loaded.
// Once both have settled, an output that never joined is a gap (e.g. a call
// whose canonical execution_id was absent and never joined), not indefinite
// "pending".
function isTurnStreaming(state: KeeperConversationEntry['streamState']): boolean {
  return state === 'opening' || state === 'thinking' || state === 'streaming' || state === 'finalizing'
}

function toolOutputCoverageState(
  entry: KeeperConversationEntry,
  coveredSinceMs: number | null | undefined,
  coveredThroughMs: number | null | undefined,
  hydrationStatus: ToolCallOutputHydrationContract['status'] | null | undefined,
): ToolOutputCoverageState {
  if (hydrationStatus === 'failed') return 'hydration-failed'
  if (coveredThroughMs == null) return hydrationStatus === 'hydrating' ? 'hydrating' : 'not-hydrated'
  const timestampMs = entry.timestamp ? Date.parse(entry.timestamp) : NaN
  if (!Number.isFinite(timestampMs)) return 'coverage-gap'
  if (coveredSinceMs != null && timestampMs < coveredSinceMs) return 'coverage-gap'
  if (timestampMs > coveredThroughMs) return 'coverage-gap'
  return 'covered'
}

function toolTraceCallId(entry: KeeperConversationEntry | null, traceStep?: ChatTraceToolStep): string | null {
  const traceCallId = traceStep?.toolCallId?.trim()
  if (traceCallId) return traceStep?.toolCallId ?? null
  return entry?.toolCallId?.trim() ? entry.toolCallId : null
}

function toolTraceSourceBadge(entry: KeeperConversationEntry | null, traceStep?: ChatTraceToolStep): TraceSourceBadgeInfo {
  if (traceStep) return traceSourceBadge(traceStep)
  const callId = entry?.toolCallId?.trim() ? entry.toolCallId : null
  if (callId) {
    return {
      label: 'tool_call_id',
      title: `source: tool transcript row, tool_call_id=${callId}`,
      tone: 'tool',
    }
  }
  if (entry?.executionId?.trim()) {
    return {
      label: 'execution_id',
      title: `source: tool transcript row, execution_id=${entry.executionId}`,
      tone: 'tool',
    }
  }
  return {
    label: 'delivery_row',
    title: 'source: delivery-only tool transcript row',
    tone: 'warn',
  }
}

function isUnlinkedTraceTool(entry: KeeperConversationEntry | null, traceStep?: ChatTraceToolStep): boolean {
  return traceStep !== undefined
    && entry === null
    && !traceStep.executionId?.trim()
}

function ToolTraceStep({
  entry,
  output,
  canMarkMissing = false,
  coverageState = 'not-applicable',
  hydrationFailureReason = null,
  traceStep,
  orderIndex,
  orderKind = 'tool',
  structuralSummary = false,
}: {
  entry: KeeperConversationEntry | null
  output: ToolCallEntry | null
  canMarkMissing?: boolean
  coverageState?: ToolOutputCoverageState
  hydrationFailureReason?: string | null
  traceStep?: ChatTraceToolStep
  orderIndex?: number
  orderKind?: 'tool' | 'tool-entry'
  structuralSummary?: boolean
}) {
  const [open, setOpen] = useState(false)
  const name = traceStep?.name || entry?.label || 'tool'
  const callId = toolTraceCallId(entry, traceStep)
  const displayArgs = prettyJsonish(entry?.text || traceStep?.args || '')
  const isEmptyArgs = EMPTY_ARG_TEXTS.has(displayArgs.trim())
  // Same reason as the trace-step row: the name repeats, the subject does not.
  const subject = isEmptyArgs ? null : toolSubject(displayArgs)
  const unlinkedTraceTool = !structuralSummary && isUnlinkedTraceTool(entry, traceStep)
  const sourceBadge = structuralSummary
    ? { label: 'activity', title: 'source: autonomous activity summary', tone: 'tool' as const }
    : toolTraceSourceBadge(entry, traceStep)
  let status: ToolTraceDisplayStatus
  if (output !== null) {
    status = output.success === false ? 'bad' : 'ok'
  } else if (traceStep?.status === 'err') {
    status = 'bad'
  } else if (traceStep?.status === 'ok') {
    status = 'ok'
  } else if (unlinkedTraceTool) {
    status = 'unlinked'
  } else if (coverageState === 'hydration-failed') {
    status = 'hydration-failed'
  } else if (coverageState === 'coverage-gap') {
    status = 'coverage-gap'
  } else {
    status = canMarkMissing ? 'missing' : 'pending'
  }
  const durLabel =
    output?.duration_ms != null && output.duration_ms > 0
      ? formatMsCompact(output.duration_ms)
      : traceStep?.dur ?? ''
  const resultView = output ? toolOutputDisplay(output.output) : (traceStep?.result ? { text: traceStep.result, truncated: false } : null)
  const hasResult = resultView !== null && resultView.text.trim() !== ''
  // Expandable when there is anything to show: args, a result, or a still-pending
  // call (so the operator can open it and see "출력 대기 중…").
  const hasBody = !structuralSummary && (unlinkedTraceTool || !isEmptyArgs || hasResult || output === null)

  return html`
    <div
      class="chat-block-tstep tool ${open ? 'exp' : ''}"
      data-chat-trace-step="tool"
      data-chat-turn-order-index=${orderIndex ?? undefined}
      data-chat-turn-order-kind=${orderKind}
      data-chat-trace-provenance=${sourceBadge.label}
      data-chat-trace-tool-call-id=${callId ?? undefined}
      data-chat-trace-execution-id=${entry?.executionId ?? traceStep?.executionId ?? undefined}
      data-chat-trace-agent-core-block-index=${traceStep?.agentCoreBlockIndex ?? undefined}
      data-chat-trace-entry-id=${entry?.id ?? undefined}
      data-chat-trace-link-state=${structuralSummary ? 'structural' : unlinkedTraceTool ? 'unlinked' : entry ? 'joined' : 'trace-only'}
      data-chat-trace-output-state=${status}
      data-chat-trace-output-coverage=${coverageState}
    >
      <span class="chat-block-tnode"></span>
      <div class="min-w-0 flex-1">
        <div
          class="chat-block-tstep-row ${hasBody ? 'click' : ''}"
          onClick=${() => { if (hasBody) setOpen((o) => !o) }}
        >
          <span class="chat-block-tstep-kind">Tool</span>
          <${TraceSourceBadge} info=${sourceBadge} />
          <span class="chat-block-tstep-name">${name}</span>
          ${subject
            ? html`<span class="chat-block-tstep-subject" title=${subject}>${subject}</span>`
            : null}
          <span
            class="chat-block-tstep-status ${status}"
            title=${TOOL_STATUS_TITLE[status]}
            aria-label=${TOOL_STATUS_TITLE[status]}
          ></span>
          <span class="chat-block-tstep-dur">${durLabel}</span>
          ${hasBody ? html`<span class="chat-block-tstep-chev">▶</span>` : null}
        </div>
        ${open && hasBody
          ? html`
            <div class="chat-block-tool-body">
                ${unlinkedTraceTool
                  ? html`<div class="chat-block-tool-label">실행 ID 없음 — 출력 조인 불가</div>`
                  : isEmptyArgs
                  ? html`<div class="chat-block-tool-label">입력 없음</div>`
                  : html`
                      <div class="chat-block-tool-label">args</div>
                      <pre class="m-0 max-h-48 overflow-y-auto whitespace-pre-wrap break-all text-2xs">${displayArgs}</pre>
                    `}
                ${hasResult
                  ? html`
                      <div class="chat-block-tool-label">result${resultView.truncated ? ' · 일부' : ''}</div>
                      <pre class="m-0 max-h-64 overflow-y-auto whitespace-pre-wrap break-all text-2xs">${resultView.text}</pre>
                    `
                  : output === null
                    ? unlinkedTraceTool
                      ? null
                      : html`<div class="chat-block-tool-label">${
                          coverageState === 'hydration-failed'
                            ? `출력 hydration 실패${hydrationFailureReason ? ` — ${hydrationFailureReason}` : ''}`
                            : coverageState === 'coverage-gap'
                            ? '출력 tail 범위 밖 — 이 도구 시점을 덮는 결과 hydration이 아직 없음'
                            : canMarkMissing
                              ? '결과 없음 — 출력이 도착하지 않음'
                              : '출력 대기 중…'
                        }</div>`
                    : null}
              </div>
            `
          : null}
      </div>
    </div>
  `
}

type TraceOrderItem =
  | { kind: 'trace'; step: Exclude<ChatTraceStep, ChatTraceToolStep> }
  | { kind: 'tool'; step: ChatTraceToolStep; entry: KeeperConversationEntry | null; output: ToolCallEntry | null }
  | { kind: 'tool-entry'; entry: KeeperConversationEntry; output: ToolCallEntry | null }
  | { kind: 'chat'; entry: KeeperConversationEntry }

function isToolOrderItem(item: TraceOrderItem): item is Extract<TraceOrderItem, { kind: 'tool' | 'tool-entry' }> {
  return item.kind === 'tool' || item.kind === 'tool-entry'
}

function traceStepDurationMs(dur: string | undefined): number {
  const trimmed = dur?.trim()
  if (!trimmed) return 0
  const match = /^(\d+(?:\.\d+)?)\s*(ms|s|m)?$/i.exec(trimmed)
  if (!match) return 0
  const value = Number(match[1])
  if (!Number.isFinite(value)) return 0
  const unit = match[2]?.toLowerCase() ?? 'ms'
  if (unit === 'm') return value * 60_000
  if (unit === 's') return value * 1_000
  return value
}

// Groups a turn's explicit progress/tool entries into one "작업 과정" trace
// card placed above the answer bubble. Live streams append tool calls directly
// into traceSteps, so this function renders that structural sequence verbatim.
// Legacy history that has only think/reason steps still falls back to the old
// honest shape: trace rows first, then sibling tool entries. It deliberately
// does not sort by timestamps because thinking deltas and tool rows come from
// different clocks and cannot prove causal order after the fact.
export function interleaveTraceAndTools(
  traceSteps: ChatTraceStep[],
  toolSteps: { entry: KeeperConversationEntry; output: ToolCallEntry | null }[],
): TraceOrderItem[] {
  const toolsByIdentity = new Map<string, { entry: KeeperConversationEntry; output: ToolCallEntry | null }>()
  for (const item of toolSteps) {
    toolsByIdentity.set(`occurrence:${item.entry.id}`, item)
    if (item.entry.executionId?.trim()) {
      toolsByIdentity.set(`execution:${item.entry.executionId}`, item)
    }
  }
  const usedEntryIds = new Set<string>()
  const ordered: TraceOrderItem[] = []
  for (const step of traceSteps) {
    if (step.kind !== 'tool') {
      ordered.push({ kind: 'trace', step })
      continue
    }
    const joinKey = step.toolOccurrenceId?.trim()
      ? `occurrence:${step.toolOccurrenceId}`
      : step.executionId?.trim()
        ? `execution:${step.executionId}`
        : null
    const matched = joinKey ? toolsByIdentity.get(joinKey) : undefined
    if (matched) usedEntryIds.add(matched.entry.id)
    ordered.push({
      kind: 'tool',
      step,
      entry: matched?.entry ?? null,
      output: matched?.output ?? lookupToolCallOutput(step.executionId),
    })
  }
  for (const item of toolSteps) {
    if (usedEntryIds.has(item.entry.id)) continue
    ordered.push({ kind: 'tool-entry', entry: item.entry, output: item.output })
  }
  return ordered
}

function chatResponsePreview(entry: KeeperConversationEntry): string {
  const liveLabel = liveMessageLabel(entry)
  if (liveLabel) return liveLabel
  const text = entry.text.trim().replace(/\s+/g, ' ')
  if (!text) return '응답 본문 없음'
  return text.length > 96 ? `${text.slice(0, 96)}…` : text
}

function ChatResponseTraceStep({
  entry,
  orderIndex,
}: {
  entry: KeeperConversationEntry
  orderIndex?: number
}) {
  const sourceBadge: TraceSourceBadgeInfo = {
    label: 'reply',
    title: 'source: assistant reply entry',
    tone: 'reply',
  }
  return html`
    <div
      class="chat-block-tstep chat"
      data-chat-trace-step="chat"
      data-chat-turn-order-index=${orderIndex ?? undefined}
      data-chat-turn-order-kind="chat"
      data-chat-trace-provenance=${sourceBadge.label}
      data-chat-trace-entry-id=${entry.id}
      data-chat-trace-source=${entry.source}
      data-chat-trace-turn-ref=${entry.turnRef ?? undefined}
      data-chat-trace-stream-contract-source=${entry.streamContract?.source ?? 'unspecified'}
      data-chat-trace-stream-contract-status=${entry.streamContract?.status ?? 'unspecified'}
      data-chat-trace-stream-contract-event=${entry.streamContract?.eventName ?? undefined}
      data-chat-trace-stream-contract-turn-ref=${entry.streamContract?.turnRef ?? undefined}
      data-chat-trace-stream-contract-trace-events=${entry.streamContract?.traceEventCount ?? undefined}
      data-chat-trace-stream-contract-lifecycle-events=${entry.streamContract?.lifecycleEvents?.join(',') ?? undefined}
    >
      <span class="chat-block-tnode"></span>
      <div class="min-w-0 flex-1">
        <div class="chat-block-tstep-row">
          <span class="chat-block-tstep-kind">Chat</span>
          <${TraceSourceBadge} info=${sourceBadge} />
          <span class="chat-block-tstep-name">응답</span>
          <span class="chat-block-tstep-text">${chatResponsePreview(entry)}</span>
        </div>
      </div>
    </div>
  `
}

/** Addressable identity for one turn's timeline block. The assistant row owns
 *  a turn bundle; a tool-only group is addressed by its first tool row. Both
 *  ids come from the conversation store, so they survive the transcript
 *  unmount that a keeper switch causes. */
function traceCardIdentity(
  assistant: KeeperConversationEntry | null,
  tools: readonly KeeperConversationEntry[],
): string | null {
  if (assistant) return `turn:${assistant.id}`
  const first = tools[0]
  return first ? `tools:${first.id}` : null
}

/** Turn timelines the operator explicitly opened or collapsed. Only explicit
 *  toggles are recorded, so the map is bounded by operator actions rather
 *  than by transcript size. */
const traceCardOpenChoices = new Map<string, boolean>()

function traceCardOpenOverride(cardKey: string): boolean | undefined {
  return traceCardOpenChoices.get(cardKey)
}

function setTraceCardOpenOverride(cardKey: string, open: boolean): void {
  traceCardOpenChoices.set(cardKey, open)
}

/** Test-only: drop recorded collapse choices between cases. */
export function _resetTraceCardOpenChoicesForTests(): void {
  traceCardOpenChoices.clear()
}

function ToolTraceCard({
  tools,
  traceSteps = [],
  assistant = null,
  turnComplete = false,
  toolOutputsCoveredSinceMs = null,
  toolOutputsCoveredThroughMs = null,
  toolOutputHydrationContract = null,
}: {
  tools: KeeperConversationEntry[]
  traceSteps?: ChatTraceStep[]
  assistant?: KeeperConversationEntry | null
  turnComplete?: boolean
  toolOutputsCoveredSinceMs?: number | null
  toolOutputsCoveredThroughMs?: number | null
  toolOutputHydrationContract?: ToolCallOutputHydrationContract | null
}) {
  const liveTurn = assistant !== null && !turnComplete
  const structuralSummary = assistant?.source === 'autonomous_turn'
  // Collapse state is derived, not stored-and-resynced: the operator's
  // explicit choice for this turn if there is one, otherwise "open once the
  // turn is no longer live". The choice lives outside the component because
  // switching keepers unmounts the whole transcript — with the state held in
  // `useState` + a `useRef` "did the user toggle" flag, both reset on remount
  // and every collapsed timeline sprang back open.
  const cardKey = traceCardIdentity(assistant, tools)
  const [localOpen, setLocalOpen] = useState<boolean | null>(null)
  const open =
    (cardKey !== null ? traceCardOpenOverride(cardKey) : localOpen) ?? !liveTurn
  const toggleOpen = () => {
    const next = !open
    if (cardKey !== null) setTraceCardOpenOverride(cardKey, next)
    // Also drives the re-render; carries the state outright for a card with
    // no addressable turn identity.
    setLocalOpen(next)
  }
  const steps = tools.map((entry) => ({
    entry,
    output: lookupToolCallOutput(entry.executionId),
  }))
  const coverageStateForEntry = (entry: KeeperConversationEntry): ToolOutputCoverageState =>
    toolOutputCoverageState(
      entry,
      toolOutputsCoveredSinceMs,
      toolOutputsCoveredThroughMs,
      toolOutputHydrationContract?.status ?? null,
    )
  const canMarkMissingForEntry = (entry: KeeperConversationEntry): boolean =>
    turnComplete && coverageStateForEntry(entry) === 'covered'
  const hasChatResponse = assistant !== null
    && assistant.delivery !== 'no_reply'
    && assistant.text.trim().length > 0
  const ordered = hasChatResponse && assistant
    ? [...interleaveTraceAndTools(traceSteps, steps), { kind: 'chat' as const, entry: assistant }]
    : interleaveTraceAndTools(traceSteps, steps)
  const orderSignature = ordered.map((item) => {
    if (item.kind === 'trace') return `trace:${item.step.kind}`
    if (item.kind === 'tool') return `tool:${toolTraceCallId(item.entry, item.step) ?? item.step.name}`
    if (item.kind === 'tool-entry') return `tool-entry:${toolTraceCallId(item.entry) ?? item.entry.id}`
    return `chat:${item.entry.id}`
  }).join('|')
  const orderedToolSteps = ordered.filter(isToolOrderItem)
  const thinkN = traceSteps.filter((step) => step.kind === 'think' || step.kind === 'reason').length
  const progressN = traceSteps.filter((step) => step.kind === 'progress').length
  const failN = orderedToolSteps.filter(
    (s) =>
      (s.output !== null && s.output.success === false)
      || (s.kind === 'tool' && s.step.status === 'err'),
  ).length
  // Surface unjoined outputs as "missing" only once the turn and output
  // hydration have both settled.
  const missingN = orderedToolSteps.filter(
    (s) => s.output === null && s.entry !== null && canMarkMissingForEntry(s.entry),
  ).length
  const coverageGapN = orderedToolSteps.filter(
    (s) => s.output === null && s.entry !== null && turnComplete && coverageStateForEntry(s.entry) === 'coverage-gap',
  ).length
  const hydrationFailedN = orderedToolSteps.filter(
    (s) => s.output === null && s.entry !== null && turnComplete && coverageStateForEntry(s.entry) === 'hydration-failed',
  ).length
  const unlinkedN = orderedToolSteps.filter(
    (s) => !structuralSummary && s.kind === 'tool' && s.entry === null && !s.step.executionId?.trim(),
  ).length
  const totalMs = orderedToolSteps.reduce(
    (sum, s) => sum + (s.output?.duration_ms ?? (s.kind === 'tool' ? traceStepDurationMs(s.step.dur) : 0)),
    0,
  )
  const durLabel = totalMs > 0 ? formatMsCompact(totalMs) : null
  const chatN = hasChatResponse ? 1 : 0
  const stepN = ordered.length

  return html`
    <div
      class="chat-block-trace ${open ? 'open' : ''}"
      data-chat-block="trace"
      data-chat-work-trace
      data-chat-tool-trace
      data-chat-turn-stream-state=${assistant ? (assistant.streamState ?? 'complete') : undefined}
      data-chat-turn-complete=${turnComplete ? 'true' : 'false'}
      data-chat-turn-stream-contract-source=${assistant?.streamContract?.source ?? undefined}
      data-chat-turn-stream-contract-status=${assistant?.streamContract?.status ?? undefined}
      data-chat-turn-stream-contract-event=${assistant?.streamContract?.eventName ?? undefined}
      data-chat-turn-stream-contract-request-id=${assistant?.streamContract?.requestId ?? undefined}
      data-chat-turn-stream-contract-turn-ref=${assistant?.streamContract?.turnRef ?? undefined}
      data-chat-turn-stream-contract-trace-events=${assistant?.streamContract?.traceEventCount ?? undefined}
      data-chat-turn-stream-contract-lifecycle-events=${assistant?.streamContract?.lifecycleEvents?.join(',') ?? undefined}
      data-chat-tool-output-hydration-source=${toolOutputHydrationContract?.source ?? undefined}
      data-chat-tool-output-hydration-status=${toolOutputHydrationContract?.status ?? 'not-requested'}
      data-chat-tool-output-hydration-failure=${toolOutputHydrationContract?.failureReason ?? undefined}
      data-chat-tool-output-covered-since=${toolOutputsCoveredSinceMs ?? undefined}
      data-chat-tool-output-covered-through=${toolOutputsCoveredThroughMs ?? undefined}
      data-chat-turn-order-signature=${orderSignature || undefined}
    >
      <button
        type="button"
        class="chat-block-trace-hd"
        onClick=${toggleOpen}
        aria-expanded=${open}
      >
        <span class="chat-block-trace-chev">${open ? '▾' : '▸'}</span>
        <span>◈</span>
        <span class="chat-block-trace-label">턴 타임라인</span>
        <span class="chat-block-trace-count">${stepN}단계</span>
        <span class="chat-block-trace-meta">
          ${thinkN > 0 ? html`<span>Think ${thinkN}</span>` : null}
          ${progressN > 0 ? html`<span>Progress ${progressN}</span>` : null}
          ${orderedToolSteps.length > 0 ? html`<span>도구 ${orderedToolSteps.length}</span>` : null}
          ${chatN > 0 ? html`<span>Chat ${chatN}</span>` : null}
          ${failN > 0 ? html`<span class="text-[var(--color-status-err)]">실패 ${failN}</span>` : null}
          ${missingN > 0 ? html`<span class="text-[var(--color-status-warn)]">결과 누락 ${missingN}</span>` : null}
          ${coverageGapN > 0 ? html`<span class="text-[var(--color-status-warn)]">출력 범위 밖 ${coverageGapN}</span>` : null}
          ${hydrationFailedN > 0 ? html`<span class="text-[var(--color-status-warn)]">출력 hydration 실패 ${hydrationFailedN}</span>` : null}
          ${unlinkedN > 0 ? html`<span class="text-[var(--color-status-warn)]">조인 불가 ${unlinkedN}</span>` : null}
          ${durLabel ? html`<span class="tnum">${durLabel}</span>` : null}
        </span>
      </button>
      ${open
        ? html`
            <div class="chat-block-trace-steps">
              <span class="chat-block-trace-rail"></span>
              ${ordered.map((item, index) =>
                item.kind === 'trace'
                  ? html`<${ChatTraceStep}
                      key=${`trace-${index}`}
                      step=${item.step}
                      orderIndex=${index}
                      streaming=${assistant !== null && !turnComplete}
                    />`
                  : item.kind === 'tool'
                    ? (() => {
                        return html`<${ToolTraceStep}
                          key=${`tool-trace-${item.entry?.id ?? item.step.toolCallId ?? item.step.name}-${index}`}
                          entry=${item.entry}
                          output=${item.output}
                          canMarkMissing=${item.entry !== null && canMarkMissingForEntry(item.entry)}
                          coverageState=${item.entry !== null ? coverageStateForEntry(item.entry) : 'not-applicable'}
                          hydrationFailureReason=${toolOutputHydrationContract?.failureReason ?? null}
                          traceStep=${item.step}
                          orderIndex=${index}
                          structuralSummary=${structuralSummary}
                          orderKind="tool"
                        />`
                      })()
                    : item.kind === 'tool-entry'
                      ? html`<${ToolTraceStep}
                          key=${`tool-entry-${item.entry.id}`}
                          entry=${item.entry}
                          output=${item.output}
                          canMarkMissing=${canMarkMissingForEntry(item.entry)}
                          coverageState=${coverageStateForEntry(item.entry)}
                          hydrationFailureReason=${toolOutputHydrationContract?.failureReason ?? null}
                          orderIndex=${index}
                          orderKind="tool-entry"
                        />`
                    : html`<${ChatResponseTraceStep} key=${`chat-${item.entry.id}`} entry=${item.entry} orderIndex=${index} />`)}
            </div>
          `
        : null}
    </div>
  `
}

function sameEntryRefs(
  left: readonly KeeperConversationEntry[],
  right: readonly KeeperConversationEntry[],
): boolean {
  return left.length === right.length && left.every((entry, index) => entry === right[index])
}

const TurnWorkBundle = memo(function TurnWorkBundle({
  tools,
  assistant,
  showMetadata,
  variant,
  showSourceBadge,
  toolOutputsCoveredSinceMs,
  toolOutputsCoveredThroughMs,
  toolOutputHydrationContract,
  contextScope = null,
  action,
}: {
  tools: KeeperConversationEntry[]
  assistant: KeeperConversationEntry
  showMetadata?: boolean
  variant: ChatTranscriptVariant
  showSourceBadge: boolean
  toolOutputsCoveredSinceMs: number | null
  toolOutputsCoveredThroughMs: number | null
  toolOutputHydrationContract: ToolCallOutputHydrationContract | null
  contextScope?: ChatContextScope | null
  action?: ChatTranscriptAction
}) {
  const traceSteps = assistant.traceSteps ?? []
  // The bundle owns the assistant entry, but output hydration is a separate
  // async surface. Only mark gaps after that surface has successfully loaded.
  const turnComplete = !isTurnStreaming(assistant.streamState)
  return html`
    <div class="chat-turn-bundle" data-chat-turn-bundle>
      <${ToolTraceCard}
        tools=${tools}
        traceSteps=${traceSteps}
        assistant=${assistant}
        turnComplete=${turnComplete}
        toolOutputsCoveredSinceMs=${toolOutputsCoveredSinceMs}
        toolOutputsCoveredThroughMs=${toolOutputsCoveredThroughMs}
        toolOutputHydrationContract=${toolOutputHydrationContract}
      />
      <${ChatMessageSurface}
        entry=${assistant}
        showMetadata=${showMetadata !== false}
        variant=${variant}
        showSourceBadge=${showSourceBadge}
        contextScope=${contextScope}
        action=${action}
      />
    </div>
  `
}, (prev, next) =>
  prev.assistant === next.assistant
  && sameEntryRefs(prev.tools, next.tools)
  && prev.showMetadata === next.showMetadata
  && prev.variant === next.variant
  && prev.showSourceBadge === next.showSourceBadge
  && prev.toolOutputsCoveredSinceMs === next.toolOutputsCoveredSinceMs
  && prev.toolOutputsCoveredThroughMs === next.toolOutputsCoveredThroughMs
  && prev.toolOutputHydrationContract === next.toolOutputHydrationContract
  && prev.contextScope === next.contextScope
  && prev.action === next.action
)

// A reader within this distance of the bottom is considered "pinned":
// new content keeps auto-scrolling. Scrolling further up unpins so the
// transcript stops yanking the viewport while old messages are read.
const STICK_TO_BOTTOM_THRESHOLD_PX = 80

const AUTONOMOUS_SUMMARY_MAX_GROUPS = 4
// A run can hold hundreds of turns; the header is a glance, not an audit. The
// scan stops here and says so with a trailing ellipsis rather than paying for
// the whole run on every render.
const AUTONOMOUS_SUMMARY_SCAN_LIMIT = 2000

/** Which tools a collapsed run of autonomous turns ran, in the order it ran
 *  them, consecutive repeats folded into a count. A header reading only
 *  "자율턴 145개" says how many times the keeper woke, not what any wake did,
 *  so the run stays closed and the reader still cannot tell a fetch from a
 *  rewrite. Returns null for a run that called no tools. */
export function autonomousToolSummary(entries: KeeperConversationEntry[]): string | null {
  const groups: { name: string; count: number }[] = []
  let scanned = 0
  let truncated = false
  for (const entry of entries) {
    for (const step of entry.traceSteps ?? []) {
      if (step.kind !== 'tool') continue
      if (scanned >= AUTONOMOUS_SUMMARY_SCAN_LIMIT) {
        truncated = true
        break
      }
      scanned++
      const name = normalizeToolName(step.name)
      const last = groups[groups.length - 1]
      if (last && last.name === name) last.count++
      else groups.push({ name, count: 1 })
    }
    if (truncated) break
  }
  if (groups.length === 0) return null
  const shown = groups.slice(0, AUTONOMOUS_SUMMARY_MAX_GROUPS)
  const text = shown.map((g) => (g.count > 1 ? `${g.name}×${g.count}` : g.name)).join(' ')
  const rest = groups.length - shown.length
  const more = rest > 0 ? ` +${rest}` : ''
  return truncated ? `${text}${more}…` : `${text}${more}`
}

/** One autonomous turn, collapsed into a single row. Starts closed: the turn is
 *  the keeper working on its own, and the transcript's subject is the
 *  conversation around it. Expanding renders the exact turn's final text and
 *  typed work trace through the same surfaces a direct turn uses. */
function AutonomousTurnGroup({
  entry,
  showMetadata,
  variant,
  showSourceBadge,
  toolOutputsCoveredSinceMs,
  toolOutputsCoveredThroughMs,
  toolOutputHydrationContract,
  action,
}: {
  entry: KeeperConversationEntry
  showMetadata?: boolean
  variant: ChatTranscriptVariant
  showSourceBadge: boolean
  toolOutputsCoveredSinceMs: number | null
  toolOutputsCoveredThroughMs: number | null
  toolOutputHydrationContract: ToolCallOutputHydrationContract | null
  action?: ChatTranscriptAction
}) {
  const [open, setOpen] = useState(false)
  const timestamp = timeLabel(entry.timestamp)
  const toolSummary = useMemo(() => autonomousToolSummary([entry]), [entry])
  return html`
    <div class="chat-block-trace ${open ? 'open' : ''}">
      <button
        type="button"
        class="chat-block-trace-hd"
        onClick=${() => setOpen((o) => !o)}
        aria-expanded=${open}
      >
        <span class="chat-block-trace-chev">${open ? '▾' : '▸'}</span>
        <span class="chat-block-trace-label">자율턴</span>
        <span class="chat-block-trace-count">1개</span>
        ${toolSummary
          ? html`<span class="chat-block-trace-tools" title=${toolSummary}>${toolSummary}</span>`
          : null}
        ${timestamp ? html`<span class="chat-block-trace-meta">${timestamp}</span>` : null}
      </button>
      ${open
        ? (entry.traceSteps?.length ?? 0) > 0
          ? html`<${TurnWorkBundle}
              key=${entry.id}
              tools=${[]}
              assistant=${entry}
              showMetadata=${showMetadata}
              variant=${variant}
              showSourceBadge=${showSourceBadge}
              toolOutputsCoveredSinceMs=${toolOutputsCoveredSinceMs}
              toolOutputsCoveredThroughMs=${toolOutputsCoveredThroughMs}
              toolOutputHydrationContract=${toolOutputHydrationContract}
              action=${action}
            />`
          : html`<${ChatMessageSurface}
              key=${entry.id}
              entry=${entry}
              showMetadata=${showMetadata !== false}
              variant=${variant}
              showSourceBadge=${showSourceBadge}
              action=${action}
            />`
        : null}
    </div>
  `
}

// How many turns an opened run draws at each end before the middle becomes a
// control. A run has no ceiling -- a keeper wakes on the order of once every
// few minutes, so an unattended weekend is hundreds of turns -- and drawing it
// whole trades the wall of headers the fold removed for a wall of rows. The
// two ends are the parts a reader asks for: where the run started and what the
// keeper just did.
const AUTONOMOUS_RUN_WINDOW_HEAD = 3
const AUTONOMOUS_RUN_WINDOW_TAIL = 3
// Turns revealed per press of the middle control. Small enough that one press
// cannot restore the wall, large enough that walking a long run is not dozens
// of presses.
const AUTONOMOUS_RUN_WINDOW_STEP = 10

/** Which slice of an opened run to draw, given how far the reader has already
 *  walked the head down. [hidden] is the count the middle control stands for;
 *  zero means every turn is drawn and no control belongs in the output.
 *
 *  A run only short enough to hide one turn is drawn whole: a control that
 *  costs a press to save a single row is the same trade `foldAutonomousRuns`
 *  declines at its own threshold. */
export function autonomousRunWindow(
  total: number,
  headCount: number,
): { head: number; tail: number; hidden: number } {
  const tail = AUTONOMOUS_RUN_WINDOW_TAIL
  if (total <= headCount + tail + 1) return { head: total, tail: 0, hidden: 0 }
  return { head: headCount, tail, hidden: total - headCount - tail }
}

/** A run of consecutive autonomous turns behind one header. Starts closed for
 *  the same reason each turn does: the transcript's subject is the conversation
 *  these wakes sit between. Expanding renders the run's turns as the same rows
 *  they would be at top level, each still closed and each still its own turn --
 *  but only the window's worth of them, with the middle behind a control. */
function AutonomousTurnRun({
  entries,
  showMetadata,
  variant,
  showSourceBadge,
  toolOutputsCoveredSinceMs,
  toolOutputsCoveredThroughMs,
  toolOutputHydrationContract,
  action,
}: {
  entries: KeeperConversationEntry[]
  showMetadata?: boolean
  variant: ChatTranscriptVariant
  showSourceBadge: boolean
  toolOutputsCoveredSinceMs: number | null
  toolOutputsCoveredThroughMs: number | null
  toolOutputHydrationContract: ToolCallOutputHydrationContract | null
  action?: ChatTranscriptAction
}) {
  const [open, setOpen] = useState(false)
  // Only ever grows, and only by a press: new turns arriving in an open run
  // extend the tail, so the reader's walked-down head stays where they left it.
  const [headCount, setHeadCount] = useState(AUTONOMOUS_RUN_WINDOW_HEAD)
  const first = timeLabel(entries[0]?.timestamp)
  const last = timeLabel(entries[entries.length - 1]?.timestamp)
  // Both ends or neither: a half range would read as a single point in time.
  const range = first && last ? (first === last ? first : `${first} ~ ${last}`) : null
  const drawn = autonomousRunWindow(entries.length, headCount)
  const toolSummary = useMemo(() => autonomousToolSummary(entries), [entries])
  const turn = (entry: KeeperConversationEntry) => html`<${AutonomousTurnGroup}
    key=${entry.id}
    entry=${entry}
    showMetadata=${showMetadata}
    variant=${variant}
    showSourceBadge=${showSourceBadge}
    toolOutputsCoveredSinceMs=${toolOutputsCoveredSinceMs}
    toolOutputsCoveredThroughMs=${toolOutputsCoveredThroughMs}
    toolOutputHydrationContract=${toolOutputHydrationContract}
    action=${action}
  />`
  return html`
    <div class="chat-block-trace chat-auto-run ${open ? 'open' : ''}">
      <button
        type="button"
        class="chat-block-trace-hd"
        onClick=${() => setOpen((o) => !o)}
        aria-expanded=${open}
      >
        <span class="chat-block-trace-chev">${open ? '▾' : '▸'}</span>
        <span class="chat-block-trace-label">자율턴</span>
        <span class="chat-block-trace-count">${entries.length}개</span>
        ${toolSummary
          ? html`<span class="chat-block-trace-tools" title=${toolSummary}>${toolSummary}</span>`
          : null}
        ${range ? html`<span class="chat-block-trace-meta">${range}</span>` : null}
      </button>
      ${open
        ? html`<div class="chat-auto-run-turns">
            ${entries.slice(0, drawn.head).map(turn)}
            ${drawn.hidden > 0
              ? html`<button
                  type="button"
                  class="chat-auto-run-more"
                  onClick=${() => setHeadCount((n) => n + AUTONOMOUS_RUN_WINDOW_STEP)}
                >
                  가운데 ${drawn.hidden}개 더 보기
                </button>`
              : null}
            ${drawn.tail > 0 ? entries.slice(entries.length - drawn.tail).map(turn) : null}
          </div>`
        : null}
    </div>
  `
}

type ChatRenderUnit =
  | { kind: 'entry'; entry: KeeperConversationEntry }
  | { kind: 'toolGroup'; id: string; entries: KeeperConversationEntry[] }
  | { kind: 'turnBundle'; id: string; entries: KeeperConversationEntry[]; entry: KeeperConversationEntry }
  // One turn the keeper took on its own, collapsed into one row. Kept
  // separate from turnBundle because these are not answers to anyone: a keeper
  // wakes on the order of once a minute, so rendering each turn expanded would
  // bury the conversation it sits between. The exact turn remains the group
  // boundary; adjacent autonomous turns must never merge into one giant run.
  | { kind: 'autonomousGroup'; id: string; entry: KeeperConversationEntry }
  // Consecutive autonomous turns behind one header. Collapsing each turn
  // individually bounds how tall one wake renders but not how many wakes do:
  // an hour with nobody watching still puts dozens of identical rows between
  // two human messages, which buries the conversation the same way expanding
  // them would. This is a container, not a merge — every turn keeps its own
  // row and its own open/closed state inside, so the exact turn is still the
  // group boundary. Runs are cut at any boundary the transcript itself has to
  // draw; see foldAutonomousRuns.
  | { kind: 'autonomousRun'; id: string; entries: KeeperConversationEntry[] }

function entryTurnRef(entry: KeeperConversationEntry): string | null {
  const value = entry.turnRef?.trim()
  return value ? value : null
}

function canAppendToolToRun(run: KeeperConversationEntry[], entry: KeeperConversationEntry): boolean {
  if (run.length === 0) return true
  const first = run[0]
  if (!first) return true
  const firstTurnRef = entryTurnRef(first)
  const nextTurnRef = entryTurnRef(entry)
  if (firstTurnRef || nextTurnRef) {
    return firstTurnRef !== null && nextTurnRef !== null && firstTurnRef === nextTurnRef
  }
  return true
}

function canBundleToolsWithAssistant(run: KeeperConversationEntry[], assistant: KeeperConversationEntry): boolean {
  if (run.length === 0) return true
  const first = run[0]
  if (!first) return true
  const toolTurnRef = entryTurnRef(first)
  const assistantTurnRef = entryTurnRef(assistant)
  if (toolTurnRef || assistantTurnRef) {
    return toolTurnRef !== null && assistantTurnRef !== null && toolTurnRef === assistantTurnRef
  }
  return true
}

// Fold maximal runs of consecutive tool-call entries into one group. Persisted
// rows carry turnRef; use it as the hard join key when present, falling back to
// adjacency only for legacy/live rows that have no turn provenance. When the run
// belongs to the following assistant entry, render both as one turn bundle so
// "작업 과정" visually belongs to the answer it produced. Assistant traceSteps
// can also produce a bundle without tools (thinking-only turns).
// Mirrors isAutonomousTurnEntry in keeper-state. Kept local because this module
// is a leaf renderer and must not import the state module; KeeperConversationSource
// is the shared type, so a drifting label fails to compile rather than silently
// matching nothing.
function isAutonomousTurnEntry(entry: KeeperConversationEntry): boolean {
  return entry.source === 'autonomous_turn'
}

// Exported for unit testing (same convention as interleaveTraceAndTools): the
// grouping contract is asserted on the unit list, without a jsdom render.
export function buildChatRenderUnits(
  entries: KeeperConversationEntry[],
  groupToolCalls: boolean,
): ChatRenderUnit[] {
  const units: ChatRenderUnit[] = []
  let run: KeeperConversationEntry[] = []
  const flush = () => {
    if (run.length === 0) return
    const first = run[0]
    if (!first) return
    units.push({ kind: 'toolGroup', id: `tracegroup-${first.id}`, entries: run })
    run = []
  }
  for (const entry of entries) {
    if (isAutonomousTurnEntry(entry)) {
      // Any open tool run belongs to the direct turn that preceded this wake.
      flush()
      units.push({ kind: 'autonomousGroup', id: `autonomous-${entry.id}`, entry })
      continue
    }
    if (!groupToolCalls) {
      units.push({ kind: 'entry', entry })
      continue
    }
    if (entry.role === 'tool') {
      if (!canAppendToolToRun(run, entry)) flush()
      run.push(entry)
    } else {
      if (
        entry.role === 'assistant'
        && (run.length > 0 || (entry.traceSteps?.length ?? 0) > 0)
        && canBundleToolsWithAssistant(run, entry)
      ) {
        units.push({
          kind: 'turnBundle',
          id: `turn-${run[0]?.id ?? entry.id}`,
          entries: run,
          entry,
        })
        run = []
        continue
      }
      flush()
      if (entry.role === 'assistant' && (entry.traceSteps?.length ?? 0) > 0) {
        units.push({
          kind: 'turnBundle',
          id: `turn-${entry.id}`,
          entries: [],
          entry,
        })
        continue
      }
      units.push({ kind: 'entry', entry })
    }
  }
  flush()
  return units
}

// Below this many consecutive autonomous turns, folding costs more than it
// saves: one or two stray wakes read as part of the surrounding conversation,
// and hiding them behind a header only adds a click. At or above it the rows
// stop being incidental and start being the wall this fold exists to remove.
const AUTONOMOUS_RUN_FOLD_THRESHOLD = 3

/** Fold consecutive `autonomousGroup` units behind one `autonomousRun`.
 *
 *  Runs shorter than the threshold are returned untouched, so a transcript with
 *  the occasional wake renders exactly as before.
 *
 *  A folded run is not allowed to swallow a row the transcript still has to
 *  anchor something on: the caller draws day dividers and the unread line
 *  against top-level units, and a unit absorbed into a run stops being one.
 *  `startsNewRun` cuts before such a row, and `runBoundaryKey` cuts whenever the
 *  key changes inside an open run — both leave the row at top level as the
 *  start of the next run. */
export function foldAutonomousRuns(
  units: ChatRenderUnit[],
  opts: {
    startsNewRun: (unit: ChatRenderUnit) => boolean
    runBoundaryKey: (unit: ChatRenderUnit) => string | null
  },
): ChatRenderUnit[] {
  const out: ChatRenderUnit[] = []
  let run: Extract<ChatRenderUnit, { kind: 'autonomousGroup' }>[] = []
  let boundary: string | null = null
  const flush = () => {
    const first = run[0]
    if (first && run.length >= AUTONOMOUS_RUN_FOLD_THRESHOLD) {
      // The run reuses the first group's id so its key and timestamp are the
      // ones the caller already computed anchors from: a divider that would
      // have landed on that group lands on the run instead of vanishing.
      out.push({ kind: 'autonomousRun', id: first.id, entries: run.map((unit) => unit.entry) })
    } else {
      out.push(...run)
    }
    run = []
    boundary = null
  }
  for (const unit of units) {
    if (unit.kind !== 'autonomousGroup') {
      flush()
      out.push(unit)
      continue
    }
    const key = opts.runBoundaryKey(unit)
    // A null key carries no boundary information, so it neither cuts the run
    // nor overwrites the last key that did.
    if (opts.startsNewRun(unit) || (key !== null && boundary !== null && key !== boundary)) {
      flush()
    }
    if (key !== null) boundary = key
    run.push(unit)
  }
  flush()
  return out
}

function unitTimestamp(unit: ChatRenderUnit): string | null {
  switch (unit.kind) {
    case 'entry':
    case 'autonomousGroup':
      return unit.entry.timestamp ?? null
    case 'toolGroup':
    case 'autonomousRun':
      return unit.entries[0]?.timestamp ?? null
    case 'turnBundle':
      return unit.entries[0]?.timestamp ?? unit.entry.timestamp ?? null
  }
}

function unitTimestampMs(unit: ChatRenderUnit): number | null {
  const ts = unitTimestamp(unit)
  if (!ts) return null
  const ms = Date.parse(ts)
  return Number.isFinite(ms) ? ms : null
}

function unitKey(unit: ChatRenderUnit): string {
  return unit.kind === 'entry' ? unit.entry.id : unit.id
}

function renderChatTranscriptBody(opts: {
  entries: KeeperConversationEntry[]
  showDayDividers: boolean
  groupToolCalls: boolean
  showMetadata?: boolean
  variant: ChatTranscriptVariant
  showSourceBadge: boolean
  toolOutputsCoveredSinceMs: number | null
  toolOutputsCoveredThroughMs: number | null
  toolOutputHydrationContract: ToolCallOutputHydrationContract | null
  // Since-last-seen cursor (unix seconds) for the unread divider; null on every
  // non-keeper chat surface so those transcripts render unchanged.
  unreadAfterTs: number | null
  // When true, skip folding autonomous groups into collapsed runs.
  expandAutonomousRuns?: boolean
  action?: ChatTranscriptAction
}): VNode[] {
  const { entries, showDayDividers, groupToolCalls, showMetadata, variant, showSourceBadge, toolOutputsCoveredSinceMs, toolOutputsCoveredThroughMs, toolOutputHydrationContract, unreadAfterTs, expandAutonomousRuns, action } = opts
  const ungroupedUnits = buildChatRenderUnits(entries, groupToolCalls)
  // Anchored on the unfolded list: folding must not move the unread line, only
  // avoid hiding it. foldAutonomousRuns cuts a run open at this key so the unit
  // it names is still top level below.
  const unreadAnchorKey = unreadDividerAnchorKey(
    ungroupedUnits.map(unit => ({ key: unitKey(unit), tsMs: unitTimestampMs(unit) })),
    unreadAfterTs,
  )
  const units = expandAutonomousRuns
    ? ungroupedUnits
    : foldAutonomousRuns(ungroupedUnits, {
    startsNewRun: (unit) => unreadAnchorKey !== null && unitKey(unit) === unreadAnchorKey,
    // Day dividers are emitted per unit below, so a run that spanned midnight
    // would show only its first day. Cutting on the day key keeps every day
    // that has turns in it addressable by a divider.
    runBoundaryKey: (unit) => (showDayDividers ? dayKey(unitTimestamp(unit)) : null),
  })
  const out: VNode[] = []
  // Track the last NON-NULL calendar day rather than only the immediately
  // previous entry, so a null-timestamp entry (live placeholder, checkpoint) in
  // the middle of a day cannot poison the comparison and re-emit a spurious
  // second divider for a day already shown above.
  let lastDayKey: string | null = null
  for (const unit of units) {
    const ts = unitTimestamp(unit)
    if (showDayDividers) {
      const dk = dayKey(ts)
      if (dk && dk !== lastDayKey) {
        out.push(html`<div class="kw-daydiv" key=${`day:${dk}`}>${dayDividerLabel(ts)}</div>`)
        lastDayKey = dk
      }
    }
    // Placed after any day divider so the unread line sits closest to the first
    // unread message.
    if (unreadAnchorKey !== null && unitKey(unit) === unreadAnchorKey) {
      out.push(html`<div class="kw-daydiv kw-unreaddiv" key="unread-divider">${UNREAD_DIVIDER_LABEL}</div>`)
    }
    if (unit.kind === 'autonomousRun') {
      out.push(html`<${AutonomousTurnRun}
        key=${unit.id}
        entries=${unit.entries}
        showMetadata=${showMetadata}
        variant=${variant}
        showSourceBadge=${showSourceBadge}
        toolOutputsCoveredSinceMs=${toolOutputsCoveredSinceMs}
        toolOutputsCoveredThroughMs=${toolOutputsCoveredThroughMs}
        toolOutputHydrationContract=${toolOutputHydrationContract}
        action=${action}
      />`)
    } else if (unit.kind === 'autonomousGroup') {
      out.push(html`<${AutonomousTurnGroup}
        key=${unit.id}
        entry=${unit.entry}
        showMetadata=${showMetadata}
        variant=${variant}
        showSourceBadge=${showSourceBadge}
        toolOutputsCoveredSinceMs=${toolOutputsCoveredSinceMs}
        toolOutputsCoveredThroughMs=${toolOutputsCoveredThroughMs}
        toolOutputHydrationContract=${toolOutputHydrationContract}
        action=${action}
      />`)
    } else if (unit.kind === 'toolGroup') {
      out.push(html`<${ToolTraceCard}
        key=${unit.id}
        tools=${unit.entries}
        toolOutputsCoveredSinceMs=${toolOutputsCoveredSinceMs}
        toolOutputsCoveredThroughMs=${toolOutputsCoveredThroughMs}
        toolOutputHydrationContract=${toolOutputHydrationContract}
      />`)
    } else if (unit.kind === 'turnBundle') {
      out.push(html`<${TurnWorkBundle}
        key=${unit.id}
        tools=${unit.entries}
        assistant=${unit.entry}
        showMetadata=${showMetadata}
        variant=${variant}
        showSourceBadge=${showSourceBadge}
        toolOutputsCoveredSinceMs=${toolOutputsCoveredSinceMs}
        toolOutputsCoveredThroughMs=${toolOutputsCoveredThroughMs}
        toolOutputHydrationContract=${toolOutputHydrationContract}
        action=${action}
      />`)
    } else if (unit.entry.role === 'tool') {
      out.push(html`<${ToolCallBubble} key=${unit.entry.id} entry=${unit.entry} />`)
    } else {
      out.push(html`<${ChatMessageSurface}
        key=${unit.entry.id}
        entry=${unit.entry}
        showMetadata=${showMetadata !== false}
        variant=${variant}
        showSourceBadge=${showSourceBadge}
        contextScope=${unit.entry.surface ? buildChatContextScope(unit.entry, entries) : null}
        action=${action}
      />`)
    }
  }
  return out
}

function traceStepsSignature(entry: KeeperConversationEntry): string {
  const steps = entry.traceSteps
  if (!steps?.length) return ''
  return steps.map((step) => {
    if (step.kind === 'think') return `think:${step.text.length}:${step.ts ?? ''}`
    if (step.kind === 'reason') return `reason:${step.text.length}:${step.detail?.length ?? 0}:${step.ts ?? ''}`
    if (step.kind === 'progress') return `progress:${step.text.length}:${step.ts ?? ''}`
    return `tool:${step.name}:${step.status ?? ''}:${step.dur ?? ''}:${step.result?.length ?? 0}`
  }).join(',')
}

export function ChatTranscript({
  entries,
  emptyText,
  showMetadata,
  variant = 'default',
  size = 'default',
  showDayDividers = false,
  groupToolCalls = false,
  showSourceBadge = false,
  toolOutputsCoveredSinceMs = null,
  toolOutputsCoveredThroughMs = null,
  toolOutputHydrationContract = null,
  unreadAfterTs = null,
  expandAutonomousRuns = false,
  onSeenBottom,
  action,
}: {
  entries: KeeperConversationEntry[]
  emptyText: string
  showMetadata?: boolean
  variant?: ChatTranscriptVariant
  size?: ChatTranscriptSize
  // C1/C2: opt-in workspace polish. Default false so every other chat surface
  // (copilot dock, detail page, etc.) renders unchanged.
  showDayDividers?: boolean
  // Opt-in: fold a turn's consecutive tool-call rows into one "작업 과정" card.
  // Default false so non-workspace surfaces keep the flat per-row ToolCallBubble.
  groupToolCalls?: boolean
  showSourceBadge?: boolean
  toolOutputsCoveredSinceMs?: number | null
  toolOutputsCoveredThroughMs?: number | null
  toolOutputHydrationContract?: ToolCallOutputHydrationContract | null
  // Since-last-seen cursor (unix seconds) driving the unread divider. Null on
  // non-keeper surfaces -> no divider.
  unreadAfterTs?: number | null
  // When true, skip folding autonomous groups into collapsed runs.
  expandAutonomousRuns?: boolean
  // Called when the operator has demonstrably caught up (scrolled/pinned to the
  // bottom, or a new row arrived while pinned, or the tab regained visibility
  // while pinned). The keeper panel uses it to advance the last-seen cursor.
  onSeenBottom?: () => void
  action?: ChatTranscriptAction
}) {
  const scrollerRef = useRef<HTMLDivElement | null>(null)
  const pinnedRef = useRef(true)
  const [unread, setUnread] = useState(false)
  // Latest onSeenBottom captured in a ref so the scroll/effect callbacks always
  // fire the current closure without listing it as an effect dependency.
  const onSeenBottomRef = useRef(onSeenBottom)
  onSeenBottomRef.current = onSeenBottom
  const lastSignature = useMemo(
    () => entries.map(entry => `${entry.id}:${entry.text.length}:${entry.delivery}:${entry.streamState ?? ''}:${traceStepsSignature(entry)}`).join('|'),
    [entries],
  )
  const toolOutputSignature = useMemo(
    () => {
      const coverageSig = `${toolOutputsCoveredSinceMs ?? ''}:${toolOutputsCoveredThroughMs ?? ''}:${toolOutputHydrationContract?.status ?? ''}:${toolOutputHydrationContract?.failureReason ?? ''}`
      return entries
        .filter(entry => entry.role === 'tool')
        .map((entry) => {
          const output = lookupToolCallOutput(entry.executionId)
          return output
            ? `${entry.id}:${output.success}:${output.duration_ms}:${toolOutputDisplay(output.output)?.text.length ?? 0}`
            : `${entry.id}:pending:${coverageSig}`
        })
        .join('|')
    },
    [entries, toolCallOutputsByExecutionId.value, toolOutputsCoveredSinceMs, toolOutputsCoveredThroughMs, toolOutputHydrationContract],
  )

  const scrollToBottom = () => {
    const el = scrollerRef.current
    if (!el) return
    el.scrollTop = el.scrollHeight
    pinnedRef.current = true
    setUnread(false)
    onSeenBottomRef.current?.()
  }

  const handleScroll = () => {
    const el = scrollerRef.current
    if (!el) return
    const distance = el.scrollHeight - el.scrollTop - el.clientHeight
    const pinned = distance <= STICK_TO_BOTTOM_THRESHOLD_PX
    pinnedRef.current = pinned
    if (pinned) {
      setUnread(false)
      onSeenBottomRef.current?.()
    }
  }

  useLayoutEffect(() => {
    const el = scrollerRef.current
    if (!el) return
    if (pinnedRef.current) {
      const snap = () => { el.scrollTop = el.scrollHeight }
      snap()
      requestAnimationFrame(snap)
      // Bottom-pinned with new content arriving means the operator is watching
      // it live — advance the cursor so the divider does not resurrect it.
      onSeenBottomRef.current?.()
    } else {
      setUnread(true)
    }
  }, [lastSignature, toolOutputSignature])

  // Advance the cursor when the tab regains visibility while pinned to bottom:
  // background rows that streamed in are treated as seen only once the operator
  // could actually see them. Pattern mirrors lib/auto-refresh.ts visibilitychange.
  useEffect(() => {
    const onVisible = () => {
      if (typeof document.visibilityState === 'string' && document.visibilityState !== 'visible') return
      if (!pinnedRef.current) return
      onSeenBottomRef.current?.()
    }
    document.addEventListener('visibilitychange', onVisible)
    return () => { document.removeEventListener('visibilitychange', onVisible) }
  }, [])

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
                <div class="text-xs font-bold uppercase tracking-4 text-[var(--color-fg-secondary)]">직접 메시지 없음</div>
                <div class="mt-3 max-w-[34rem] text-base font-medium leading-airy text-[var(--color-fg-primary)]">${emptyText}</div>
              </div>
            `
          : renderChatTranscriptBody({
              entries,
              showDayDividers,
              groupToolCalls,
              showMetadata,
              variant,
              showSourceBadge,
              toolOutputsCoveredSinceMs,
              toolOutputsCoveredThroughMs,
              toolOutputHydrationContract,
              unreadAfterTs,
              expandAutonomousRuns,
              action,
            })}
      </div>
      ${unread
        ? html`
            <button
              type="button"
              class="absolute bottom-3 left-1/2 -translate-x-1/2 inline-flex items-center gap-1.5 rounded-full border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-3.5 py-1.5 text-xs font-semibold text-[var(--color-fg-primary)] shadow-[var(--shadow-raised)] transition-colors hover:bg-[var(--color-bg-hover)] ${CHAT_FOCUS_RING}"
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
export const CHAT_COMPOSER_DEFAULT_KEEPER_LABEL = 'keeper'
export const CHAT_COMPOSER_COMMAND_HEADER_SUFFIX = '명령'
export const CHAT_COMPOSER_DROP_PLACEHOLDER = '여기에 놓아 첨부…'

export function AttachDraftChip({
  attachment,
  onRemove,
}: {
  attachment: KeeperConversationAttachment
  onRemove: () => void
}) {
  const meta = [attachment.dims, formatAttachmentSize(attachment.size)].filter(Boolean).join(' · ')
  return html`
    <div class="cdraft att" data-chat-attachment-draft=${attachment.id}>
      <div class="cdraft-thumb">
        ${attachment.type === 'image'
          ? html`<img src=${attachment.data} alt=${attachment.name} />`
          : html`<span class="cdraft-glyph">◫</span>`}
      </div>
      <div class="cdraft-meta">
        <span class="cdraft-name mono">${attachment.name}</span>
        <span class="cdraft-sub mono">${meta}</span>
      </div>
      <button
        type="button"
        class="cdraft-x"
        title="첨부 제거"
        aria-label="${attachment.name} 첨부 제거"
        onClick=${onRemove}
      >
        ✕
      </button>
    </div>
  `
}

export interface ComposerVoiceDraft {
  transcript: string
}

export function ChatComposer({
  draft: draftProp,
  placeholder,
  disabled,
  streaming,
  streamStartedAt,
  lastEventAt,
  allowSendWhileStreaming = false,
  commands = [],
  onDraftChange,
  onSend,
  onAbort,
  layout = 'default',
  draftPersistKey,
  keeperLabel,
  footerMode = 'always',
}: {
  draft?: string
  placeholder: string
  disabled: boolean
  streaming: boolean
  streamStartedAt?: number | null
  /** Wall-clock ms of the most recent stream event; drives the stall hint. */
  lastEventAt?: number | null
  /** When true, a new durable operation may be submitted while another
   *  operation is streaming. */
  allowSendWhileStreaming?: boolean
  commands?: ChatComposerCommand[]
  /** Optional controlled draft handler. When omitted the composer keeps its
   *  own draft state, which prevents the host from re-rendering on every
   *  keystroke (see keeper-workspace chat performance). */
  onDraftChange?: (value: string) => void
  onSend: (payload: ChatComposerSendPayload) => void | Promise<void>
  onAbort?: () => void
  layout?: 'default' | 'primary'
  /** Operator-facing keeper label for the slash-command menu header. This is
   *  intentionally separate from [draftPersistKey], which may be an opaque
   *  storage key. */
  keeperLabel?: string
  /** `activity` keeps queue/stall evidence but removes the idle instruction
   * row, allowing the dense keeper-v2 workspace to match its single-row
   * composer. Other chat layouts retain the footer by default. */
  footerMode?: 'always' | 'activity'
  /** When set (and uncontrolled), the composer persists its unsent draft
   *  per key across remounts via keeper-chat-store, so switching keepers
   *  keeps each keeper's own half-typed message without leaking it to
   *  another keeper. Ignored in controlled mode (the host owns the draft).
   *
   *  Callers pass `key=${draftPersistKey}` too, so a keeper switch remounts
   *  the composer. The effect below additionally re-syncs the buffer if the
   *  key changes in place, so the write key and the editing buffer can never
   *  diverge into a cross-keeper leak even without the remount. */
  draftPersistKey?: string
}) {
  const [elapsed, setElapsed] = useState(0)
  const [voiceElapsed, setVoiceElapsed] = useState(0)
  const [focus, setFocus] = useState(false)
  const [drag, setDrag] = useState(false)
  const [slashIdx, setSlashIdx] = useState(0)
  const [attachments, setAttachments] = useState<KeeperConversationAttachment[]>([])
  const [voiceDraft, setVoiceDraft] = useState<ComposerVoiceDraft | null>(null)
  const isControlled = typeof draftProp === 'string'
  const draftPersistStoreKey = draftPersistKey?.trim() ?? ''
  const slashMenuKeeperLabel = keeperLabel?.trim() || CHAT_COMPOSER_DEFAULT_KEEPER_LABEL
  // Lazy initializer: on (re)mount restore this keeper's persisted draft so a
  // keeper switch (key=${keeperName} remount) does not drop a half-typed
  // message. Controlled callers manage their own draft, so skip persistence.
  const [internalDraftState, setInternalDraftState] = useState<{ key: string | null; value: string }>(() =>
    isControlled
      ? { key: null, value: '' }
      : {
          key: draftPersistStoreKey,
          value: draftPersistStoreKey ? readKeeperDraft(draftPersistStoreKey) : '',
        },
  )
  const internalDraft =
    !isControlled && draftPersistStoreKey !== internalDraftState.key
      ? draftPersistStoreKey
        ? readKeeperDraft(draftPersistStoreKey)
        : ''
      : internalDraftState.value
  const draft = isControlled ? draftProp : internalDraft
  const setDraft = (value: string) => {
    if (isControlled) {
      onDraftChange?.(value)
    } else {
      setInternalDraftState({ key: draftPersistStoreKey, value })
      if (draftPersistStoreKey) writeKeeperDraft(draftPersistStoreKey, value)
    }
  }
  // External-store sync: a normal keeper switch remounts (key=${keeperName}) and
  // the lazy initializer above already restored the draft. This layout effect
  // covers the one case the initializer cannot — `draftPersistKey` changing
  // without a remount. The render-time fallback above prevents a stale buffer
  // from being shown for the new key; this effect aligns the internal state for
  // the next edit.
  useLayoutEffect(() => {
    if (isControlled) {
      if (internalDraftState.key !== null) setInternalDraftState({ key: null, value: '' })
      return
    }
    if (draftPersistStoreKey !== internalDraftState.key) {
      setInternalDraftState({
        key: draftPersistStoreKey,
        value: draftPersistStoreKey ? readKeeperDraft(draftPersistStoreKey) : '',
      })
    }
  }, [draftPersistStoreKey, internalDraftState.key, isControlled])
  const fileInputRef = useRef<HTMLInputElement | null>(null)
  const textareaRef = useRef<HTMLTextAreaElement | null>(null)

  // RFC-0236 P1: speak to compose. Voice transcription is saved as a visual draft
  // card (VoiceDraft) matching the mockup and board composers.
  const voice = useVoiceInput({
    onTranscribed: (text) => {
      if (text) {
        setVoiceDraft({
          transcript: text,
        })
      }
    },
    onError: (message) => showToast(message, 'error'),
  })

  useEffect(() => {
    if (voice.state !== 'recording') {
      setVoiceElapsed(0)
      return
    }
    const startedAt = Date.now()
    const tick = () => {
      const duration = Math.round((Date.now() - startedAt) / 1000)
      setVoiceElapsed(duration)
    }
    tick()
    const id = setInterval(tick, 1000)
    return () => clearInterval(id)
  }, [voice.state])

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

  const streamLabel = streaming
    ? allowSendWhileStreaming
      ? '새 작업 접수'
      : `응답 중${elapsed > 0 ? ` ${elapsed}s` : ''}`
    : '전송'
  const isStreamWarning = streaming && elapsed > 60
  const hasContent = draft.trim() !== '' || attachments.length > 0 || voiceDraft !== null
  const sendDisabled = disabled || !hasContent || (streaming && !allowSendWhileStreaming)
  const slashMatch = /^\/([^\s]*)$/.exec(draft)
  const slashQuery = slashMatch?.[1]?.toLowerCase() ?? null
  const slashMatches = useMemo(
    () =>
      slashQuery === null
        ? []
        : commands.filter((command) => {
            const id = command.id.toLowerCase()
            const label = command.label.toLowerCase()
            return id.startsWith(slashQuery) || label.startsWith(slashQuery)
          }),
    [commands, slashQuery],
  )
  const slashOpen = voice.state === 'idle' && slashMatches.length > 0
  const activeSlashIdx = slashOpen ? Math.min(slashIdx, slashMatches.length - 1) : 0
  const activeSlashCommand = slashOpen ? slashMatches[activeSlashIdx] : undefined

  const isPrimary = layout === 'primary'

  const ingestFiles = async (files: FileList | null) => {
    if (!files || files.length === 0) return
    const { attachments: added, errors } = await collectAttachments(files, attachments)
    errors.forEach((message) => showToast(message, 'error'))
    if (added.length > 0) {
      setAttachments((prev) => [...prev, ...added])
    }
  }

  const handlePaste = (event: ClipboardEvent) => {
    const items = event.clipboardData?.items
    if (!items) return
    const imageFiles: File[] = []
    for (const item of Array.from(items)) {
      if (item.type.startsWith('image/')) {
        const file = item.getAsFile()
        if (file) imageFiles.push(file)
      }
    }
    if (imageFiles.length > 0) {
      event.preventDefault()
      const dt = new DataTransfer()
      for (const f of imageFiles) dt.items.add(f)
      void ingestFiles(dt.files)
    }
  }

  const handleSend = () => {
    if (sendDisabled) return
    const blocks: ChatBlock[] = []
    const userBlocks: KeeperUserInputBlock[] = []
    for (const att of attachments) {
      blocks.push({
        t: 'attach',
        id: att.id,
        kind: att.type,
        name: att.name,
        dims: att.dims,
        src: att.type === 'image' ? att.data : undefined,
        ph: att.type !== 'image' ? att.name : undefined,
        size: formatAttachmentSize(att.size),
        via: 'Dashboard 업로드',
        data: att.data,
        mimeType: att.mimeType,
        sizeBytes: att.size,
      } as ChatBlock)
      userBlocks.push({
        type: userInputMediaKindForAttachment(att),
        attachmentId: att.id,
        name: att.name,
        mimeType: att.mimeType,
        size: att.size,
      })
    }
    let text = draft.trim()
    if (voiceDraft) {
      const voiceText = voiceDraft.transcript
      text = text ? `${voiceText}\n\n${text}` : voiceText
    }

    if (text) {
      blocks.push({ t: 'p', html: escapeHtml(text) } as ChatBlock)
      userBlocks.push({ type: 'text', text })
    }
    void onSend({
      blocks,
      userBlocks,
      clientActionId: nextComposerClientActionId(),
      text,
    })
    setDraft('')
    setSlashIdx(0)
    setAttachments([])
    setVoiceDraft(null)
    if (textareaRef.current) textareaRef.current.style.height = 'auto'
  }

  const runSlashCommand = (command?: ChatComposerCommand) => {
    if (!command || command.disabled) return
    setDraft('')
    setSlashIdx(0)
    if (textareaRef.current) textareaRef.current.style.height = 'auto'
    void Promise.resolve(command.run()).catch((err) => {
      const message = err instanceof Error ? err.message : `${command.label} 실행 실패`
      showToast(message, 'error')
    })
  }

  const grow = (event: Event) => {
    const target = event.target as HTMLTextAreaElement
    setDraft(target.value)
    setSlashIdx(0)
    target.style.height = 'auto'
    target.style.height = `${Math.min(target.scrollHeight, 160)}px`
  }

  const onKeyDown = (event: KeyboardEvent) => {
    if (slashOpen) {
      if (event.key === 'ArrowDown') {
        event.preventDefault()
        setSlashIdx((activeSlashIdx + 1) % slashMatches.length)
        return
      }
      if (event.key === 'ArrowUp') {
        event.preventDefault()
        setSlashIdx((activeSlashIdx - 1 + slashMatches.length) % slashMatches.length)
        return
      }
      if (event.key === 'Enter' || event.key === 'Tab') {
        event.preventDefault()
        runSlashCommand(activeSlashCommand)
        return
      }
      if (event.key === 'Escape') {
        event.preventDefault()
        setDraft('')
        setSlashIdx(0)
        return
      }
    }
    if (isSubmitEnter(event) && !event.shiftKey) {
      event.preventDefault()
      if (!sendDisabled) {
        handleSend()
      }
    }
  }

  const onDragOver = (event: DragEvent) => {
    event.preventDefault()
    if (!drag) setDrag(true)
  }
  const onDragLeave = (event: DragEvent) => {
    if (event.currentTarget === event.target) setDrag(false)
  }
  const onDrop = (event: DragEvent) => {
    event.preventDefault()
    setDrag(false)
    void ingestFiles(event.dataTransfer?.files ?? null)
  }

  const composerClass = isPrimary ? 'composer primary' : 'composer'
  const boxClass = `composer-box ${focus ? 'focus' : ''} ${drag ? 'drag' : ''}`

  return html`
    <div
      class=${composerClass}
      onDragOver=${onDragOver}
      onDragLeave=${onDragLeave}
      onDrop=${onDrop}
      onPaste=${handlePaste}
    >
      <div class="composer-inner">
        ${isPrimary
          ? null
          : html`
              <div class="flex flex-wrap items-center justify-between gap-2">
                <div class="text-xs font-bold uppercase tracking-3 text-[var(--color-fg-secondary)]">메시지</div>
                <div class="text-xs text-[var(--color-fg-secondary)]">Enter로 전송, Shift+Enter로 줄바꿈</div>
              </div>
            `}
        ${attachments.length > 0 || voiceDraft
          ? html`
              <div class="composer-tray">
                ${attachments.map((att) => html`
                  <${AttachDraftChip}
                    key=${att.id}
                    attachment=${att}
                    onRemove=${() => setAttachments((prev) => prev.filter((a) => a.id !== att.id))}
                  />
                `)}
                ${voiceDraft
                  ? html`
                      <div class="cdraft voice" data-testid="composer-voice-draft">
                        <span class="cdraft-glyph mic">◌</span>
                        <div class="cdraft-tx">
                          <span class="cdraft-tx-k">받아쓰기</span>
                          <span class="cdraft-tx-v">${voiceDraft.transcript}</span>
                        </div>
                        <button
                          type="button"
                          class="cdraft-x"
                          title="음성 제거"
                          aria-label="Remove voice draft"
                          onClick=${() => { setVoiceDraft(null) }}
                          disabled=${disabled}
                        >
                          ✕
                        </button>
                      </div>
                    `
                  : null}
              </div>
            `
          : null}
        <div class=${boxClass}>
          ${slashOpen
            ? html`
                <div class="slashmenu" role="listbox" aria-label="keeper slash commands">
                  <div class="slashmenu-h">${slashMenuKeeperLabel} · ${CHAT_COMPOSER_COMMAND_HEADER_SUFFIX}</div>
                  ${slashMatches.map((command, index) => html`
                    <button
                      key=${`${command.group}:${command.id}`}
                      type="button"
                      role="option"
                      aria-selected=${index === activeSlashIdx ? 'true' : 'false'}
                      class=${`slashmenu-i ${index === activeSlashIdx ? 'on' : ''}${command.danger ? ' danger' : ''}`}
                      disabled=${command.disabled}
                      title=${command.disabledReason ?? command.hint ?? command.label}
                      onMouseEnter=${() => setSlashIdx(index)}
                      onMouseDown=${(event: MouseEvent) => event.preventDefault()}
                      onClick=${() => runSlashCommand(command)}
                    >
                      <span class="slashmenu-gl">${command.glyph ?? '⌁'}</span>
                      <span class="slashmenu-cmd mono">/${command.id}</span>
                      <span class="slashmenu-lbl">${command.label}</span>
                      <span class="slashmenu-hint">${command.disabledReason ?? command.hint ?? ''}</span>
                      <span class="slashmenu-grp">${command.group}</span>
                    </button>
                  `)}
                </div>
              `
            : null}
          <!-- Flush borderless textarea: prototype composer.jsx <textarea> has
               no inline styling; all box styling (border:0, outline:0,
               transparent bg, padding:9px 0) comes from .composer textarea in
               chat.css (mirrors styles/v2.css:932-936). Removing the prior
               inline Tailwind (control-textarea + border + rounded + px/py +
               bg + focus ring) drops the nested box the prototype lacks. -->
          ${voice.state === 'recording' || voice.state === 'transcribing'
            ? html`
                <div class=${`rec-bar ${voice.state === 'transcribing' ? 'transcribing' : ''}`}>
                  <span class="rec-dot"></span>
                  <span class="rec-lbl">${voice.state === 'recording' ? '녹음 중' : '전사 중'}</span>
                  <span class="rec-clock mono">${formatVoiceClock(voiceElapsed)}</span>
                  <div class="rec-wave" aria-hidden="true">
                    ${VOICE_WAVE_BARS.map((height, index) => html`
                      <span
                        key=${index}
                        class="rbar"
                        style=${`height: ${Math.round(4 + height * 18)}px; animation-delay: ${index * 34}ms`}
                      ></span>
                    `)}
                  </div>
                  <button
                    type="button"
                    class="rec-btn stop"
                    title=${voice.state === 'recording' ? '녹음 종료 — 받아쓰기' : '음성 전사 중'}
                    disabled=${voice.state !== 'recording'}
                    onClick=${voice.stop}
                  >
                    <${Square} size=${13} aria-hidden="true" /> 완료
                  </button>
                </div>
              `
            : html`
                <textarea
                  ref=${textareaRef}
                  class="composer-textarea"
                  rows=${layout === 'primary' ? 1 : 2}
                  placeholder=${drag ? CHAT_COMPOSER_DROP_PLACEHOLDER : placeholder}
                  aria-label="메시지 입력"
                  value=${draft}
                  onInput=${grow}
                  onKeyDown=${onKeyDown}
                  onFocus=${() => setFocus(true)}
                  onBlur=${() => setFocus(false)}
                  disabled=${disabled}
                ></textarea>
                <div class="composer-tools">
                  <input
                    ref=${fileInputRef}
                    type="file"
                    accept=${ATTACHMENT_INPUT_ACCEPT}
                    multiple
                    class="hidden"
                    aria-label="파일 첨부"
                    onChange=${(event: Event) => {
                      const target = event.target as HTMLInputElement
                      void ingestFiles(target.files)
                      target.value = ''
                    }}
                  />
                  <button
                    type="button"
                    class="ctool"
                    title="이미지·파일 첨부"
                    aria-label="이미지·파일 첨부"
                    disabled=${disabled}
                    onClick=${() => fileInputRef.current?.click()}
                  >
                    ⊕
                  </button>
                  ${voice.supported ? html`
                    <button
                      type="button"
                      class="ctool"
                      title="음성으로 입력"
                      aria-label="음성으로 입력"
                      disabled=${disabled}
                      onClick=${() => { void voice.start() }}
                    >
                      <${Mic} size=${15} aria-hidden="true" />
                    </button>
                  ` : null}
                  <button
                    type="button"
                    class="send ${isStreamWarning && !allowSendWhileStreaming ? 'warn' : ''}"
                    disabled=${sendDisabled}
                    onClick=${handleSend}
                  >
                    ${streamLabel}
                  </button>
                  ${streaming && onAbort
                    ? html`
                        <button
                          type="button"
                          class="ctool abort"
                          title="응답 중지"
                          aria-label="응답 중지"
                          onClick=${onAbort}
                        >
                          중지${elapsed > 0 ? ` (${elapsed}s)` : ''}
                        </button>
                      `
                    : null}
                </div>
              `}
        </div>
        ${footerMode === 'always' || (footerMode === 'activity' && isStalled)
          ? html`
              <div class="composer-foot">
                <span class="hint">
                  <kbd>⌘</kbd> <kbd>↵</kbd> 전송 · 끌어다 놓아 첨부
                  ${isStalled
                    ? html`<span class="ml-2 text-[var(--color-status-warn)]" data-chat-stall-hint>마지막 수신 ${sinceLastEvent}초 전 — 스트림 지연</span>`
                    : null}
                </span>
              </div>
            `
          : null}
      </div>
    </div>
  `
}
