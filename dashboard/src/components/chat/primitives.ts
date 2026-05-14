import { html } from 'htm/preact'
import { JsonViewerCard } from '../common/json-viewer'
import { useEffect, useMemo, useRef, useState } from 'preact/hooks'
import { ActionButton } from '../common/button'
import { formatTimeHms } from '../../lib/format-time'
import { formatCost } from '../../lib/format-number'
import type { KeeperConversationDetails, KeeperConversationEntry } from '../../types'

type ChatTranscriptVariant = 'default' | 'messenger'

function timeLabel(timestamp?: string | null): string | null {
  if (!timestamp) return null
  const value = new Date(timestamp)
  if (Number.isNaN(value.getTime())) return null
  return formatTimeHms(value.getTime() / 1000)
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
  const expanded = showMetadata && expandedRaw
  const rawExpanded = showMetadata && rawExpandedRaw
  const tone = bubbleTone(entry)
  const isMessenger = variant === 'messenger'
  const detailItems = detailSummary(entry.details)
  const canExpand = showMetadata && !!entry.details
  const overview = entry.details ? overviewRows(entry.details) : []
  const state = stateRows(entry.details?.stateBlock)
  const delivery = deliveryLabel(entry)
  const timestamp = timeLabel(entry.timestamp)

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

      <div class="whitespace-pre-wrap break-words text-base leading-airy text-[var(--color-fg-primary)]">
        ${entry.text || (entry.delivery === 'streaming' ? '' : '(empty reply)')}
      </div>
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

export function ChatTranscript({
  entries,
  emptyText,
  showMetadata,
  variant = 'default',
}: {
  entries: KeeperConversationEntry[]
  emptyText: string
  showMetadata?: boolean
  variant?: ChatTranscriptVariant
}) {
  const scrollerRef = useRef<HTMLDivElement | null>(null)
  const lastSignature = useMemo(
    () => entries.map(entry => `${entry.id}:${entry.text.length}:${entry.delivery}`).join('|'),
    [entries],
  )

  useEffect(() => {
    const el = scrollerRef.current
    if (!el) return
    el.scrollTop = el.scrollHeight
  }, [lastSignature])

  return html`
    <div
      class=${`chat-transcript flex min-h-75 max-h-130 flex-col overflow-y-auto border border-[var(--color-border-default)] shadow-[inset_0_1px_0_var(--color-border-default)] ${
        variant === 'messenger'
          ? 'gap-4 rounded-[var(--radius-xl)] px-4 py-5 sm:px-5'
          : 'gap-3 rounded-[var(--radius-xl)] px-3 py-4'
      }`}
      data-chat-variant=${variant}
      ref=${scrollerRef}
    >
      ${entries.length === 0
        ? html`
            <div class="flex min-h-55 flex-col items-center justify-center rounded-card border border-dashed border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-6 text-center">
              <div class="text-2xs font-semibold uppercase tracking-5 text-[var(--color-fg-muted)]">직접 메시지 없음</div>
              <div class="mt-3 max-w-[34rem] text-sm leading-airy text-[var(--color-fg-secondary)]">${emptyText}</div>
            </div>
          `
        : entries.map(entry => html`<${ChatMessageBubble} key=${entry.id} entry=${entry} showMetadata=${showMetadata !== false} variant=${variant} />`)}
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
    ? `응답 중${elapsed > 0 ? ` ${elapsed}s` : ''}`
    : '보내기'
  const isStreamWarning = streaming && elapsed > 60

  return html`
    <div class="chat-composer flex flex-col gap-3">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <div class="text-2xs font-semibold uppercase tracking-4 text-[var(--color-fg-muted)]">메시지</div>
        <div class="text-2xs text-[var(--color-fg-muted)]">Enter로 전송, Shift+Enter로 줄바꿈</div>
      </div>
      <textarea
        class="control-textarea min-h-24 rounded-card border border-[var(--color-border-default)] bg-[var(--color-bg-panel-alt)] px-3 py-3 text-base leading-loose"
        placeholder=${placeholder}
        aria-label="메시지 입력"
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
        <div class="text-2xs leading-paragraph text-[var(--color-fg-muted)]">
          ${streaming
            ? '키퍼 응답 스트림이 활성 상태입니다. 멈춘 것 같으면 중지할 수 있습니다.'
            : '직접 메시지만 이 레인에 표시됩니다. 내부 키퍼 프롬프트는 숨겨집니다.'}
        </div>
        <div class="flex gap-2 items-center">
        <${ActionButton}
          variant=${isStreamWarning ? 'danger' : 'primary'}
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
