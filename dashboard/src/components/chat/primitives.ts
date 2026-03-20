import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
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
      return entry.streamState === 'finalizing' ? 'finalizing' : 'streaming'
    case 'timeout':
      return 'timeout'
    case 'error':
      return 'error'
    case 'history':
      return entry.role
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
    <article class=${`chat-bubble ${bubbleTone(entry)}`}>
      <div class="chat-bubble-head">
        <div class="chat-bubble-identity">
          <div class=${`chat-avatar ${bubbleTone(entry)}`}>${avatarMonogram(entry)}</div>
          <div class="chat-bubble-identity-copy">
            <div class="chat-bubble-labels">
              <span class=${`chat-role-chip ${bubbleTone(entry)}`}>${entry.label}</span>
              <span class="chat-delivery-chip">${deliveryLabel(entry)}</span>
              ${entry.timestamp ? html`<span class="chat-time-chip">${timeLabel(entry.timestamp)}</span>` : null}
            </div>
            <div class="chat-identity-title">${avatarLabel(entry)}</div>
          </div>
        </div>
        ${canExpand
          ? html`
              <button
                type="button"
                class="chat-disclosure-btn"
                onClick=${() => { setExpanded(!expanded) }}
              >
                ${expanded ? '상세 숨기기' : '상세 보기'}
              </button>
            `
          : null}
      </div>

      ${showMetadata && detailItems.length > 0
        ? html`<div class="chat-detail-chip-row">
            ${detailItems.map(item => html`<span class="chat-detail-chip">${item}</span>`)}
          </div>`
        : null}

      <div class="chat-bubble-body">${entry.text || (entry.delivery === 'streaming' ? '…' : '(empty reply)')}</div>
      ${entry.error ? html`<div class="chat-bubble-error">${entry.error}</div>` : null}

      ${expanded && entry.details
        ? html`
            <div class="chat-detail-panel">
              ${overview.length > 0
                ? html`
                    <div class="chat-overview-grid">
                      ${overview.map(item => html`
                        <div class="chat-overview-card">
                          <div class="chat-overview-label">${item.label}</div>
                          <div class="chat-overview-value">${item.value}</div>
                        </div>
                      `)}
                    </div>
                  `
                : null}
              ${entry.details.skillPrimary
                ? html`
                    <div class="chat-detail-callout">
                      <div class="chat-detail-callout-label">스킬 경로</div>
                      <div class="chat-detail-callout-value">${entry.details.skillPrimary}</div>
                      ${entry.details.skillReason
                        ? html`<div class="chat-detail-callout-copy">${entry.details.skillReason}</div>`
                        : null}
                    </div>
                  `
                : null}
              ${state.length > 0
                ? html`
                    <div class="chat-detail-section">
                      <div class="chat-detail-section-title">상태 스냅샷</div>
                      <div class="chat-state-grid">
                        ${state.map(item => html`
                          <div class="chat-state-card">
                            <div class="chat-state-label">${item.label}</div>
                            <div class="chat-state-value">${item.value}</div>
                          </div>
                        `)}
                      </div>
                    </div>
                  `
                : null}
              ${entry.details.rawPayload
                ? html`
                    <div class="chat-detail-section">
                      <button
                        type="button"
                        class="chat-raw-toggle"
                        onClick=${() => { setRawExpanded(!rawExpanded) }}
                      >
                        ${rawExpanded ? '원본 숨기기' : '원본 보기'}
                      </button>
                      ${rawExpanded
                        ? html`<pre>${JSON.stringify(entry.details.rawPayload, null, 2)}</pre>`
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
    <div class="chat-transcript" ref=${scrollerRef}>
      ${entries.length === 0
        ? html`<div class="chat-empty-copy">${emptyText}</div>`
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
    ? `Streaming${elapsed > 0 ? ` ${elapsed}s` : '...'}`
    : '전송'
  const warnClass = streaming && elapsed > 60 ? ' chat-stream-warning' : ''

  return html`
    <div class="chat-composer">
      <textarea
        class="control-textarea chat-composer-input"
        placeholder=${placeholder}
        value=${draft}
        onInput=${(event: Event) => { onDraftChange((event.target as HTMLTextAreaElement).value) }}
        disabled=${disabled}
      ></textarea>
      <div class="chat-composer-actions">
        <button
          type="button"
          class="control-btn${warnClass}"
          onClick=${onSend}
          disabled=${disabled || streaming || draft.trim() === ''}
        >
          ${streamLabel}
        </button>
        ${streaming && onAbort
          ? html`
              <button
                type="button"
                class="control-btn ghost"
                onClick=${onAbort}
              >
                중지
              </button>
            `
          : null}
      </div>
    </div>
  `
}
