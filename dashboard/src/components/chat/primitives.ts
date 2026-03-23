import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import { ActionButton } from '../common/button'
import type { KeeperConversationDetails, KeeperConversationEntry } from '../../types'

function timeLabel(timestamp?: string | null): string | null {
  if (!timestamp) return null
  const value = new Date(timestamp)
  if (Number.isNaN(value.getTime())) return null
  return value.toLocaleTimeString()
}

function deliveryLabel(entry: KeeperConversationEntry): string {
  switch (entry.delivery) {
    case 'sending':
      return 'sending'
    case 'streaming':
      return entry.streamState === 'finalizing' ? 'finalizing' : 'live'
    case 'timeout':
      return 'timeout'
    case 'error':
      return 'error'
    case 'history':
      return 'saved'
    default:
      return 'delivered'
  }
}

function bubbleTone(entry: KeeperConversationEntry): string {
  if (entry.delivery === 'error' || entry.delivery === 'timeout') return 'error'
  if (entry.role === 'user') return 'user'
  if (entry.role === 'assistant') return 'assistant'
  return 'system'
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
    details.modelUsed ?? null,
    typeof details.latencyMs === 'number' ? `${details.latencyMs} ms` : null,
    tokenSummary(details),
  ].filter((value): value is string => Boolean(value))
}

function formatCurrency(value?: number | null): string | null {
  if (typeof value !== 'number' || !Number.isFinite(value)) return null
  if (value === 0) return '$0.00'
  if (value < 0.01) return `$${value.toFixed(4)}`
  return `$${value.toFixed(2)}`
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
    details.modelUsed ? { label: '모델', value: details.modelUsed } : null,
    typeof details.latencyMs === 'number' ? { label: '지연', value: `${details.latencyMs} ms` } : null,
    typeof details.usage?.totalTokens === 'number' ? { label: '토큰', value: `${details.usage.totalTokens}` } : null,
    formatCurrency(details.costUsd) ? { label: '비용', value: formatCurrency(details.costUsd)! } : null,
    details.traceId ? { label: '트레이스', value: details.traceId } : null,
    typeof details.generation === 'number' ? { label: '세대', value: `${details.generation}` } : null,
  ].filter((row): row is { label: string; value: string } => Boolean(row))
}

export function ChatMessageBubble({
  entry,
  showMetadata = true,
}: {
  entry: KeeperConversationEntry
  showMetadata?: boolean
}) {
  const [expanded, setExpanded] = useState(false)
  const [rawExpanded, setRawExpanded] = useState(false)
  const detailItems = detailSummary(entry.details)
  const canExpand = showMetadata && !!entry.details
  const overview = entry.details ? overviewRows(entry.details) : []
  const state = stateRows(entry.details?.stateBlock)

  useEffect(() => {
    if (!showMetadata) {
      setExpanded(false)
      setRawExpanded(false)
    }
  }, [showMetadata])

  return html`
    <article
      class=${`chat-bubble ${bubbleTone(entry)} flex w-full max-w-[90%] flex-col gap-3 rounded-[20px] border px-4 py-3 backdrop-blur-sm`}
    >
      <div class="flex items-start justify-between gap-3">
        <div class="flex min-w-0 flex-1 items-start gap-3">
          <div
            class=${`chat-avatar ${bubbleTone(entry)} flex size-10 shrink-0 items-center justify-center rounded-2xl border text-[11px] font-semibold uppercase tracking-[0.08em]`}
          >
            ${avatarMonogram(entry)}
          </div>
          <div class="min-w-0 flex-1">
            <div class="flex flex-wrap items-center gap-1.5">
              <span
                class=${`chat-role-chip ${bubbleTone(entry)} inline-flex items-center rounded-full border px-2.5 py-1 text-[10px] font-semibold uppercase tracking-[0.12em]`}
              >
                ${entry.label}
              </span>
              <span class="inline-flex items-center rounded-full border border-[var(--card-border)] bg-[rgba(255,255,255,0.04)] px-2.5 py-1 text-[10px] font-medium uppercase tracking-[0.1em] text-[var(--text-muted)]">
                ${deliveryLabel(entry)}
              </span>
              ${entry.timestamp
                ? html`
                    <span class="inline-flex items-center rounded-full border border-[rgba(148,163,184,0.16)] bg-[rgba(148,163,184,0.08)] px-2.5 py-1 text-[10px] font-medium tabular-nums text-[var(--text-muted)]">
                      ${timeLabel(entry.timestamp)}
                    </span>
                  `
                : null}
            </div>
            <div class="mt-2 truncate text-[13px] font-semibold text-[var(--text-strong)]">
              ${avatarLabel(entry)}
            </div>
          </div>
        </div>
        ${canExpand
          ? html`
              <button
                type="button"
                class="rounded-full border border-[var(--card-border)] bg-[rgba(255,255,255,0.04)] px-3 py-1 text-[11px] font-medium text-[var(--text-muted)] transition-colors hover:bg-[rgba(255,255,255,0.08)] hover:text-[var(--text-body)]"
                onClick=${() => { setExpanded(!expanded) }}
              >
                ${expanded ? '상세 숨기기' : '상세 보기'}
              </button>
            `
          : null}
      </div>

      ${showMetadata && detailItems.length > 0
        ? html`<div class="flex flex-wrap gap-1.5">
            ${detailItems.map(item => html`
              <span class="inline-flex items-center rounded-full border border-[rgba(71,184,255,0.16)] bg-[rgba(71,184,255,0.08)] px-2.5 py-1 text-[10px] font-medium text-[#bfe8ff]">
                ${item}
              </span>
            `)}
          </div>`
        : null}

      <div class="whitespace-pre-wrap break-words text-[14px] leading-[1.7] text-[var(--text-body)]">
        ${entry.text || (entry.delivery === 'streaming' ? '…' : '(empty reply)')}
      </div>
      ${entry.error
        ? html`
            <div class="rounded-2xl border border-[rgba(239,68,68,0.24)] bg-[rgba(127,29,29,0.28)] px-3 py-2 text-[12px] leading-[1.55] text-[#ffb4b4]">
              ${entry.error}
            </div>
          `
        : null}

      ${expanded && entry.details
        ? html`
            <div class="chat-detail-panel rounded-[18px] border border-[rgba(148,163,184,0.14)] px-3 py-3">
              ${overview.length > 0
                ? html`
                    <div class="grid grid-cols-[repeat(auto-fit,minmax(116px,1fr))] gap-2">
                      ${overview.map(item => html`
                        <div class="rounded-2xl border border-[rgba(148,163,184,0.12)] bg-[rgba(255,255,255,0.03)] px-3 py-2.5">
                          <div class="text-[10px] font-semibold uppercase tracking-[0.12em] text-[var(--text-muted)]">${item.label}</div>
                          <div class="mt-1 text-[13px] font-semibold text-[var(--text-strong)]">${item.value}</div>
                        </div>
                      `)}
                    </div>
                  `
                : null}
              ${entry.details.skillPrimary
                ? html`
                    <div class="chat-detail-callout rounded-2xl border border-[rgba(76,181,137,0.18)] px-3 py-3">
                      <div class="text-[10px] font-semibold uppercase tracking-[0.12em] text-[#8fdcb3]">스킬 경로</div>
                      <div class="mt-1 text-[13px] font-semibold text-[#d8f7e6]">${entry.details.skillPrimary}</div>
                      ${entry.details.skillReason
                        ? html`<div class="mt-1 text-[12px] leading-[1.6] text-[#bfe8cf]">${entry.details.skillReason}</div>`
                        : null}
                    </div>
                  `
                : null}
              ${state.length > 0
                ? html`
                    <div class="flex flex-col gap-2">
                      <div class="text-[10px] font-semibold uppercase tracking-[0.12em] text-[var(--text-muted)]">상태 스냅샷</div>
                      <div class="grid grid-cols-[repeat(auto-fit,minmax(116px,1fr))] gap-2">
                        ${state.map(item => html`
                          <div class="rounded-2xl border border-[rgba(71,184,255,0.14)] bg-[rgba(71,184,255,0.06)] px-3 py-2.5">
                            <div class="text-[10px] font-semibold uppercase tracking-[0.1em] text-[#9ad9ff]">${item.label}</div>
                            <div class="mt-1 text-[12px] leading-[1.55] text-[var(--text-body)]">${item.value}</div>
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
                        class="self-start rounded-full border border-[var(--card-border)] bg-[rgba(255,255,255,0.04)] px-3 py-1 text-[11px] font-medium text-[var(--text-muted)] transition-colors hover:bg-[rgba(255,255,255,0.08)] hover:text-[var(--text-body)]"
                        onClick=${() => { setRawExpanded(!rawExpanded) }}
                      >
                        ${rawExpanded ? '원본 숨기기' : '원본 보기'}
                      </button>
                      ${rawExpanded
                        ? html`<pre class="rounded-2xl border border-[rgba(148,163,184,0.12)] bg-[rgba(2,10,24,0.84)] px-3 py-3">${JSON.stringify(entry.details.rawPayload, null, 2)}</pre>`
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

export function ChatTranscript({
  entries,
  emptyText,
  showMetadata,
}: {
  entries: KeeperConversationEntry[]
  emptyText: string
  showMetadata?: boolean
}) {
  const scrollerRef = useRef<HTMLDivElement | null>(null)
  const lastSignature = entries.map(entry => `${entry.id}:${entry.text.length}:${entry.delivery}`).join('|')

  useEffect(() => {
    const el = scrollerRef.current
    if (!el) return
    el.scrollTop = el.scrollHeight
  }, [lastSignature])

  return html`
    <div
      class="chat-transcript flex min-h-[300px] max-h-[520px] flex-col gap-3 overflow-y-auto rounded-[22px] border border-[rgba(148,163,184,0.14)] px-3 py-4 shadow-[inset_0_1px_0_rgba(255,255,255,0.03)]"
      ref=${scrollerRef}
    >
      ${entries.length === 0
        ? html`
            <div class="flex min-h-[220px] flex-col items-center justify-center rounded-[18px] border border-dashed border-[rgba(148,163,184,0.18)] bg-[rgba(255,255,255,0.03)] px-6 text-center">
              <div class="text-[11px] font-semibold uppercase tracking-[0.16em] text-[var(--text-muted)]">No Direct Messages</div>
              <div class="mt-3 max-w-[34rem] text-[13px] leading-[1.7] text-[var(--text-secondary)]">${emptyText}</div>
            </div>
          `
        : entries.map(entry => html`<${ChatMessageBubble} key=${entry.id} entry=${entry} showMetadata=${showMetadata !== false} />`)}
    </div>
  `
}

export function ChatComposer({
  draft,
  placeholder,
  disabled,
  streaming,
  streamStartedAt,
  onDraftChange,
  onSend,
  onAbort,
}: {
  draft: string
  placeholder: string
  disabled: boolean
  streaming: boolean
  streamStartedAt?: number | null
  onDraftChange: (value: string) => void
  onSend: () => void
  onAbort?: () => void
}) {
  const [elapsed, setElapsed] = useState(0)

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

  const streamLabel = streaming
    ? `응답 중${elapsed > 0 ? ` ${elapsed}s` : '...'}`
    : '보내기'
  const warnClass = streaming && elapsed > 60 ? ' chat-stream-warning' : ''

  return html`
    <div class="chat-composer flex flex-col gap-3">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <div class="text-[11px] font-semibold uppercase tracking-[0.14em] text-[var(--text-muted)]">Message</div>
        <div class="text-[11px] text-[var(--text-muted)]">Enter to send, Shift+Enter for newline</div>
      </div>
      <textarea
        class="control-textarea min-h-[96px] rounded-[18px] border border-[rgba(148,163,184,0.16)] bg-[rgba(255,255,255,0.04)] px-3 py-3 text-[14px] leading-[1.6]"
        placeholder=${placeholder}
        value=${draft}
        onInput=${(event: Event) => { onDraftChange((event.target as HTMLTextAreaElement).value) }}
        onKeyDown=${(event: KeyboardEvent) => {
          if (event.key === 'Enter' && !event.shiftKey) {
            event.preventDefault()
            if (!disabled && !streaming && draft.trim() !== '') {
              onSend()
            }
          }
        }}
        disabled=${disabled}
      ></textarea>
      <div class="flex flex-wrap items-center justify-between gap-2">
        <div class="text-[11px] leading-[1.55] text-[var(--text-muted)]">
          ${streaming
            ? 'Keeper reply stream is active. You can stop it if the run looks stuck.'
            : 'Direct messages are kept in this lane. Internal keeper prompts stay hidden.'}
        </div>
        <div class="flex gap-2 items-center">
        <${ActionButton}
          variant=${warnClass ? 'danger' : 'primary'}
          onClick=${onSend}
          disabled=${disabled || streaming || draft.trim() === ''}
        >
          ${streamLabel}
        <//>
        ${streaming && onAbort
          ? html`
              <${ActionButton}
                variant="ghost"
                onClick=${onAbort}
              >
                중지
              <//>
            `
          : null}
        </div>
      </div>
    </div>
  `
}
