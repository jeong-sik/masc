import { html } from 'htm/preact'
import { useEffect, useMemo, useState } from 'preact/hooks'
import { fetchBoardReactions, toggleReaction } from '../../api/board'
import { lastEvent } from '../../sse'
import { showToast } from '../common/toast'
import type { BoardReactionSummary, BoardReactionTargetType } from '../../types'

const BOARD_REACTION_EMOJIS = ['👍', '❤️', '🎉', '🚀', '👀', '😕', '👏', '🔥'] as const

export function ReactionBar({
  targetType,
  targetId,
  compact = false,
  initialSummaries,
}: {
  targetType: BoardReactionTargetType
  targetId: string
  compact?: boolean
  initialSummaries?: BoardReactionSummary[]
}) {
  const hasInitialSummaries = initialSummaries !== undefined
  const [summaries, setSummaries] = useState<BoardReactionSummary[]>(() => initialSummaries ?? [])
  const [busyEmoji, setBusyEmoji] = useState<string | null>(null)

  useEffect(() => {
    setSummaries(initialSummaries ?? [])
  }, [targetType, targetId, initialSummaries])

  useEffect(() => {
    let cancelled = false
    const refresh = () => {
      void fetchBoardReactions(targetType, targetId)
        .then(next => {
          if (!cancelled) setSummaries(next)
        })
        .catch(err => {
          if (!cancelled) {
            console.warn('[board] reaction summary failed', err instanceof Error ? err.message : err)
          }
        })
    }
    if (!hasInitialSummaries) refresh()
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
  }, [targetType, targetId, hasInitialSummaries])

  const summaryByEmoji = useMemo(() => {
    const map = new Map<string, BoardReactionSummary>()
    for (const summary of summaries) map.set(summary.emoji, summary)
    return map
  }, [summaries])

  const handleToggle = async (emoji: string) => {
    if (busyEmoji) return
    setBusyEmoji(emoji)
    try {
      const result = await toggleReaction(targetType, targetId, emoji)
      setSummaries(result.summary)
    } catch (err) {
      console.warn('[board] reaction toggle failed', err instanceof Error ? err.message : err)
      showToast('리액션 반영에 실패했습니다', 'error')
    } finally {
      setBusyEmoji(null)
    }
  }

  return html`
    <div class="flex items-center gap-1 flex-wrap" role="group" aria-label="리액션">
      ${BOARD_REACTION_EMOJIS.map(emoji => {
        const summary = summaryByEmoji.get(emoji)
        const count = summary?.count ?? 0
        const reacted = summary?.reacted ?? false
        return html`
          <button
            key=${emoji}
            type="button"
            class=${`${compact ? 'h-6 min-w-7 px-1.5 text-2xs' : 'h-7 min-w-8 px-2 text-xs'} rounded-[var(--r-1)] border transition-colors duration-[var(--t-med)] ${
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
            ${count > 0 ? html`<span class="ml-1 tabular-nums">${count}</span>` : null}
          </button>
        `
      })}
    </div>
  `
}
