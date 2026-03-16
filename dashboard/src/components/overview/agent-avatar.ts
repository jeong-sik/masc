// MASC Dashboard — CSS Pixel Art Avatar Component
// Renders an 8x8 grid avatar with deterministic colors from agent name.

import { html } from 'htm/preact'
import {
  paletteForAgent,
  templateForAgent,
  PIXEL_TEMPLATES,
  type AvatarPalette,
} from '../../config/avatar-palettes'

type AvatarSize = 'sm' | 'md' | 'lg'

interface AgentAvatarProps {
  name: string
  status?: string
  traits?: string[]
  size?: AvatarSize
  showName?: boolean
  onClick?: () => void
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

export function AgentAvatar({ name, status, traits, size, showName, onClick }: AgentAvatarProps) {
  const palette = paletteForAgent(name)
  const template = templateForAgent(name, traits)
  const grid = PIXEL_TEMPLATES[template]
  const sizeClass = size === 'sm' ? 'pixel-avatar--sm' : size === 'lg' ? 'pixel-avatar--lg' : ''
  const statusAttr = status ?? 'idle'

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

  const avatar = html`
    <div
      class="pixel-avatar ${sizeClass}"
      data-status=${statusAttr}
      title=${name}
      onClick=${onClick}
      role=${onClick ? 'button' : undefined}
      tabindex=${onClick ? '0' : undefined}
    >
      ${cells}
    </div>
  `

  if (!showName) return avatar

  const nameClass = statusAttr !== 'offline' && statusAttr !== 'inactive'
    ? 'pixel-avatar-name pixel-avatar-name--active'
    : 'pixel-avatar-name'

  return html`
    <div class="pixel-avatar-wrap">
      ${avatar}
      <span class=${nameClass}>${name}</span>
    </div>
  `
}
