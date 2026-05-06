import { html } from 'htm/preact'
import { useEffect, useMemo, useState } from 'preact/hooks'
import {
  buildChronicleViewModel,
  chronicleLaneForEvent,
  chronicleLaneLabel,
} from './chronicle-model'
import type { ChronicleEvent, ChronicleLane } from './chronicle-types'

interface ChronicleNavigatorProps {
  events: readonly ChronicleEvent[]
  selectedEventId?: string | null
  maxEvents?: number
  testId?: string
  onSelectedEventChange?: (eventId: string | null) => void
}

const LANE_TONE: Record<ChronicleLane, string> = {
  git: 'border-[var(--color-status-ok)]',
  keeper: 'border-[var(--color-accent)]',
  plan: 'border-[var(--color-status-info)]',
  system: 'border-[var(--color-border-strong)]',
  conversation: 'border-[var(--color-status-warn)]',
}

function formatTime(timestamp: number): string {
  const date = new Date(timestamp)
  if (!Number.isFinite(date.getTime())) return '--:--:--'
  return `${date.getHours().toString().padStart(2, '0')}:${date.getMinutes().toString().padStart(2, '0')}:${date.getSeconds().toString().padStart(2, '0')}`
}

function formatMetadataValue(value: unknown): string {
  if (value == null) return ''
  if (typeof value === 'string') return value
  if (typeof value === 'number' || typeof value === 'boolean') return String(value)
  if (Array.isArray(value)) return value.map(item => formatMetadataValue(item)).filter(Boolean).join(', ')
  try {
    return JSON.stringify(value)
  } catch {
    return String(value)
  }
}

function metadataEntries(event: ChronicleEvent | null): Array<[string, string]> {
  if (!event?.content.metadata) return []
  return Object.entries(event.content.metadata)
    .map(([key, value]): [string, string] => [key, formatMetadataValue(value)])
    .filter(([, value]) => value !== '')
}

export function ChronicleNavigator({
  events,
  selectedEventId,
  maxEvents = 100,
  testId,
  onSelectedEventChange,
}: ChronicleNavigatorProps) {
  const [internalSelectedId, setInternalSelectedId] = useState<string | null | undefined>(
    selectedEventId,
  )
  useEffect(() => {
    if (selectedEventId !== undefined) setInternalSelectedId(selectedEventId)
  }, [selectedEventId])
  const effectiveSelectedId = selectedEventId !== undefined ? selectedEventId : internalSelectedId
  const model = useMemo(
    () => buildChronicleViewModel(events, effectiveSelectedId, maxEvents),
    [events, effectiveSelectedId, maxEvents],
  )
  const selected = model.selectedEvent
  const selectedLane = selected ? chronicleLaneForEvent(selected) : null
  const metadata = metadataEntries(selected)

  const selectEvent = (eventId: string) => {
    if (selectedEventId === undefined) setInternalSelectedId(eventId)
    onSelectedEventChange?.(eventId)
  }

  return html`
    <section
      class="grid min-h-0 gap-3 lg:grid-cols-[minmax(220px,0.9fr)_minmax(220px,1fr)_minmax(260px,1.2fr)]"
      aria-label="Chronicle navigator"
      data-chronicle-navigator
      data-chronicle-total-count=${model.summary.totalCount}
      data-chronicle-visible-count=${model.summary.visibleCount}
      data-chronicle-selected-id=${selected?.id ?? ''}
      data-chronicle-session-count=${model.summary.sessionCount}
      data-chronicle-related-link-count=${model.summary.relatedLinkCount}
      data-testid=${testId}
    >
      <div
        class="min-h-0 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)]"
        data-chronicle-panel="timeline"
      >
        <div class="border-b border-[var(--color-border-default)] px-3 py-2">
          <div class="text-2xs font-semibold text-[var(--color-fg-primary)]">Chronicle</div>
          <div class="text-3xs text-[var(--color-fg-muted)]">
            ${model.summary.visibleCount}/${model.summary.totalCount} events · ${model.summary.sessionCount} sessions
          </div>
        </div>
        <div class="max-h-[520px] overflow-auto p-2" role="list" aria-label="Chronicle events">
          ${model.events.length === 0
            ? html`<div class="px-1 py-2 text-3xs text-[var(--color-fg-muted)]">No chronicle events</div>`
            : model.events.map(event => {
                const lane = chronicleLaneForEvent(event)
                const selectedRow = selected?.id === event.id
                return html`
                  <div role="listitem" data-chronicle-event-id=${event.id}>
                    <button
                      type="button"
                      class=${`mb-1 grid w-full grid-cols-[3.5rem_minmax(0,1fr)] gap-2 rounded-[var(--r-1)] border-l-2 ${LANE_TONE[lane]} px-2 py-1.5 text-left hover:bg-[var(--color-bg-hover)] aria-pressed:bg-[var(--color-state-active-bg)]`}
                      aria-pressed=${selectedRow}
                      onClick=${() => selectEvent(event.id)}
                    >
                      <span class="font-mono text-3xs text-[var(--color-fg-muted)]">${formatTime(event.timestamp)}</span>
                      <span class="min-w-0">
                        <span class="block truncate text-xs text-[var(--color-fg-primary)]">${event.content.summary}</span>
                        <span class="block truncate text-3xs text-[var(--color-fg-muted)]">
                          ${chronicleLaneLabel(lane)} · ${event.actor.displayName}
                        </span>
                      </span>
                    </button>
                  </div>
                `
              })}
        </div>
      </div>

      <div
        class="min-h-0 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)]"
        data-chronicle-panel="context"
      >
        <div class="border-b border-[var(--color-border-default)] px-3 py-2">
          <div class="text-2xs font-semibold text-[var(--color-fg-primary)]">Context</div>
          <div class="text-3xs text-[var(--color-fg-muted)]">
            ${selected ? `${chronicleLaneLabel(selectedLane!)} · ${selected.context.sessionId}` : 'No selection'}
          </div>
        </div>
        <div class="grid gap-3 p-3">
          <div>
            <div class="mb-1 text-3xs font-semibold uppercase text-[var(--color-fg-muted)]">Related Events</div>
            ${model.relatedEvents.length === 0
              ? html`<div class="text-3xs text-[var(--color-fg-muted)]">No related events</div>`
              : html`
                <ul class="grid gap-1" aria-label="Related chronicle events">
                  ${model.relatedEvents.map(event => html`
                    <li class="rounded-[var(--r-0)] bg-[var(--color-bg-elevated)] px-2 py-1 text-3xs text-[var(--color-fg-secondary)]">
                      ${formatTime(event.timestamp)} · ${event.content.summary}
                    </li>
                  `)}
                </ul>
              `}
          </div>
          <div>
            <div class="mb-1 text-3xs font-semibold uppercase text-[var(--color-fg-muted)]">Linked Targets</div>
            ${model.linkedTargets.length === 0
              ? html`<div class="text-3xs text-[var(--color-fg-muted)]">No linked targets</div>`
              : html`
                <ul class="grid gap-1" aria-label="Linked chronicle targets">
                  ${model.linkedTargets.map(target => html`
                    <li
                      class="flex min-w-0 items-center justify-between gap-2 rounded-[var(--r-0)] bg-[var(--color-bg-elevated)] px-2 py-1 text-3xs"
                      data-chronicle-target=${target.key}
                    >
                      <span class="min-w-0 truncate text-[var(--color-fg-secondary)]">${target.uri}</span>
                      <span class="shrink-0 font-mono text-[var(--color-fg-muted)]">${target.eventCount}</span>
                    </li>
                  `)}
                </ul>
              `}
          </div>
          <div>
            <div class="mb-1 text-3xs font-semibold uppercase text-[var(--color-fg-muted)]">Project State</div>
            ${selected?.context.projectState
              ? html`
                <dl class="grid grid-cols-[5rem_minmax(0,1fr)] gap-x-2 gap-y-1 text-3xs">
                  <dt class="text-[var(--color-fg-muted)]">branch</dt>
                  <dd class="truncate text-[var(--color-fg-secondary)]">${selected.context.projectState.branch ?? '-'}</dd>
                  <dt class="text-[var(--color-fg-muted)]">commit</dt>
                  <dd class="truncate font-mono text-[var(--color-fg-secondary)]">${selected.context.projectState.commit ?? '-'}</dd>
                  <dt class="text-[var(--color-fg-muted)]">files</dt>
                  <dd class="text-[var(--color-fg-secondary)]">${selected.context.projectState.filesChanged ?? 0}</dd>
                </dl>
              `
              : html`<div class="text-3xs text-[var(--color-fg-muted)]">No project snapshot</div>`}
          </div>
        </div>
      </div>

      <div
        class="min-h-0 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)]"
        data-chronicle-panel="detail"
      >
        <div class="border-b border-[var(--color-border-default)] px-3 py-2">
          <div class="text-2xs font-semibold text-[var(--color-fg-primary)]">Action Detail</div>
          <div class="text-3xs text-[var(--color-fg-muted)]">${selected?.target.uri ?? 'No selection'}</div>
        </div>
        ${selected
          ? html`
            <div class="grid gap-3 p-3">
              <div>
                <div class="text-sm font-semibold text-[var(--color-fg-primary)]">${selected.content.summary}</div>
                ${selected.content.detail
                  ? html`<p class="mt-1 text-xs text-[var(--color-fg-secondary)]">${selected.content.detail}</p>`
                  : null}
              </div>
              ${selected.content.diff
                ? html`
                  <pre class="max-h-48 overflow-auto rounded-[var(--r-1)] bg-[var(--color-bg-elevated)] p-2 text-3xs text-[var(--color-fg-secondary)]">${selected.content.diff}</pre>
                `
                : null}
              ${metadata.length > 0
                ? html`
                  <dl class="grid grid-cols-[7rem_minmax(0,1fr)] gap-x-2 gap-y-1 text-3xs">
                    ${metadata.map(([key, value]) => html`
                      <dt class="text-[var(--color-fg-muted)]">${key}</dt>
                      <dd class="min-w-0 truncate text-[var(--color-fg-secondary)]">${value}</dd>
                    `)}
                  </dl>
                `
                : null}
              ${selected.intent
                ? html`
                  <div
                    class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-1.5 text-3xs text-[var(--color-fg-secondary)]"
                    data-chronicle-intent
                  >
                    ${selected.intent.statedGoal ?? selected.intent.inferredIntent ?? 'Intent recorded'}
                    <span class="font-mono text-[var(--color-fg-muted)]">${Math.round(selected.intent.confidence * 100)}%</span>
                  </div>
                `
                : null}
            </div>
          `
          : html`<div class="p-3 text-3xs text-[var(--color-fg-muted)]">Select an event to inspect details</div>`}
      </div>
    </section>
  `
}
