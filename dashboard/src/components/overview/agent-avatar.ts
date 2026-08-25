// MASC Dashboard — Agent Avatar (design keeper-v2 `.sigil` renderer)
//
// SYNC CONTRACT (2026-08-23): renders the keeper-v2 `.sigil` monogram via
// <Sigil> (common/sigil-chip.ts) — the same renderer used by
// chat/primitives.ts, board/board-surface.ts, keeper-badge.ts,
// ide/ide-editor-ownership.ts and v2/primitives-v2.ts. The pixel-grid
// renderer (pixel-avatar.css + config/avatar-palettes.ts) and its overlays
// (activity dot, speech bubble, blocker ring, signal ring) were removed per
// docs/DESIGN-EXTRA-UI.md "Two avatar systems"; roster/profile rows carry
// that operational context in their own cells. Heartbeat mirrors the old
// animated statuses (running/active/working/busy), matching the design's
// PHASE_PULSE bucket (prototypes/keeper-v2/data.jsx).

import { html } from 'htm/preact'
import { Sigil } from '../common/sigil-chip'
import { kSlot, kSigil } from '../keeper-badge'

type AvatarSize = 'xs' | 'sm' | 'md' | 'lg' | 'xl'

interface AgentAvatarProps {
  name: string
  status?: string
  size?: AvatarSize
  onClick?: () => void
}

const SIZE_PX: Record<AvatarSize, number> = {
  xs: 20, // fusion dense master list (was the .fus-list 20px override)
  sm: 32,
  md: 48,
  lg: 64,
  xl: 96,
}

const HEARTBEAT_STATUSES = new Set(['running', 'active', 'working', 'busy'])

function handleKeyActivate(onClick?: () => void) {
  if (!onClick) return undefined
  return (e: KeyboardEvent) => {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault()
      onClick()
    }
  }
}

export function AgentAvatar({ name, status, size = 'md', onClick }: AgentAvatarProps) {
  const statusAttr = status ?? 'idle'
  const px = SIZE_PX[size]
  return html`
    <span
      class="v2-overview-avatar agent-avatar inline-flex"
      data-status=${statusAttr}
      title=${name}
      onClick=${onClick}
      onKeyDown=${handleKeyActivate(onClick)}
      role=${onClick ? 'button' : undefined}
      tabindex=${onClick ? '0' : undefined}
    >
      <${Sigil}
        slot=${kSlot(name)}
        size=${px}
        heartbeat=${HEARTBEAT_STATUSES.has(statusAttr)}
        title=${name}
      >${kSigil(name)}<//>
    </span>
  `
}
