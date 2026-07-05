// Board display utilities — shared between memory.ts and memory-post-detail.ts

/**
 * User-visible fallback shown when a board message arrives without a
 * `from` field — three board panels (state-block-messages,
 * mention-inbox, message-workspace-timeline) used to inline the literal
 * `'system'` in `row.message.from ?? 'system'`. Captured here so a
 * future relabel (e.g. localising to `'시스템'` or distinguishing
 * automation from system) updates every panel in one place.
 */
export const SYSTEM_MESSAGE_FROM = 'system'

/**
 * Stable list-item key for a board `Message` row at position `index`.
 *
 * Prefers the message's own id (set by the backend on durable posts).
 * Falls back to `<seq>-<index>` for unposted/draft rows where `id`
 * hasn't been assigned yet, with `'message'` as the seq placeholder.
 *
 * Two board panels (`mention-inbox`, `message-workspace-timeline`) shipped
 * this exact body file-internal as `rowKey`. A third (`state-block-messages`)
 * uses a different base (`id ?? seq ?? index` single chain) plus a
 * `state-block.slice(0, 24)` suffix and is left on its own helper —
 * a future change to its base policy can adopt this helper once the
 * suffix is parameterised.
 */
export function boardMessageRowKey(message: Message, index: number): string {
  return message.id ?? `${message.seq ?? 'message'}-${index}`
}

/**
 * One-line preview text for a board `Message`.
 *
 * Prefers the state-stripped content (so a message that's *only* a
 * state block falls through to either raw content or `'(empty)'`).
 * The state-only case is what differentiates this fallback chain from
 * the `state-block-messages` panel's variant, which intentionally
 * surfaces `'(state-only message)'` instead because that view is
 * specifically for state-block traffic.
 *
 * Two board panels (`mention-inbox`, `message-workspace-timeline`) shipped
 * this exact body file-internal as `previewContent`. The third panel
 * (`state-block-messages`) stays on its own variant — its empty branch
 * is `'(state-only message)'` rather than `'(empty)'`, and the fallback
 * chain skips the raw content step.
 */
export function previewBoardMessage(message: Message): string {
  return stripStateBlocks(message.content).trim() || message.content.trim() || '(empty)'
}

import { navigate } from '../router'
import type { Message } from '../types'
import { findKeeper } from './keeper-utils'
import { openKeeperDetail } from '../components/keeper-detail'
import { stripStateBlocks } from '../keeper-message'
import { clampPct } from './format-number'
import type { BoardActorIdentity, BoardContributorQuality, BoardPost } from '../types'

/** Strip inline markdown formatting from title text (bold, italic, code). */
export function stripInlineMarkdown(text: string): string {
  return text
    .replace(/\*\*(.+?)\*\*/g, '$1')
    .replace(/__(.+?)__/g, '$1')
    .replace(/\*(.+?)\*/g, '$1')
    .replace(/_(.+?)_/g, '$1')
    .replace(/`(.+?)`/g, '$1')
}

/**
 * preview 카드에서 본문 첫 heading이 title과 같은 내용이면 해당 heading 줄을 생략.
 *
 * post-detail은 title이 text-2xl(~24px)이라 본문 헤더가 section 역할을 하지만,
 * preview 카드는 title 타이포가 13.5px라 본문 h1(16px)/h2(14px)가 역전되어
 * "제목이 두 벌로, 그리고 더 크게" 보이는 현상의 원인이 된다. 미리보기 목적상
 * title과 중복되는 첫 헤더는 제거한다. title 요약 + body 전개 같은 의도적 구조는
 * heading 텍스트가 title과 다르면 그대로 유지된다.
 */
export function dedupeLeadingHeading(title: string, body: string): string {
  const normTitle = stripInlineMarkdown(title).trim().replace(/^#+\s*/, '')
  if (!normTitle) return body
  const heading = body.match(/^#{1,6}\s+(.+?)\s*$/m)
  if (heading && stripInlineMarkdown(heading[1] ?? '').trim() === normTitle) {
    return body.replace(/^#{1,6}\s+.+\n?/m, '')
  }
  return body
}

export function boardPostHash(postId: string): string {
  return `#board?post=${encodeURIComponent(postId)}`
}

export function boardPostPermalink(postId: string, baseHref?: string): string {
  const hash = boardPostHash(postId)
  const base = baseHref ?? (typeof window !== 'undefined' ? window.location.href : '')
  if (!base) return hash
  try {
    return new URL(hash, base).toString()
  } catch {
    return hash
  }
}

function boardPostDisplayTitle(post: Pick<BoardPost, 'id' | 'title'>): string {
  return stripInlineMarkdown(post.title).trim() || post.id
}

export function boardPostTrackbackMarkdown(
  post: Pick<BoardPost, 'id' | 'title'>,
  baseHref?: string,
): string {
  return `[${boardPostDisplayTitle(post)}](${boardPostPermalink(post.id, baseHref)})`
}

export function boardPostXShareUrl(
  post: Pick<BoardPost, 'id' | 'title'>,
  baseHref?: string,
): string {
  const params = new URLSearchParams({
    text: `${boardPostDisplayTitle(post)} - MASC Board`,
    url: boardPostPermalink(post.id, baseHref),
  })
  return `https://twitter.com/intent/tweet?${params.toString()}`
}

export function boardActorDisplayName(
  authorName: string,
  identity?: BoardActorIdentity | null,
): string {
  const displayName = identity?.display_name?.trim()
  return displayName || authorName
}

export function boardActorRuntimeName(
  authorName: string,
  identity?: BoardActorIdentity | null,
): string | null {
  const runtime = identity?.runtime_agent_name?.trim()
  if (runtime) return runtime
  const raw = identity?.raw?.trim()
  if (raw && raw !== authorName) return raw
  return null
}

export function boardActorAvatarKey(
  authorName: string,
  identity?: BoardActorIdentity | null,
): string {
  return identity?.key?.trim() || boardActorDisplayName(authorName, identity)
}

const GENERIC_ACTOR_SIGIL_KEYS = new Set([
  'agent',
  'keeper',
  'raw_agent',
  'unknown',
])

function firstSpecificActorLabel(candidates: Array<string | null | undefined>): string | null {
  for (const candidate of candidates) {
    const trimmed = candidate?.trim()
    if (!trimmed) continue
    if (GENERIC_ACTOR_SIGIL_KEYS.has(trimmed.toLowerCase())) continue
    return trimmed
  }
  return null
}

export function boardActorSigilLabel(
  authorName: string,
  identity?: BoardActorIdentity | null,
): string {
  return firstSpecificActorLabel([
    identity?.display_name,
    identity?.runtime_agent_name,
    identity?.id,
    identity?.raw,
    identity?.key,
    authorName,
  ]) ?? authorName
}

export function boardActorTitle(
  authorName: string,
  identity?: BoardActorIdentity | null,
): string | undefined {
  const runtime = boardActorRuntimeName(authorName, identity)
  const display = boardActorDisplayName(authorName, identity)
  return runtime && runtime !== display ? `런타임 ${runtime}` : undefined
}

export function contributorQualityPercent(quality?: BoardContributorQuality | null): number | null {
  if (!contributorQualityHasEvidence(quality)) return null
  const score = contributorQualityDisplayScore(quality)
  return score === null ? null : clampPct(Math.round(score * 100))
}

export function contributorQualityBandLabel(quality?: BoardContributorQuality | null): string {
  switch (contributorQualityDisplayBand(quality)) {
    case 'excellent':
      return '우수'
    case 'strong':
      return '강함'
    case 'watch':
      return '관찰'
    case 'low':
      return '낮음'
    default:
      return '품질'
  }
}

export function contributorQualityBadgeClass(quality?: BoardContributorQuality | null): string {
  switch (contributorQualityDisplayBand(quality)) {
    case 'excellent':
    case 'strong':
      return 'bg-[var(--ok-10)] text-[var(--ok-fg)] border-[var(--ok-20)]'
    case 'watch':
      return 'bg-[var(--warn-10)] text-[var(--warn-bright)] border-[var(--warn-20)]'
    case 'low':
      return 'bg-[var(--bad-10)] text-[var(--bad-light)] border-[var(--bad-20)]'
    default:
      return 'bg-[var(--color-bg-muted)] text-[var(--color-fg-muted)] border-[var(--color-border-divider)]'
  }
}

function contributorQualityDisplayScore(
  quality?: BoardContributorQuality | null,
): number | null {
  if (!quality) return null
  const legacyScore = quality.score
  if (legacyScore !== undefined && Number.isFinite(legacyScore)) return legacyScore
  const accountabilityScore = quality.accountability_score
  if (accountabilityScore !== undefined && Number.isFinite(accountabilityScore)) {
    return accountabilityScore
  }
  return null
}

function contributorQualityDisplayBand(
  quality?: BoardContributorQuality | null,
): BoardContributorQuality['band'] | null {
  if (quality?.band) return quality.band
  return null
}

function contributorQualityHasEvidence(quality?: BoardContributorQuality | null): boolean {
  if (!quality) return false
  if (quality.evidence_state !== undefined) {
    return quality.evidence_state === 'measured'
  }
  if (quality.band) return true
  if (quality.score !== undefined && Number.isFinite(quality.score)) return true
  if ((quality.board_posts ?? 0) > 0) return true
  if ((quality.board_comments ?? 0) > 0) return true
  if ((quality.completion_rate ?? 0) > 0) return true
  if ((quality.response_rate ?? 0) > 0) return true

  const DEFAULT_ACCOUNTABILITY_SCORE = 1.0
  const DEFAULT_THOMPSON_CONFIDENCE = 0.5
  const DEFAULT_AUTONOMY_LEVEL = 'standard'

  if (quality.accountability_score !== undefined && quality.accountability_score < DEFAULT_ACCOUNTABILITY_SCORE) return true
  if (quality.thompson_confidence !== undefined && quality.thompson_confidence !== DEFAULT_THOMPSON_CONFIDENCE) return true
  return quality.autonomy_level !== undefined && quality.autonomy_level !== DEFAULT_AUTONOMY_LEVEL
}

/** Navigate to keeper detail if author is a keeper, otherwise agent profile. */
export function navigateToAuthor(
  authorName: string,
  event?: Event,
  identity?: BoardActorIdentity | null,
) {
  event?.stopPropagation()
  const keeper =
    identity?.kind === 'keeper'
      ? findKeeper(identity.id) ?? findKeeper(identity.raw) ?? findKeeper(authorName)
      : findKeeper(authorName)
  if (keeper) {
    openKeeperDetail(keeper)
  } else {
    navigate('monitoring', { section: 'agents', agent: identity?.raw ?? authorName })
  }
}
