import { html } from 'htm/preact'
import { useCallback, useEffect, useMemo, useRef, useState } from 'preact/hooks'
import { CheckCircle2, EyeOff, RefreshCw, ShieldAlert, Trash2 } from 'lucide-preact'
import {
  fetchBoardModerationQueue,
  flagBoardModerationTarget,
  submitBoardModerationAction,
  type BoardModerationActionKind,
  type BoardModerationFlagReason,
  type BoardModerationQueueEntry,
  type BoardModerationTargetKind,
} from '../../api/board-moderation'
import { ActionButton } from '../common/button'
import { EmptyState, LoadingState } from '../common/feedback-state'
import { TextInput } from '../common/input'
import { Select } from '../common/select'
import { SurfaceCard } from '../common/card'
import { TimeAgo } from '../common/time-ago'
import { showToast } from '../common/toast'

type QueueFilter = 'open' | 'resolved' | 'all'

const TARGET_OPTIONS: Array<{ value: BoardModerationTargetKind; label: string }> = [
  { value: 'post', label: 'Post' },
  { value: 'comment', label: 'Comment' },
]

const REASON_OPTIONS: Array<{ value: BoardModerationFlagReason; label: string }> = [
  { value: 'spam', label: 'Spam' },
  { value: 'harassment', label: 'Harassment' },
  { value: 'off_topic', label: 'Off topic' },
  { value: 'policy:operator', label: 'Policy' },
]

const FILTER_OPTIONS: Array<{ value: QueueFilter; label: string }> = [
  { value: 'open', label: 'Open' },
  { value: 'resolved', label: 'Resolved' },
  { value: 'all', label: 'All' },
]

const ACTION_META: Record<BoardModerationActionKind, {
  label: string
  variant: 'ghost' | 'danger' | 'warn' | 'ok'
  icon: typeof CheckCircle2
}> = {
  approve: { label: 'Approve', variant: 'ok', icon: CheckCircle2 },
  hide: { label: 'Hide', variant: 'warn', icon: EyeOff },
  remove: { label: 'Remove', variant: 'danger', icon: Trash2 },
  warn: { label: 'Warn', variant: 'ghost', icon: ShieldAlert },
}

function resolvedQuery(filter: QueueFilter): boolean | undefined {
  if (filter === 'open') return false
  if (filter === 'resolved') return true
  return undefined
}

function queueTimestamp(entry: BoardModerationQueueEntry): string {
  return entry.flagged_at_iso ?? new Date(entry.flagged_at * 1000).toISOString()
}

function QueueRow({
  entry,
  busyAction,
  onAction,
}: {
  entry: BoardModerationQueueEntry
  busyAction: string | null
  onAction: (entry: BoardModerationQueueEntry, action: BoardModerationActionKind) => void
}) {
  return html`
    <${SurfaceCard} variant="compact" testId=${`moderation-row-${entry.entry_id}`}>
      <div class="grid gap-3 lg:grid-cols-[1fr_auto] lg:items-start">
        <div class="min-w-0 space-y-2">
          <div class="flex min-w-0 flex-wrap items-center gap-2">
            <span class="inline-flex size-7 items-center justify-center rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] text-[var(--color-fg-muted)]" aria-hidden="true">
              <${ShieldAlert} size=${15} />
            </span>
            <div class="min-w-0">
              <h3 class="truncate font-mono text-sm font-semibold text-[var(--color-fg-primary)]">${entry.target_id}</h3>
              <div class="flex flex-wrap items-center gap-2 text-2xs text-[var(--color-fg-muted)]">
                <span>${entry.target_kind}</span>
                <span>${entry.reason}</span>
                <span>${entry.reporter}</span>
                <span><${TimeAgo} timestamp=${queueTimestamp(entry)} /></span>
              </div>
            </div>
          </div>
          <div class="flex flex-wrap items-center gap-2 text-2xs text-[var(--color-fg-muted)]">
            <span class=${`inline-flex rounded-[var(--r-1)] border px-1.5 py-0.5 ${
              entry.resolved
                ? 'border-[var(--ok-30)] bg-[var(--ok-10)] text-[var(--ok-bright)]'
                : 'border-[var(--warn-30)] bg-[var(--warn-10)] text-[var(--warn-bright)]'
            }`}>
              ${entry.resolved ? 'resolved' : 'open'}
            </span>
            <span class="font-mono">${entry.entry_id}</span>
          </div>
        </div>
        <div class="flex flex-wrap gap-2 lg:justify-end">
          ${(['approve', 'hide', 'warn', 'remove'] as const).map(action => {
            const meta = ACTION_META[action]
            const Icon = meta.icon
            const busy = busyAction === `${entry.entry_id}:${action}`
            return html`
              <${ActionButton}
                key=${action}
                variant=${meta.variant}
                size="sm"
                disabled=${entry.resolved || busyAction !== null}
                ariaBusy=${busy}
                ariaLabel=${`${meta.label} moderation flag ${entry.entry_id}`}
                testId=${`moderation-action-${entry.entry_id}-${action}`}
                onClick=${() => onAction(entry, action)}
              >
                <span class="inline-flex items-center gap-1.5">
                  <${Icon} size=${13} aria-hidden="true" />
                  ${busy ? 'Working' : meta.label}
                </span>
              <//>
            `
          })}
        </div>
      </div>
    <//>
  `
}

export function BoardModerationSurface() {
  const [entries, setEntries] = useState<BoardModerationQueueEntry[]>([])
  const [serverCount, setServerCount] = useState(0)
  const [filter, setFilter] = useState<QueueFilter>('open')
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [targetKind, setTargetKind] = useState<BoardModerationTargetKind>('post')
  const [targetId, setTargetId] = useState('')
  const [reporter, setReporter] = useState('dashboard')
  const [reason, setReason] = useState<BoardModerationFlagReason>('spam')
  const [submitting, setSubmitting] = useState(false)
  const [busyAction, setBusyAction] = useState<string | null>(null)
  const activeLoad = useRef<{ id: number; controller: AbortController } | null>(null)
  const nextLoadId = useRef(0)

  const load = useCallback(async () => {
    activeLoad.current?.controller.abort()
    const controller = new AbortController()
    const id = nextLoadId.current + 1
    nextLoadId.current = id
    activeLoad.current = { id, controller }
    setLoading(true)
    setError(null)
    try {
      const queue = await fetchBoardModerationQueue({
        resolved: resolvedQuery(filter),
        signal: controller.signal,
      })
      if (activeLoad.current?.id !== id || controller.signal.aborted) return
      setEntries(queue.entries)
      setServerCount(queue.count)
    } catch (err) {
      if (activeLoad.current?.id !== id || controller.signal.aborted) return
      const message = err instanceof Error ? err.message : 'Failed to load moderation queue'
      setError(message)
    } finally {
      if (activeLoad.current?.id === id) {
        activeLoad.current = null
        setLoading(false)
      }
    }
  }, [filter])

  useEffect(() => {
    void load()
    return () => {
      activeLoad.current?.controller.abort()
      activeLoad.current = null
      nextLoadId.current += 1
    }
  }, [load])

  const openCount = useMemo(() => entries.filter(entry => !entry.resolved).length, [entries])
  const canSubmit = targetId.trim() !== '' && !submitting

  const submitFlag = async (event: Event) => {
    event.preventDefault()
    if (!canSubmit) return
    setSubmitting(true)
    setError(null)
    try {
      await flagBoardModerationTarget({
        target_kind: targetKind,
        target_id: targetId,
        reporter,
        reason,
      })
      setTargetId('')
      showToast('Moderation flag queued', 'success')
      await load()
    } catch (err) {
      const message = err instanceof Error ? err.message : 'Failed to flag target'
      setError(message)
      showToast(`Moderation flag failed: ${message}`, 'error')
    } finally {
      setSubmitting(false)
    }
  }

  const handleAction = async (
    entry: BoardModerationQueueEntry,
    action: BoardModerationActionKind,
  ) => {
    const key = `${entry.entry_id}:${action}`
    setBusyAction(key)
    setError(null)
    try {
      const result = await submitBoardModerationAction({
        target_kind: entry.target_kind,
        target_id: entry.target_id,
        action,
        reason: entry.reason,
      })
      showToast(result.delete_warning ?? `Moderation action recorded: ${action}`, result.delete_warning ? 'warning' : 'success')
      await load()
    } catch (err) {
      const message = err instanceof Error ? err.message : 'Failed to record moderation action'
      setError(message)
      showToast(`Moderation action failed: ${message}`, 'error')
    } finally {
      setBusyAction(null)
    }
  }

  return html`
    <section class="flex min-w-0 flex-col gap-4" aria-label="Board moderation">
      <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div class="min-w-0">
          <h2 class="text-base font-semibold text-[var(--color-fg-primary)]">Board Moderation</h2>
          <p class="mt-1 text-xs text-[var(--color-fg-muted)]">${openCount} open / ${serverCount} returned</p>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <${Select}
            value=${filter}
            options=${FILTER_OPTIONS}
            ariaLabel="Moderation queue filter"
            testId="moderation-filter"
            class="!w-32 !py-1 !text-xs"
            disabled=${loading}
            onInput=${(value: string) => setFilter(value as QueueFilter)}
          />
          <${ActionButton}
            variant="ghost"
            size="sm"
            onClick=${() => { void load() }}
            disabled=${loading}
            ariaLabel="Refresh moderation queue"
          >
            <span class="inline-flex items-center gap-1.5">
              <${RefreshCw} size=${14} aria-hidden="true" />
              Refresh
            </span>
          <//>
        </div>
      </div>

      <form class="grid gap-3 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3" onSubmit=${submitFlag}>
        <div class="grid gap-3 lg:grid-cols-[0.7fr_1fr_0.8fr_0.8fr_auto] lg:items-end">
          <label class="grid gap-1 text-2xs font-medium uppercase text-[var(--color-fg-muted)]">
            Target
            <${Select}
              value=${targetKind}
              options=${TARGET_OPTIONS}
              disabled=${submitting}
              ariaLabel="Moderation target kind"
              testId="moderation-target-kind"
              onInput=${(value: string) => setTargetKind(value as BoardModerationTargetKind)}
            />
          </label>
          <label class="grid gap-1 text-2xs font-medium uppercase text-[var(--color-fg-muted)]">
            Target ID
            <${TextInput}
              value=${targetId}
              required
              disabled=${submitting}
              placeholder="post-id"
              ariaLabel="Moderation target id"
              testId="moderation-target-id"
              onInput=${(event: Event) => setTargetId((event.target as HTMLInputElement).value)}
            />
          </label>
          <label class="grid gap-1 text-2xs font-medium uppercase text-[var(--color-fg-muted)]">
            Reason
            <${Select}
              value=${reason}
              options=${REASON_OPTIONS}
              disabled=${submitting}
              ariaLabel="Moderation reason"
              testId="moderation-reason"
              onInput=${(value: string) => setReason(value as BoardModerationFlagReason)}
            />
          </label>
          <label class="grid gap-1 text-2xs font-medium uppercase text-[var(--color-fg-muted)]">
            Reporter
            <${TextInput}
              value=${reporter}
              disabled=${submitting}
              placeholder="dashboard"
              ariaLabel="Moderation reporter"
              testId="moderation-reporter"
              onInput=${(event: Event) => setReporter((event.target as HTMLInputElement).value)}
            />
          </label>
          <${ActionButton}
            type="submit"
            variant="primary"
            size="md"
            disabled=${!canSubmit}
            ariaBusy=${submitting}
            testId="moderation-flag-submit"
          >
            <span class="inline-flex items-center gap-1.5">
              <${ShieldAlert} size=${14} aria-hidden="true" />
              Flag
            </span>
          <//>
        </div>
      </form>

      ${error ? html`
        <div class="rounded-[var(--r-1)] border border-[var(--color-status-err)]/40 bg-[var(--color-status-err)]/10 px-3 py-2 text-xs text-[var(--color-status-err)]" role="alert">${error}</div>
      ` : null}

      ${loading
        ? html`<${LoadingState}>Loading moderation queue...<//>`
        : entries.length === 0
          ? html`<${EmptyState} message="No moderation queue entries." compact />`
          : html`
            <div class="grid gap-3" data-testid="moderation-queue">
              ${entries.map(entry => html`
                <${QueueRow}
                  key=${entry.entry_id}
                  entry=${entry}
                  busyAction=${busyAction}
                  onAction=${handleAction}
                />
              `)}
            </div>
          `}
    </section>
  `
}
