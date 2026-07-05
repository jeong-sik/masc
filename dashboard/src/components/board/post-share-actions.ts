import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
import { Link2, Quote, Share2, Sparkles } from 'lucide-preact'
import { ActionButton } from '../common/button'
import { copyToClipboard } from '../common/copyable-code'
import { showToast } from '../common/toast'
import { requestBoardContextInference } from '../../api/board'
import { keepers } from '../../store'
import {
  boardPostPermalink,
  boardPostTrackbackMarkdown,
  boardPostXShareUrl,
} from '../../lib/board-utils'
import type { BoardPost } from './board-state'

function contextInferenceTargetKeeper(post: BoardPost): string | undefined {
  const identity = post.author_identity
  if (identity?.kind === 'keeper') {
    return identity.id?.trim() || identity.runtime_agent_name?.trim() || identity.raw?.trim() || post.author.trim() || undefined
  }
  const list = keepers.value
  return list[0]?.name || undefined
}

export function PostShareActions({ post, compact = false }: { post: BoardPost; compact?: boolean }) {
  const [contextPending, setContextPending] = useState(false)
  const permalink = boardPostPermalink(post.id)
  const trackback = boardPostTrackbackMarkdown(post)
  const xShareUrl = boardPostXShareUrl(post)
  const buttonClass = `v2-workspace-action !px-1.5 ${compact ? '!py-0.5' : '!py-1'}`

  const copyLink = async (event: Event) => {
    event.stopPropagation()
    const ok = await copyToClipboard(permalink)
    showToast(ok ? '게시글 링크를 복사했습니다' : '게시글 링크 복사에 실패했습니다', ok ? 'success' : 'error')
  }

  const copyTrackback = async (event: Event) => {
    event.stopPropagation()
    const ok = await copyToClipboard(trackback)
    showToast(ok ? '트랙백 링크를 복사했습니다' : '트랙백 링크 복사에 실패했습니다', ok ? 'success' : 'error')
  }

  const inferContext = async (event: Event) => {
    event.stopPropagation()
    if (contextPending) return
    setContextPending(true)
    try {
      const result = await requestBoardContextInference(post.id, contextInferenceTargetKeeper(post))
      showToast(`맥락 추론을 ${result.keeperName}에게 요청했습니다`, 'success')
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      showToast(`맥락 추론 요청에 실패했습니다: ${message}`, 'error')
    } finally {
      setContextPending(false)
    }
  }

  const targetKeeper = contextInferenceTargetKeeper(post)
  const isContextInferDisabled = contextPending || !targetKeeper
  const contextInferTooltip = targetKeeper
    ? `맥락 추론 요청 (${targetKeeper})`
    : '맥락 추론을 실행할 등록된 keeper가 없습니다'

  return html`
    <span
      class=${`inline-flex items-center gap-1 ${compact ? 'text-2xs' : 'text-xs'}`}
      data-testid=${`bd-share-${post.id}`}
      onClick=${(event: Event) => event.stopPropagation()}
      onKeyDown=${(event: KeyboardEvent) => event.stopPropagation()}
    >
      <${ActionButton}
        variant="ghost"
        size="sm"
        class=${buttonClass}
        ariaLabel=${`게시글 링크 복사: ${post.id}`}
        title="링크 복사"
        testId=${`bd-share-link-${post.id}`}
        onClick=${copyLink}
      ><${Link2} size=${13} strokeWidth=${2.2} aria-hidden="true" /><//>
      <${ActionButton}
        variant="ghost"
        size="sm"
        class=${buttonClass}
        ariaLabel=${`트랙백 링크 복사: ${post.id}`}
        title="트랙백 복사"
        testId=${`bd-share-trackback-${post.id}`}
        onClick=${copyTrackback}
      ><${Quote} size=${13} strokeWidth=${2.2} aria-hidden="true" /><//>
      <${ActionButton}
        variant="ghost"
        size="sm"
        class=${buttonClass}
        disabled=${isContextInferDisabled}
        ariaBusy=${contextPending}
        ariaLabel=${`맥락 추론 요청: ${post.id}`}
        title=${contextInferTooltip}
        testId=${`bd-context-infer-${post.id}`}
        onClick=${inferContext}
      ><${Sparkles} size=${13} strokeWidth=${2.2} aria-hidden="true" /><//>
      <a
        href=${xShareUrl}
        target="_blank"
        rel="noopener noreferrer"
        class=${`${buttonClass} inline-flex items-center justify-center rounded-md border border-solid border-border bg-transparent text-text-primary hover:bg-surface-subtle`}
        aria-label=${`X에 공유: ${post.id}`}
        title="X 공유"
        data-testid=${`bd-share-x-${post.id}`}
        onClick=${(event: Event) => event.stopPropagation()}
      >
        <${Share2} size=${13} strokeWidth=${2.2} aria-hidden="true" />
      </a>
    </span>
  `
}
