// RFC-0266 §7 — fusion run status helpers.
//
// The registry status panel these helpers once backed was merged into the
// FusionSurface master list (one list for board-sink + registry-only runs), so
// only the pure status→tone/text mappers remain here. They are the single source
// of truth for the closed registry status enum, reused by the sidebar
// registry row and the registry-only detail placeholder in fusion-surface.ts.

import type { FusionRunStatusLabel } from '../../api/dashboard'

type StatusTone = 'ok' | 'warn' | 'bad'

// Reuses the existing `.fus-status.tone-*` chip. `running` is `warn` (drawing the
// eye to active work), `completed` `ok`, `failed` `bad`.
export function fusionRunStatusTone(status: FusionRunStatusLabel): StatusTone {
  switch (status) {
    case 'running':
      return 'warn'
    case 'completed':
      return 'ok'
    case 'failed':
      return 'bad'
  }
}

export function fusionRunStatusText(status: FusionRunStatusLabel): string {
  switch (status) {
    case 'running':
      return 'running'
    case 'completed':
      return 'completed'
    case 'failed':
      return 'failed'
  }
}
