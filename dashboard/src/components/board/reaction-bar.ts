import { html } from 'htm/preact'
import { useCallback, useEffect, useMemo, useRef, useState } from 'preact/hooks'
import { fetchBoardReactionState, toggleReaction } from '../../api/board'
import { lastEvent } from '../../sse'
import { showToast } from '../common/toast'
import type { BoardReactionSummary, BoardReactionTargetType } from '../../types'

type Target = { targetType: BoardReactionTargetType; targetId: string }
export type ReactionBatchObservation =
  { revision: number } & (
    | { state: 'loading' }
    | { state: 'unavailable' }
    | { state: 'ready'; byTargetId: ReadonlyMap<string, BoardReactionSummary[]>; supportedEmojis: readonly string[] }
  )

type BatchFence = { owner: () => number; through: number }

type Observation = Target & {
  batch: ReactionBatchObservation | undefined
  phase: 'loading' | 'ready' | 'writing' | 'unavailable'
  summaries: BoardReactionSummary[]
  catalog: readonly string[] | null
  message: string
  fence?: BatchFence
}
type Request = Target & { batch: ReactionBatchObservation | undefined; fence?: BatchFence } & (
  | { kind: 'read' }
  | { kind: 'write'; refreshAfterWrite: boolean }
)

function owns(target: Target, targetType: BoardReactionTargetType, targetId: string): boolean {
  return target.targetType === targetType && target.targetId === targetId
}

function captureBatchFence(owner?: () => number): BatchFence | undefined {
  return owner ? { owner, through: owner() } : undefined
}

function coveredByFence(batch: ReactionBatchObservation | undefined, fence: BatchFence | undefined, owner?: () => number): boolean {
  return batch !== undefined && batch.state !== 'unavailable'
    && fence !== undefined && fence.owner === owner && batch.revision <= fence.through
}

function projectBatch(current: Observation, incoming: Observation, owner?: () => number): Observation {
  if (!owns(current, incoming.targetType, incoming.targetId)) return incoming
  if (current.batch === incoming.batch || current.phase === 'writing'
    || coveredByFence(incoming.batch, current.fence, owner)) return current
  if (incoming.phase === 'ready') return incoming
  return {
    ...incoming, summaries: current.summaries, catalog: current.catalog ?? incoming.catalog, fence: current.fence,
  }
}

function initialObservation(
  targetType: BoardReactionTargetType,
  targetId: string,
  summaries?: BoardReactionSummary[],
  catalog?: readonly string[],
  batch?: ReactionBatchObservation,
): Observation {
  if (batch?.state === 'ready') {
    summaries = batch.byTargetId.get(targetId)
    catalog = batch.supportedEmojis
  }
  const phase = batch?.state === 'loading' ? 'loading'
    : batch?.state === 'unavailable' ? 'unavailable'
    : summaries !== undefined && catalog !== undefined && catalog.length > 0 ? 'ready' : 'loading'
  return {
    targetType, targetId, batch, phase,
    summaries: summaries ?? [],
    catalog: catalog && catalog.length > 0 ? catalog : null,
    message: phase === 'unavailable' ? '리액션 요약을 불러오지 못했습니다' : '',
  }
}

export function ReactionBar({
  targetType,
  targetId,
  compact = false,
  initialSummaries,
  supportedEmojis,
  batchObservation,
  getLatestBatchRevision,
}: {
  targetType: BoardReactionTargetType
  targetId: string
  compact?: boolean
  initialSummaries?: BoardReactionSummary[]
  supportedEmojis?: readonly string[]
  /** An actual parent batch observation, preserved across ordinary rerenders. */
  batchObservation?: ReactionBatchObservation
  /** Synchronous batch-start order, including starts whose loading render was coalesced. */
  getLatestBatchRevision?: () => number
}) {
  const incoming = initialObservation(targetType, targetId, initialSummaries, supportedEmojis, batchObservation)
  const hasInitialState = incoming.phase === 'ready'
  const [observation, setObservation] = useState<Observation>(() => incoming)
  const activeRequest = useRef<Request | null>(null)
  const visible = projectBatch(observation, incoming, getLatestBatchRevision)

  useEffect(() => () => {
    const request = activeRequest.current
    if (request && owns(request, targetType, targetId)) activeRequest.current = null
  }, [targetType, targetId])

  useEffect(() => {
    const request = activeRequest.current
    if (request && owns(request, targetType, targetId)) {
      if (request.kind === 'write') {
        if (request.batch !== batchObservation) {
          request.batch = batchObservation
          request.refreshAfterWrite = true
          setObservation(current => owns(current, targetType, targetId)
            ? { ...current, batch: batchObservation } : current)
        }
        return
      }
      if (request.batch === batchObservation
        || coveredByFence(batchObservation, request.fence, getLatestBatchRevision)) return
    }
    activeRequest.current = null
    setObservation(current => projectBatch(current,
      initialObservation(targetType, targetId, initialSummaries, supportedEmojis, batchObservation), getLatestBatchRevision))
  }, [targetType, targetId, initialSummaries, supportedEmojis, batchObservation, getLatestBatchRevision])

  const refresh = useCallback((batch = batchObservation) => {
    const pending = activeRequest.current
    if (pending?.kind === 'write' && owns(pending, targetType, targetId)) {
      pending.refreshAfterWrite = true
      return
    }
    const fence = captureBatchFence(getLatestBatchRevision)
    const request: Request = { kind: 'read', targetType, targetId, batch, fence }
    activeRequest.current = request
    setObservation(current => ({
      ...(owns(current, targetType, targetId) ? current : initialObservation(targetType, targetId)),
      batch, fence, phase: 'loading', message: '',
    }))
    void fetchBoardReactionState(targetType, targetId)
      .then(next => {
        if (activeRequest.current !== request) return
        activeRequest.current = null
        setObservation({
          targetType, targetId, batch, phase: 'ready', summaries: next.summaries,
          catalog: next.supportedEmojis, message: '', fence: captureBatchFence(getLatestBatchRevision),
        })
      })
      .catch(err => {
        if (activeRequest.current !== request) return
        activeRequest.current = null
        console.warn('[board] reaction summary failed', err instanceof Error ? err.message : err)
        const fence = captureBatchFence(getLatestBatchRevision)
        setObservation(current => ({
          ...(owns(current, targetType, targetId) ? current : initialObservation(targetType, targetId)),
          batch, phase: 'unavailable', message: '리액션 요약을 불러오지 못했습니다', fence,
        }))
      })
  }, [targetType, targetId, batchObservation, getLatestBatchRevision])

  useEffect(() => {
    if (!hasInitialState && batchObservation?.state !== 'loading') refresh()
    return lastEvent.subscribe(event => {
      if (event?.type === 'reaction_changed'
        && event.target_type === targetType && event.target_id === targetId) refresh()
    })
  }, [targetType, targetId, hasInitialState, batchObservation, refresh])

  const summaryByEmoji = useMemo(() => new Map(
    visible.summaries.map(summary => [summary.emoji, summary]),
  ), [visible.summaries])

  const handleToggle = async (emoji: string) => {
    if (visible.phase !== 'ready' || activeRequest.current !== null) return
    const request: Request = { kind: 'write', targetType, targetId, batch: batchObservation, refreshAfterWrite: false }
    activeRequest.current = request
    setObservation({ ...visible, phase: 'writing', message: '' })
    try {
      const result = await toggleReaction(targetType, targetId, emoji)
      if (activeRequest.current !== request) return
      activeRequest.current = null
      const fence = captureBatchFence(getLatestBatchRevision)
      setObservation(current => owns(current, targetType, targetId)
        ? { ...current, batch: request.batch, phase: 'ready', summaries: result.summary, message: '',
          fence } : current)
      if (request.refreshAfterWrite) refresh(request.batch)
    } catch (err) {
      if (activeRequest.current !== request) return
      activeRequest.current = null
      console.warn('[board] reaction toggle failed', err instanceof Error ? err.message : err)
      const message = '리액션 반영에 실패했습니다'
      const fence = captureBatchFence(getLatestBatchRevision)
      setObservation(current => owns(current, targetType, targetId)
        ? { ...current, batch: request.batch, phase: 'unavailable', message,
          fence } : current)
      showToast(message, 'error')
      if (request.refreshAfterWrite) refresh(request.batch)
    }
  }

  const ready = visible.phase === 'ready'
  const knownLabel = ready || visible.phase === 'writing'
  const message = visible.phase === 'loading' ? '불러오는 중…'
    : visible.phase === 'writing' ? '리액션 반영 중…' : visible.message
  return html`
    <div class="board-reaction-bar flex items-center gap-1 flex-wrap" role="group" aria-label="리액션">
      ${(visible.catalog ?? []).map(emoji => {
        const summary = summaryByEmoji.get(emoji)
        const count = summary?.count ?? 0
        const reacted = ready ? summary?.reacted ?? false : undefined
        return html`
          <button
            key=${emoji}
            type="button"
            class=${`v2-workspace-action inline-flex items-center justify-center gap-1 leading-none ${compact ? 'h-6 min-w-7 px-1.5 text-2xs' : 'h-7 min-w-8 px-2 text-xs'} rounded-[var(--r-1)] border transition-colors duration-[var(--t-med)] ${
              reacted
                ? 'bg-[var(--accent-12)] text-[var(--color-accent-fg)] border-[var(--accent-20)]'
                : 'bg-transparent text-[var(--color-fg-muted)] border-[var(--color-border-divider)] hover:bg-[var(--color-bg-hover)] hover:text-[var(--color-fg-primary)]'
            } disabled:opacity-60`}
            aria-pressed=${reacted}
            aria-label=${knownLabel ? `${emoji} 리액션 ${count}개` : `${emoji} 리액션 확인 불가`}
            disabled=${!ready}
            onClick=${() => { void handleToggle(emoji) }}
          >
            <span aria-hidden="true">${emoji}</span>
            ${count > 0 ? html`<span class="tabular-nums">${count}</span>` : null}
          </button>
        `
      })}
      <span class="text-xs text-[var(--color-fg-muted)]" role="status" aria-live="polite" aria-atomic="true">
        ${message}
        ${visible.phase === 'unavailable' && visible.summaries.length > 0
          ? ' 마지막 확인한 수치를 표시합니다.' : ''}
      </span>
      ${visible.phase === 'unavailable' ? html`
        <button type="button" class="text-xs underline" aria-label="리액션 다시 확인" onClick=${() => refresh()}>
          다시 확인
        </button>` : null}
    </div>
  `
}
