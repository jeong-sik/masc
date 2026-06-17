import { html } from 'htm/preact'
import type { ComponentChildren, VNode } from 'preact'
import { marked } from 'marked'
import DOMPurify from 'dompurify'
import { JsonViewerCard } from '../common/json-viewer'
import { highlightCodeHtml } from '../common/shiki-highlighter'
import { useEffect, useId, useLayoutEffect, useMemo, useRef, useState } from 'preact/hooks'
import { ringFocusClasses } from '../common/ring'
import { collectAttachments } from './attachments'
import { parseMarkdownToBlocks } from './markdown-blocks'
import { showToast } from '../common/toast'

const CHAT_FOCUS_RING = ringFocusClasses({ tone: 'accent-medium', width: 2 })
import { formatTimeHms } from '../../lib/format-time'
import { formatCost } from '../../lib/format-number'
import { isSubmitEnter } from '../../lib/keyboard'
import type { ChatBlock, ChatBroadcastBlock, ChatCalloutBlock, ChatLinkBlock, ChatMermaidBlock, ChatShellBlock, ChatTableBlock, ChatTraceStep, ChatVoiceBlock } from '../../types'
import type { KeeperConversationAttachment, KeeperConversationAudioClip, KeeperConversationDetails, KeeperConversationEntry, SurfaceRef } from '../../types'
import type { ToolCallOutputBlob } from '../../api/dashboard'
import { lookupToolCallOutput } from '../../tool-call-output-store'
import { Sigil } from '../common/sigil-chip'
import { SuggestionChip } from '../common/suggestion-chip'
import { StatusDot } from '../common/status-dot'
import type { JSX } from 'preact'

/** Keeper identity used by SigilBadge. */
export interface SigilBadgeKeeper {
  slot: number
  id: string
  sigil?: string
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

function downloadArtifact(data: string, filename: string, mimeType?: string): void {
  const href = data.startsWith('data:')
    ? data
    : URL.createObjectURL(new Blob([data], { type: mimeType ?? 'application/octet-stream' }))
  const a = document.createElement('a')
  a.href = href
  a.download = filename
  a.style.display = 'none'
  document.body.appendChild(a)
  a.click()
  document.body.removeChild(a)
  if (!data.startsWith('data:')) {
    setTimeout(() => URL.revokeObjectURL(href), 1000)
  }
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
        <div
          class="chat-lightbox-md markdown-body"
          dangerouslySetInnerHTML=${{
            __html: DOMPurify.sanitize(marked.parse(text) as string),
          }}
        />
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

function linkifyHtml(raw: string): string {
  if (!raw || raw.indexOf('http') === -1 || raw.indexOf('<a ') !== -1) return raw
  return raw.replace(
    /(^|[\s(>])(https?:\/\/[^\s<)]+[^\s<).,!?:;])/g,
    '$1<a class="inline-link" href="$2" target="_blank" rel="noopener noreferrer">$2</a>',
  )
}

function sanitizeHtml(raw: string): string {
  return DOMPurify.sanitize(raw)
}

function sanitizeSvg(raw: string): string {
  return DOMPurify.sanitize(raw, { USE_PROFILES: { svg: true } })
}

function renderInlineHtml(raw: string): { __html: string } {
  return { __html: sanitizeHtml(linkifyHtml(raw)) }
}

function highlightJson(obj: unknown): string {
  const s = JSON.stringify(obj, null, 2)
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

async function copyCodeToClipboard(text: string): Promise<void> {
  try {
    await navigator.clipboard.writeText(text)
    showToast('코드를 복사했습니다', 'success')
  } catch {
    showToast('복사하지 못했습니다', 'error')
  }
}

function ChatCodeBlock({ cap, html: htmlContent, source }: { cap?: string; html: string; source?: string }) {
  const [highlighted, setHighlighted] = useState<string | null>(null)
  const [failed, setFailed] = useState(false)
  const codeId = useId()

  useEffect(() => {
    let cancelled = false
    const run = async () => {
      try {
        const text = codeBlockText(htmlContent, source)
        const next = await highlightCodeHtml(text, cap && cap.trim() ? cap.trim() : 'text')
        if (!cancelled) setHighlighted(next)
      } catch {
        if (!cancelled) setFailed(true)
      }
    }
    void run()
    return () => { cancelled = true }
  }, [htmlContent, cap, source])

  const plain = codeBlockText(htmlContent, source)

  return html`
    <div class="chat-block-code ${failed ? 'chat-block-code-fallback' : ''}" data-chat-block="code">
      <div class="chat-block-code-hd">
        ${cap ? html`<span class="chat-block-code-cap">${cap}</span>` : html`<span class="chat-block-code-cap" />`}
        <button
          type="button"
          class="chat-block-code-copy"
          aria-label="코드 복사"
          title="복사"
          onClick=${() => { void copyCodeToClipboard(plain) }}
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

function ChatAttachBlock({ name, dims, src, svg, ph, via, size }: { name: string; dims?: string; src?: string; svg?: string; ph?: string; via?: string; size?: string }) {
  return html`
    <figure class="chat-block-attach" data-chat-block="attach">
      <div class="chat-block-attach-hd">
        <span>◫</span>
        <span class="chat-block-attach-name">${name}</span>
        ${dims ? html`<span class="chat-block-attach-dims">${dims}</span>` : null}
      </div>
      <div class="chat-block-attach-frame">
        ${src
          ? html`<img src=${src} alt=${name} class="chat-block-attach-img" />`
          : svg
            ? html`<span dangerouslySetInnerHTML=${{ __html: sanitizeHtml(svg) }} />`
            : html`<div class="chat-block-attach-ph">${ph || '첨부 이미지'}</div>`}
      </div>
      <figcaption class="chat-block-attach-cap">
        <span>이미지 첨부</span>${via ? ` · ${via}` : ''}${size ? ` · ${size}` : ''}
      </figcaption>
    </figure>
  `
}

function ChatVoiceBlock(b: ChatVoiceBlock) {
  const secs = b.secs ?? 14
  const [playing, setPlaying] = useState(false)
  const [prog, setProg] = useState(0)

  useEffect(() => {
    if (!playing) return
    const start = performance.now() - prog * secs * 1000
    let raf = 0
    const tick = (now: number) => {
      const p = Math.min(1, (now - start) / (secs * 1000))
      setProg(p)
      if (p >= 1) {
        setPlaying(false)
        return
      }
      raf = requestAnimationFrame(tick)
    }
    raf = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(raf)
  }, [playing])

  const toggle = () => {
    if (prog >= 1) setProg(0)
    setPlaying((p) => !p)
  }

  const bars = b.wave ?? []
  const fmt = (s: number) => `${Math.floor(s / 60)}:${String(Math.round(s) % 60).padStart(2, '0')}`
  const shown = playing || prog > 0 ? prog * secs : secs

  return html`
    <div class="chat-block-voice" data-chat-block="voice">
      <div class="chat-block-voice-row">
        <button type="button" class="chat-block-voice-play ${playing ? 'on' : ''}" onClick=${toggle} aria-label=${playing ? '일시정지' : '재생'}>
          ${playing ? '❙❙' : '▶'}
        </button>
        <div class="chat-block-voice-wave">
          ${bars.map((h, i) => html`
            <span
              key=${i}
              class="chat-block-vbar ${(i + 0.5) / bars.length <= prog ? 'on' : ''}"
              style=${{ height: `${Math.round(5 + h * 21)}px` }}
            />
          `)}
        </div>
        <span class="chat-block-voice-dur">${fmt(shown)}</span>
      </div>
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
  return html`
    <figure class="chat-block-media" data-chat-block="image">
      <div class="chat-block-media-frame ${src ? 'cursor-zoom-in' : ''}" onClick=${() => src && setOpen(true)}>
        ${src
          ? html`<img src=${src} alt=${cap || ''} class="max-h-52 w-full rounded-[var(--r-1)] object-contain" />`
          : html`<div class="chat-block-media-ph">${ph || '실행 화면'}</div>`}
      </div>
      ${cap ? html`<figcaption class="chat-block-media-cap">${cap}</figcaption>` : null}
      ${open && src
        ? html`
            <${ChatPreviewModal} title=${cap || '이미지'} onClose=${() => setOpen(false)}>
              <img
                src=${src}
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
  const clean = useMemo(() => sanitizeSvg(svg), [svg])
  return html`
    <figure class="chat-block-media" data-chat-block="svg">
      <div
        class="chat-block-media-frame cursor-zoom-in"
        onClick=${() => setOpen(true)}
        dangerouslySetInnerHTML=${{ __html: clean }}
      />
      ${cap ? html`<figcaption class="chat-block-media-cap">${cap}</figcaption>` : null}
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
  const [svg, setSvg] = useState<string | null>(null)
  const [error, setError] = useState(false)

  useEffect(() => {
    let active = true
    const run = async () => {
      try {
        const mod = await import('mermaid')
        const mermaid = mod.default
        if (typeof mermaid.initialize === 'function') {
          mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: 'dark' })
        }
        const { svg: rendered } = await mermaid.render(`mermaid-${id}`, source)
        if (active) setSvg(rendered)
      } catch {
        if (active) setError(true)
      }
    }
    void run()
    return () => { active = false }
  }, [source, id])

  if (error) {
    return html`<${ChatCodeBlock} cap="mermaid" html=${escapeHtml(source)} source=${source} />`
  }

  return html`
    <figure class="chat-block-media" data-chat-block="mermaid">
      <div class="chat-block-mermaid">
        ${svg
          ? html`<div dangerouslySetInnerHTML=${{ __html: sanitizeSvg(svg) }} />`
          : html`<div class="chat-block-media-ph">다이어그램 렌더링 중…</div>`}
      </div>
      ${caption ? html`<figcaption class="chat-block-media-cap">${caption}</figcaption>` : null}
    </figure>
  `
}

function ChatTraceStep({ step }: { step: ChatTraceStep }) {
  const [open, setOpen] = useState(false)

  if (step.kind === 'think') {
    return html`
      <div class="chat-block-tstep think" data-chat-trace-step="think">
        <span class="chat-block-tnode"></span>
        <div class="min-w-0 flex-1">
          <div class="chat-block-tstep-row">
            <span class="chat-block-tstep-kind">Thinking</span>
            <span>${step.text}</span>
          </div>
        </div>
      </div>
    `
  }

  if (step.kind === 'reason') {
    const exp = !!step.detail
    return html`
      <div class="chat-block-tstep reason ${open ? 'exp' : ''}" data-chat-trace-step="reason">
        <span class="chat-block-tnode"></span>
        <div class="min-w-0 flex-1">
          <div class="chat-block-tstep-row ${exp ? 'click' : ''}" onClick=${() => { if (exp) setOpen((o) => !o) }}>
            <span class="chat-block-tstep-kind">Reasoning</span>
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

  return html`
    <div class="chat-block-tstep tool ${open ? 'exp' : ''}" data-chat-trace-step="tool">
      <span class="chat-block-tnode"></span>
      <div class="min-w-0 flex-1">
        <div class="chat-block-tstep-row click" onClick=${() => setOpen((o) => !o)}>
          <span class="chat-block-tstep-kind">Tool</span>
          <span class="chat-block-tstep-name">${step.name}</span>
          <span class="chat-block-tstep-status ${step.status === 'ok' ? 'ok' : 'bad'}"></span>
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

function ChatTraceBlock({ trace }: { trace: ChatTraceStep[] }) {
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
        <span class="chat-block-trace-meta">
          ${toolN > 0 ? html`<span>도구 ${toolN}</span>` : null}
          ${dur ? html`<span class="tnum">${dur}</span>` : null}
        </span>
      </button>
      ${open
        ? html`
            <div class="chat-block-trace-steps">
              <span class="chat-block-trace-rail"></span>
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
  return html`
    <a
      class="chat-block-linkcard ${b.kind || ''}"
      href=${b.url}
      target="_blank"
      rel="noopener noreferrer"
      data-chat-block="link"
    >
      <span class="chat-block-linkcard-fav">${b.fav || (host ? host.slice(0, 1).toUpperCase() : '↗')}</span>
      <span class="chat-block-linkcard-body">
        <span class="chat-block-linkcard-title">${b.title}</span>
        ${b.desc ? html`<span class="chat-block-linkcard-desc">${b.desc}</span>` : null}
        <span class="chat-block-linkcard-meta">${b.meta || host}</span>
      </span>
      <span class="chat-block-linkcard-go">↗</span>
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

function ChatBlock({ block }: { block: ChatBlock }) {
  switch (block.t) {
    case 'p': return html`<${ChatTextBlock} html=${block.html} />`
    case 'h4': return html`<${ChatHeadingBlock} html=${block.html} />`
    case 'ul': return html`<${ChatListBlock} items=${block.items} />`
    case 'callout': return html`<${ChatCalloutBlock} severity=${block.severity} html=${block.html} />`
    case 'table': return html`<${ChatTableBlock} head=${block.head} rows=${block.rows} />`
    case 'code': return html`<${ChatCodeBlock} cap=${block.cap} html=${block.html} source=${block.source} />`
    case 'shell': return html`<${ChatShellBlock} title=${block.title} lines=${block.lines} exit=${block.exit} dur=${block.dur} />`
    case 'artifact': return html`<${ChatArtifactBlock} kind=${block.kind} name=${block.name} size=${block.size} note=${block.note} data=${block.data} mimeType=${block.mimeType} />`
    case 'attach': return html`<${ChatAttachBlock} name=${block.name} dims=${block.dims} src=${block.src} svg=${block.svg} ph=${block.ph} via=${block.via} size=${block.size} />`
    case 'voice': return html`<${ChatVoiceBlock} secs=${block.secs} wave=${block.wave} via=${block.via} size=${block.size} transcript=${block.transcript} />`
    case 'image': return html`<${ChatImageBlock} src=${block.src} ph=${block.ph} cap=${block.cap} />`
    case 'svg': return html`<${ChatSvgBlock} svg=${block.svg} cap=${block.cap} />`
    case 'mermaid': return html`<${ChatMermaidBlock} source=${block.source} caption=${block.caption} />`
    case 'trace': return html`<${ChatTraceBlock} trace=${block.trace} />`
    case 'link': return html`<${ChatLinkBlock} url=${block.url} title=${block.title} desc=${block.desc} meta=${block.meta} fav=${block.fav} kind=${block.kind} />`
    case 'broadcast': return html`<${ChatBroadcastBlock} scope=${block.scope} via=${block.via} note=${block.note} recipients=${block.recipients} />`
    default: return null
  }
}

function ChatBlocks({ blocks }: { blocks: ChatBlock[] }) {
  return html`
    <div class="flex flex-col gap-3" data-chat-blocks>
      ${blocks.map((b, i) => html`<${ChatBlock} key=${i} block=${b} />`)}
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

function AttachmentCard({ attachment }: { attachment: KeeperConversationAttachment }) {
  const [open, setOpen] = useState(false)
  const canDownload = isSafeAttachmentHref(attachment)
  const meta = attachmentMeta(attachment)
  const isImage = isRenderableImageAttachment(attachment)

  return html`
    <div
      class="overflow-hidden rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)]"
      data-chat-attachment-card=${attachment.id}
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
        src=${clip.audioUrl ?? `/api/v1/voice/audio/${encodeURIComponent(clip.token)}`}
        aria-label=${clip.messageText || '음성 메시지'}
      />
      ${duration
        ? html`<span class="chat-audio-dur">${duration}</span>`
        : null}
      ${clip.deviceId
        ? html`<span class="chat-audio-device" title=${`device: ${clip.deviceId}`}>🔊</span>`
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
  const hasBlocks = entry.blocks && entry.blocks.length > 0
  const liveLabel = liveMessageLabel(entry)
  const messageText = liveLabel ? '' : entry.text || '(empty reply)'
  const messageLength = messageText.length
  const parsedBlocks = useMemo(() => {
    if (hasBlocks) return null
    if (entry.role !== 'assistant' && entry.role !== 'system') return null
    return parseMarkdownToBlocks(messageText)
  }, [hasBlocks, entry.role, messageText])
  const effectiveBlocks = entry.blocks && entry.blocks.length > 0 ? entry.blocks : (parsedBlocks ?? [])
  const hasEffectiveBlocks = effectiveBlocks.length > 0
  const collapseThreshold = 1200
  const isCollapsible = !hasEffectiveBlocks && messageLength > collapseThreshold
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
      class=${`chat-bubble ${tone} flex w-full flex-col backdrop-blur-sm ${
        isMessenger
          ? 'max-w-[82%] gap-2.5 rounded-[var(--radius-xl)] px-4 py-3.5'
          : 'max-w-[90%] gap-3 rounded-[var(--r-5)] px-4 py-3'
      }`}
      data-chat-variant=${variant}
    >
      <div class=${`flex justify-between gap-3 ${isMessenger ? 'items-center' : 'items-start'}`}>
        <div class=${`flex min-w-0 flex-1 gap-3 ${isMessenger ? 'items-center' : 'items-start'}`}>
          <div
            class=${`chat-avatar ${tone} flex shrink-0 items-center justify-center whitespace-nowrap text-xs font-bold uppercase tracking-[var(--track-caps)] ${
              isMessenger ? 'size-8 rounded-card' : 'size-10 rounded-[var(--r-1)]'
            }`}
          >
            ${avatarMonogram(entry)}
          </div>
          <div class="min-w-0 flex-1">
            ${isMessenger
              ? html`
                  <div class="flex flex-wrap items-center gap-x-2 gap-y-1">
                    <span class="truncate text-sm font-semibold text-[var(--color-fg-primary)]">
                      ${avatarLabel(entry)}
                    </span>
                    ${timestamp
                      ? html`<span class="text-2xs font-medium tabular-nums text-[var(--color-fg-secondary)]">${timestamp}</span>`
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
                    ${surfaceInfo && surfaceInfo.url !== '#'
                      ? html`
                          <a
                            href=${surfaceInfo.url}
                            target="_blank"
                            rel="noopener noreferrer"
                            class="inline-flex items-center gap-1 rounded-[var(--r-0)] border border-[var(--accent-20)] bg-[var(--accent-10)] px-2 py-0.5 text-2xs font-semibold text-[var(--color-accent-fg)] hover:bg-[var(--accent-20)] ${CHAT_FOCUS_RING}"
                            title=${surfaceInfo.label}
                          >
                            <span>${surfaceInfo.icon}</span>
                            <span>${surfaceInfo.label}</span>
                          </a>
                        `
                      : surfaceInfo
                      ? html`
                          <span
                            class="inline-flex items-center gap-1 rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2 py-0.5 text-2xs font-medium text-[var(--color-fg-secondary)]"
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
                      class=${`chat-role-chip ${tone} inline-flex items-center rounded-[var(--r-0)] px-2.5 py-1 text-2xs font-bold uppercase tracking-2`}
                    >
                      ${entry.label}
                    </span>
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
                    ${surfaceInfo && surfaceInfo.url !== '#'
                      ? html`
                          <a
                            href=${surfaceInfo.url}
                            target="_blank"
                            rel="noopener noreferrer"
                            class="inline-flex items-center gap-1 rounded-[var(--r-0)] border border-[var(--accent-20)] bg-[var(--accent-10)] px-2.5 py-1 text-2xs font-semibold text-[var(--color-accent-fg)] hover:bg-[var(--accent-20)] ${CHAT_FOCUS_RING}"
                            title=${surfaceInfo.label}
                          >
                            <span>${surfaceInfo.icon}</span>
                            <span>${surfaceInfo.label}</span>
                          </a>
                        `
                      : surfaceInfo
                      ? html`
                          <span
                            class="inline-flex items-center gap-1 rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-panel-alt)] px-2.5 py-1 text-2xs font-medium text-[var(--color-fg-secondary)]"
                            title=${surfaceInfo.label}
                          >
                            <span>${surfaceInfo.icon}</span>
                            <span>${surfaceInfo.label}</span>
                          </span>
                        `
                      : null}
                  </div>
                  <div class="mt-2 truncate text-sm font-bold text-[var(--color-fg-primary)]">
                    ${avatarLabel(entry)}
                  </div>
                `}
          </div>
        </div>
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
            ${hasEffectiveBlocks
              ? html`<${ChatBlocks} blocks=${effectiveBlocks} />`
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
      ${entry.error
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
              ${entry.details.skillPrimary
                ? html`
                    <div class="chat-detail-callout rounded-[var(--r-1)] border border-[var(--ok-border)] px-3 py-3">
                      <div class="text-2xs font-bold uppercase tracking-2 text-[var(--ok-fg)]">스킬 경로</div>
                      <div class="mt-1 text-sm font-bold text-[var(--ok-fg)]">${entry.details.skillPrimary}</div>
                      ${entry.details.skillReason
                        ? html`<div class="mt-1 text-sm leading-loose text-[var(--ok-fg)]">${entry.details.skillReason}</div>`
                        : null}
                    </div>
                  `
                : null}
              ${state.length > 0
                ? html`
                    <div class="flex flex-col gap-2">
                      <div class="text-2xs font-bold uppercase tracking-2 text-[var(--color-fg-secondary)]">상태 스냅샷</div>
                      <div class="grid grid-cols-[repeat(auto-fit,minmax(116px,1fr))] gap-2">
                        ${state.map(item => html`
                          <div class="rounded-[var(--r-1)] border border-[var(--color-accent-soft)] bg-[var(--accent-6)] px-3 py-2.5">
                            <div class="text-2xs font-bold uppercase tracking-2 text-[var(--color-accent-fg)]">${item.label}</div>
                            <div class="mt-1 text-sm leading-paragraph text-[var(--color-fg-primary)]">${item.value}</div>
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
        class="flex w-full items-center gap-2 px-3 py-2 text-left hover:bg-[var(--color-bg-hover)] transition-colors ${CHAT_FOCUS_RING}"
        onClick=${() => { setExpanded(!expanded) }}
        aria-expanded=${expanded}
      >
        <span class="inline-flex size-5 shrink-0 items-center justify-center rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-panel-alt)] text-2xs font-mono font-bold text-[var(--color-fg-secondary)]">T</span>
        <span class="font-mono text-sm font-semibold text-[var(--color-accent-fg)] truncate">${toolName}</span>
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

  useLayoutEffect(() => {
    const el = scrollerRef.current
    if (!el) return
    if (pinnedRef.current) {
      const snap = () => { el.scrollTop = el.scrollHeight }
      snap()
      requestAnimationFrame(snap)
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
                <div class="text-xs font-bold uppercase tracking-4 text-[var(--color-fg-secondary)]">직접 메시지 없음</div>
                <div class="mt-3 max-w-[34rem] text-base font-medium leading-airy text-[var(--color-fg-primary)]">${emptyText}</div>
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

interface VoiceDraft {
  secs: number
  size: string
  wave: number[]
  transcript: string
}

function fmtClock(secs: number): string {
  const m = Math.floor(secs / 60)
  const s = Math.floor(secs % 60)
  return `${m}:${String(s).padStart(2, '0')}`
}

function escapeHtml(raw: string): string {
  return raw.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}

function randomWave(n: number): number[] {
  return Array.from({ length: n }, () => 0.22 + Math.random() * 0.74)
}

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

function VoiceDraftChip({
  draft,
  onRemove,
}: {
  draft: VoiceDraft
  onRemove: () => void
}) {
  return html`
    <div class="cdraft voice" data-chat-voice-draft>
      <span class="cdraft-glyph mic">◌</span>
      <div class="cdraft-wave">
        ${draft.wave.map((h, i) => html`<span key=${i} class="vbar on" style=${{ height: `${Math.round(4 + h * 18)}px` }}></span>`)}
      </div>
      <span class="cdraft-dur mono">${fmtClock(draft.secs)}</span>
      <div class="cdraft-tx">
        <span class="cdraft-tx-k">받아쓰기</span>
        <span class="cdraft-tx-v">${draft.transcript}</span>
      </div>
      <button type="button" class="cdraft-x" title="음성 제거" aria-label="음성 제거" onClick=${onRemove}>✕</button>
    </div>
  `
}

function RecordBar({
  secs,
  wave,
  onStop,
  onCancel,
}: {
  secs: number
  wave: number[]
  onStop: () => void
  onCancel: () => void
}) {
  return html`
    <div class="rec-bar" data-chat-record-bar>
      <span class="rec-dot"></span>
      <span class="rec-lbl">녹음 중</span>
      <span class="rec-clock mono">${fmtClock(secs)}</span>
      <div class="rec-wave">
        ${wave.map((h, i) => html`<span key=${i} class="rbar" style=${{ height: `${Math.round(3 + h * 20)}px` }}></span>`)}
      </div>
      <button type="button" class="rec-btn cancel" title="취소" onClick=${onCancel}>취소</button>
      <button type="button" class="rec-btn stop" title="녹음 종료 — 받아쓰기" onClick=${onStop}>■ 완료</button>
    </div>
  `
}

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
  onSend: (payload: { blocks: ChatBlock[] }) => void | Promise<void>
  onAbort?: () => void
  layout?: 'default' | 'primary'
}) {
  const [elapsed, setElapsed] = useState(0)
  const [focus, setFocus] = useState(false)
  const [drag, setDrag] = useState(false)
  const [attachments, setAttachments] = useState<KeeperConversationAttachment[]>([])
  const [voiceDraft, setVoiceDraft] = useState<VoiceDraft | null>(null)
  const [recording, setRecording] = useState(false)
  const [recSecs, setRecSecs] = useState(0)
  const [recWave, setRecWave] = useState<number[]>([])
  const fileInputRef = useRef<HTMLInputElement | null>(null)
  const textareaRef = useRef<HTMLTextAreaElement | null>(null)
  const recIntervalRef = useRef<number | null>(null)

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

  useEffect(() => {
    if (!recording) {
      if (recIntervalRef.current) {
        clearInterval(recIntervalRef.current)
        recIntervalRef.current = null
      }
      return
    }
    const t0 = performance.now()
    const id = window.setInterval(() => {
      const s = (performance.now() - t0) / 1000
      setRecSecs(s)
      setRecWave((prev) => [...prev.slice(-46), 0.2 + Math.random() * 0.78])
    }, 110)
    recIntervalRef.current = id
    return () => {
      clearInterval(id)
      recIntervalRef.current = null
    }
  }, [recording])

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
    : '볂이기'
  const isStreamWarning = streaming && elapsed > 60
  const hasContent = draft.trim() !== '' || attachments.length > 0 || voiceDraft !== null
  const sendDisabled = disabled || !hasContent || (streaming && !queueEnabled)

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

  const startRecording = () => {
    setRecording(true)
    setRecSecs(0)
    setRecWave([])
  }

  const stopRecording = () => {
    const secs = Math.max(1, recSecs)
    const n = Math.min(40, Math.max(14, Math.round(secs * 2.2)))
    setRecording(false)
    setVoiceDraft({
      secs,
      size: formatAttachmentSize(Math.round(secs * 3400)),
      wave: randomWave(n),
      transcript: '스케줄러 p99 스파이크 건, compact 도는 타이밍이랑 겹치는지 확인하고 결과만 알려줘.',
    })
  }

  const cancelRecording = () => {
    setRecording(false)
    setVoiceDraft(null)
  }

  const handleSend = () => {
    if (sendDisabled) return
    const blocks: ChatBlock[] = []
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
    }
    if (voiceDraft) {
      blocks.push({
        t: 'voice',
        secs: Math.round(voiceDraft.secs),
        wave: voiceDraft.wave,
        size: voiceDraft.size,
        via: '음성 입력 · 받아쓰기',
        transcript: voiceDraft.transcript,
      } as ChatBlock)
    }
    const text = draft.trim()
    if (text) {
      blocks.push({ t: 'p', html: escapeHtml(text) } as ChatBlock)
    }
    void onSend({ blocks })
    onDraftChange('')
    setAttachments([])
    setVoiceDraft(null)
    if (textareaRef.current) textareaRef.current.style.height = 'auto'
  }

  const grow = (event: Event) => {
    const target = event.target as HTMLTextAreaElement
    onDraftChange(target.value)
    target.style.height = 'auto'
    target.style.height = `${Math.min(target.scrollHeight, 160)}px`
  }

  const onKeyDown = (event: KeyboardEvent) => {
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
                ${voiceDraft ? html`<${VoiceDraftChip} draft=${voiceDraft} onRemove=${() => setVoiceDraft(null)} />` : null}
              </div>
            `
          : null}
        <div class=${boxClass}>
          ${recording
            ? html`<${RecordBar}
                secs=${recSecs}
                wave=${recWave}
                onStop=${stopRecording}
                onCancel=${cancelRecording}
              />`
            : html`
                <textarea
                  ref=${textareaRef}
                  class=${(isPrimary
                    ? 'control-textarea min-h-30 rounded-[var(--r-2)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)] px-4 py-4 text-base leading-loose'
                    : 'control-textarea min-h-24 rounded-card border border-[var(--color-border-default)] bg-[var(--color-bg-panel-alt)] px-3 py-3 text-base leading-loose') + ` ${CHAT_FOCUS_RING}`}
                  placeholder=${placeholder}
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
                    accept="image/png,image/jpeg,image/gif,image/webp,text/plain,text/markdown,application/json,text/csv"
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
                  <button
                    type="button"
                    class="ctool"
                    title="음성 입력 — 받아쓰기로 메시지 작성"
                    aria-label="음성 입력"
                    disabled=${disabled}
                    onClick=${startRecording}
                  >
                    🎤
                  </button>
                  <button
                    type="button"
                    class="send ${isStreamWarning && !canQueue ? 'warn' : ''}"
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
        <div class="composer-foot">
          <span class="hint">
            <kbd>⌘</kbd> <kbd>↵</kbd> 전송 · 끌어다 놓아 첨부
            ${isStalled
              ? html`<span class="ml-2 text-[var(--color-status-warn)]" data-chat-stall-hint>마지막 수신 ${sinceLastEvent}초 전 — 스트림 지연</span>`
              : null}
          </span>
          ${queueCount > 0
            ? html`<span class="queue-badge" data-chat-queue-count>대기 ${queueCount}</span>`
            : null}
        </div>
      </div>
    </div>
  `
}
