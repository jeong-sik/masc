import { html } from 'htm/preact'
import { useMemo } from 'preact/hooks'
import { ArrowLeft, Braces } from 'lucide-preact'
import { ActionButton } from '../common/button'
import { EmptyState } from '../common/empty-state'
import { RichContent } from '../common/rich-content'
import { TimeAgo } from '../common/time-ago'
import { stripStateBlocks } from '../../keeper-message'
import { navigate } from '../../router'
import { messages } from '../../store'
import type { Message } from '../../types'

interface StateBlockRow {
  message: Message
  stateBlock: string
  fields: StateBlockField[]
  index: number
  timestampMs: number | null
}

interface StateBlockField {
  label: string
  value: string
}

const STATE_BLOCK_RE = /\[STATE\]([\s\S]*?)\[\/STATE\]/g

export function extractStateBlocks(content: string): string[] {
  const blocks: string[] = []
  for (const match of content.matchAll(STATE_BLOCK_RE)) {
    const block = match[1]?.trim()
    if (block) blocks.push(block)
  }
  return blocks
}

export function stateBlockFields(block: string): StateBlockField[] {
  return block
    .split('\n')
    .map(line => line.trim())
    .filter(Boolean)
    .map(line => {
      const separator = line.indexOf(':')
      if (separator <= 0) return null
      const label = line.slice(0, separator).trim()
      const value = line.slice(separator + 1).trim()
      return label && value ? { label, value } : null
    })
    .filter((row): row is StateBlockField => row !== null)
}

function messageTimestampMs(message: Message): number | null {
  if (!message.timestamp) return null
  const parsed = Date.parse(message.timestamp)
  return Number.isFinite(parsed) ? parsed : null
}

export function buildStateBlockRows(messageList: readonly Message[]): StateBlockRow[] {
  return messageList
    .flatMap((message, index): StateBlockRow[] => {
      const stateBlocks = extractStateBlocks(message.content)
      if (stateBlocks.length === 0) return []
      return stateBlocks.map(stateBlock => ({
        message,
        stateBlock,
        fields: stateBlockFields(stateBlock),
        index,
        timestampMs: messageTimestampMs(message),
      }))
    })
    .sort((left, right) => {
      if (left.timestampMs !== null && right.timestampMs !== null && left.timestampMs !== right.timestampMs) {
        return right.timestampMs - left.timestampMs
      }
      if (left.message.seq !== undefined && right.message.seq !== undefined && left.message.seq !== right.message.seq) {
        return right.message.seq - left.message.seq
      }
      return right.index - left.index
    })
}

function previewContent(message: Message): string {
  return stripStateBlocks(message.content).trim() || '(state-only message)'
}

function rowKey(row: StateBlockRow): string {
  return `${row.message.id ?? row.message.seq ?? row.index}-${row.stateBlock.slice(0, 24)}`
}

function StateRow({ row }: { row: StateBlockRow }) {
  return html`
    <article
      role="listitem"
      class="rounded-[var(--r-1)] border border-[var(--color-border-default)] border-l-[3px] border-l-[var(--warn-bright)] bg-[var(--color-bg-surface)] px-3.5 py-3"
    >
      <div class="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1">
        ${row.message.seq !== undefined
          ? html`<span class="text-3xs font-semibold tabular-nums uppercase tracking-[var(--track-caps)] text-[var(--warn-bright)]">#${row.message.seq}</span>`
          : null}
        <span class="text-xs font-semibold text-[var(--color-fg-secondary)]">${row.message.from ?? 'system'}</span>
        ${row.message.timestamp
          ? html`<span class="text-2xs tabular-nums text-[var(--color-fg-muted)]"><${TimeAgo} timestamp=${row.message.timestamp} /></span>`
          : null}
        ${row.message.type
          ? html`<span class="rounded-[var(--r-0)] border border-[var(--color-border-default)] px-2 py-0.5 text-3xs font-medium uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">${row.message.type}</span>`
          : null}
      </div>

      <div class="mt-2 text-sm leading-paragraph text-[var(--color-fg-primary)]">
        <${RichContent} text=${previewContent(row.message)} previewLimit=${2} />
      </div>

      <div
        class="mt-3 rounded-[var(--r-1)] border border-[var(--color-accent-soft)] bg-[var(--accent-10)] px-3 py-3"
        aria-label="State block"
      >
        <div class="mb-2 flex items-center gap-2 text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-accent-fg)]">
          <${Braces} size=${13} aria-hidden="true" />
          STATE
        </div>
        ${row.fields.length > 0
          ? html`
              <dl class="grid gap-2 sm:grid-cols-2">
                ${row.fields.map(field => html`
                  <div class="min-w-0 rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2.5 py-2" key=${field.label}>
                    <dt class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">${field.label}</dt>
                    <dd class="mt-1 text-xs leading-paragraph text-[var(--color-fg-secondary)]">${field.value}</dd>
                  </div>
                `)}
              </dl>
            `
          : html`<pre class="whitespace-pre-wrap break-words text-xs leading-paragraph text-[var(--color-fg-secondary)]">${row.stateBlock}</pre>`}
      </div>
    </article>
  `
}

export function StateBlockMessages() {
  const rows = useMemo(() => buildStateBlockRows(messages.value), [messages.value])
  const sourceCount = new Set(rows.map(row => row.message.from ?? 'system')).size

  return html`
    <section class="grid gap-4" aria-labelledby="state-block-messages-heading">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">Messages</div>
          <h2 id="state-block-messages-heading" class="mt-1 text-xl font-semibold text-[var(--color-fg-primary)]">State-block messages</h2>
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
          <div class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">State blocks</div>
          <div class="mt-1 text-lg font-semibold tabular-nums text-[var(--color-fg-primary)]">${rows.length}</div>
        </div>
        <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2">
          <div class="text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">Sources</div>
          <div class="mt-1 text-lg font-semibold tabular-nums text-[var(--color-fg-primary)]">${sourceCount}</div>
        </div>
      </div>

      ${rows.length === 0
        ? html`<${EmptyState} message="state block 메시지가 없습니다" compact />`
        : html`<div role="list" aria-label=${`${rows.length} state messages`} class="grid gap-2.5">${rows.map(row => html`<${StateRow} key=${rowKey(row)} row=${row} />`)}</div>`}
    </section>
  `
}
