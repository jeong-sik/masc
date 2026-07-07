// MASC Dashboard — CSS Pixel Art Avatar Component (Phase 2 enhanced)
// Renders an 8x8 grid avatar with deterministic colors from agent name.
// Now includes operational overlays: activity dot, speech bubble, blocker ring.

import { html } from 'htm/preact'
import {
  paletteForAgent,
  templateForAgent,
  PIXEL_TEMPLATES,
  type AvatarPalette,
} from '../../config/avatar-palettes'
import { trimText } from '../../lib/truncate'

type AvatarSize = 'sm' | 'md' | 'lg' | 'xl'

interface AgentAvatarProps {
  name: string
  status?: string
  traits?: string[]
  size?: AvatarSize
  showName?: boolean
  onClick?: () => void
  // Phase 2: operational info overlays
  currentWork?: string | null
  activityAge?: number | null
  hasBlocker?: boolean
  signalTruth?: 'live' | 'stale' | 'archived' | 'unknown'
  alwaysShowBubble?: boolean
}

function colorForCell(value: number, palette: AvatarPalette): string | null {
  switch (value) {
    case 1: return palette.skin
    case 2: return palette.hair
    case 3: return palette.point
    case 4: return palette.highlight
    default: return null
  }
}

function activityDotClass(ageSec: number | null): string {
  if (ageSec == null) return 'activity-dot--unknown'
  if (ageSec < 60) return 'activity-dot--live-pulse'
  if (ageSec < 300) return 'activity-dot--live'
  if (ageSec < 1800) return 'activity-dot--stale'
  return 'activity-dot--inactive'
}

function signalRingClass(truth?: string): string {
  if (truth === 'live') return 'signal-ring--live'
  if (truth === 'stale') return 'signal-ring--stale'
  if (truth === 'archived') return 'signal-ring--archived'
  return ''
}

function activityDotLabel(ageSec: number | null): string | undefined {
  if (ageSec == null) return undefined
  if (ageSec < 60) return '방금 활동'
  if (ageSec < 300) return '최근 활동'
  if (ageSec < 1800) return '잠시 비활성'
  return '비활성'
}

function handleKeyActivate(onClick?: () => void) {
  if (!onClick) return undefined
  return (e: KeyboardEvent) => {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault()
      onClick()
    }
  }
}

export function AgentAvatar({
  name,
  status,
  traits,
  size,
  showName,
  onClick,
  currentWork,
  activityAge,
  hasBlocker,
  signalTruth,
  alwaysShowBubble,
}: AgentAvatarProps) {
  const palette = paletteForAgent(name)
  const template = templateForAgent(name, traits)
  const grid = PIXEL_TEMPLATES[template]
  const sizeClass = size === 'sm' ? 'pixel-avatar--sm' : size === 'lg' ? 'pixel-avatar--lg' : size === 'xl' ? 'pixel-avatar--xl' : ''
  const statusAttr = status ?? 'idle'
  const blockerClass = hasBlocker ? 'pixel-avatar--has-blocker' : ''
  const ringClass = signalRingClass(signalTruth)

  const cells = []
  for (let i = 0; i < 64; i++) {
    const color = colorForCell(grid[i] ?? 0, palette)
    cells.push(
      html`<span
        class="pixel-avatar__cell"
        style=${{ background: color ?? 'transparent' }}
      />`
    )
  }

  const dotClass = activityDotClass(activityAge ?? null)
  const bubbleText = trimText(currentWork, 20)

  const avatar = html`
    <div
      class="v2-overview-avatar pixel-avatar rounded-[var(--r-1)] ${sizeClass} ${blockerClass} ${ringClass}"
      data-status=${statusAttr}
      title=${name}
      onClick=${onClick}
      onKeyDown=${handleKeyActivate(onClick)}
      role=${onClick ? 'button' : undefined}
      tabindex=${onClick ? '0' : undefined}
    >
      ${cells}
      <span
        class="pixel-avatar__activity-dot ${dotClass}"
        role=${activityDotLabel(activityAge ?? null) ? 'img' : undefined}
        aria-label=${activityDotLabel(activityAge ?? null)}
      />
      ${bubbleText ? html`
        <span class="pixel-avatar__speech-bubble rounded-[var(--r-1)] ${alwaysShowBubble ? 'always-visible' : ''}">
          ${bubbleText}
        </span>
      ` : null}
    </div>
  `

  if (!showName) return avatar

  const nameClass = statusAttr !== 'offline' && statusAttr !== 'inactive'
    ? 'pixel-avatar-name pixel-avatar-name--active'
    : 'pixel-avatar-name'

  return html`
    <div class="v2-overview-avatar pixel-avatar-wrap">
      ${avatar}
      <span class=${nameClass}>${name}</span>
    </div>
  `
}
