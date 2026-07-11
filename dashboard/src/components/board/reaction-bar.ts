import { html } from 'htm/preact'
import { useEffect, useMemo, useState } from 'preact/hooks'
import { fetchBoardReactionState, toggleReaction } from '../../api/board'
import { lastEvent } from '../../sse'
import { showToast } from '../common/toast'
import type { BoardReactionSummary, BoardReactionTargetType } from '../../types'

export function ReactionBar({
  targetType,
  targetId,
  compact = false,
  initialSummaries,
  supportedEmojis,
}: {
  targetType: BoardReactionTargetType
  targetId: string
  compact?: boolean
  initialSummaries?: BoardReactionSummary[]
  supportedEmojis?: readonly string[]
}) {
  const hasInitialState =
    initialSummaries !== undefined && supportedEmojis !== undefined && supportedEmojis.length > 0
  const [summaries, setSummaries] = useState<BoardReactionSummary[]>(() => initialSummaries ?? [])
  const [supportedEmojiCatalog, setSupportedEmojiCatalog] = useState<string[] | null>(
    () => supportedEmojis && supportedEmojis.length > 0 ? [...supportedEmojis] : null,
  )
  const [busyEmoji, setBusyEmoji] = useState<string | null>(null)
  const [statusMessage, setStatusMessage] = useState('')

  useEffect(() => {
    setSummaries(initialSummaries ?? [])
    setSupportedEmojiCatalog(
      supportedEmojis && supportedEmojis.length > 0 ? [...supportedEmojis] : null,
    )
    setStatusMessage('')
  }, [targetType, targetId, initialSummaries, supportedEmojis])

  useEffect(() => {
    let cancelled = false
    const refresh = () => {
      setStatusMessage('')
      void fetchBoardReactionState(targetType, targetId)
        .then(next => {
          if (!cancelled) {
            setSummaries(next.summaries)
            setSupportedEmojiCatalog(next.supportedEmojis)
            setStatusMessage('')
          }
        })
        .catch(err => {
          if (!cancelled) {
            console.warn('[board] reaction summary failed', err instanceof Error ? err.message : err)
            setStatusMessage('리액션 요약을 불러오지 못했습니다')
          }
        })
    }
    if (!hasInitialState) refresh()
    const unsubscribe = lastEvent.subscribe(event => {
      if (event?.type !== 'reaction_changed') return
      if (event.target_type === targetType && event.target_id === targetId) {
        refresh()
      }
    })
    return () => {
      cancelled = true
      unsubscribe()
    }
  }, [targetType, targetId, hasInitialState])

  const summaryByEmoji = useMemo(() => {
    const map = new Map<string, BoardReactionSummary>()
    for (const summary of summaries) map.set(summary.emoji, summary)
    return map
  }, [summaries])

  const handleToggle = async (emoji: string) => {
    if (busyEmoji) return
    setBusyEmoji(emoji)
    setStatusMessage('')
    try {
      const result = await toggleReaction(targetType, targetId, emoji)
      setSummaries(result.summary)
    } catch (err) {
      console.warn('[board] reaction toggle failed', err instanceof Error ? err.message : err)
      const message = '리액션 반영에 실패했습니다'
      setStatusMessage(message)
      showToast(message, 'error')
    } finally {
      setBusyEmoji(null)
    }
  }

  return html`
    <div class="flex items-center gap-1 flex-wrap" role="group" aria-label="리액션">
      ${(supportedEmojiCatalog ?? []).map(emoji => {
        const summary = summaryByEmoji.get(emoji)
        const count = summary?.count ?? 0
        const reacted = summary?.reacted ?? false
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
            aria-label=${`${emoji} 리액션 ${count}개`}
            disabled=${busyEmoji !== null}
            onClick=${() => { void handleToggle(emoji) }}
          >
            <span aria-hidden="true">${emoji}</span>
            ${count > 0 ? html`<span class="tabular-nums">${count}</span>` : null}
          </button>
        `
      })}
      <span class="sr-only" role="status" aria-live="polite" aria-atomic="true">
        ${statusMessage || (supportedEmojiCatalog === null ? '리액션 종류를 불러오는 중입니다' : '')}
      </span>
    </div>
  `
}
