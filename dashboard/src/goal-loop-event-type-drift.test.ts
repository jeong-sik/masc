import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

import { describe, expect, it } from 'vitest'

// RFC-0284 review follow-up (parity-gate consistency exception).
//
// The `goal_loop_status` event type is a *slice-bridged* event: the frontend
// handles it in `hydrateDashboardSlice`'s eventType switch (`case 'X'`), NOT as
// an exact-match `event.type === 'X'` route. The sse-event-type-parity gate only
// inventories exact-match routes (its regex matches `event.type === 'X'`), so it
// does NOT track `goal_loop_status`. Its liveness instead depends on three raw
// string literals staying in sync across the boundary:
//
//   1. BE emit       — the event type definition broadcast over SSE
//   2. BE WS bridge  — the slice-bridge arm mapping it onto the "goals" slice
//   3. FE switch case — the hydrateDashboardSlice handler
//
// Rename one and live goal-loop updates break silently while every other test
// stays green — exactly the failure mode the parity gate was built to prevent
// for exact-match routes. This guard binds the three literals (plus the bridge
// target) so a one-sided rename turns red. RFC §7 rejects widening the
// exact-match contract surface, so this is a targeted drift guard rather than a
// parity-gate extension.
//
// BE paths are resolved from the dashboard cwd via `../lib/`. The CI Dashboard
// job runs on a full checkout, so the backend files resolve there too.

const EVENT_TYPE = 'goal_loop_status'

const sites = [
  [
    'BE emit (event type def)',
    '../lib/server/server_dashboard_http_goal_loop_broadcast.ml',
    `"${EVENT_TYPE}"`,
  ],
  [
    'BE WS slice bridge',
    '../lib/server/server_mcp_transport_ws.ml',
    `"${EVENT_TYPE}"`,
  ],
  [
    'FE hydrateDashboardSlice case',
    'src/sse-store.ts',
    `'${EVENT_TYPE}'`,
  ],
] as const

describe('goal_loop_status event-type cross-boundary drift guard (RFC-0284)', () => {
  for (const [label, file, literal] of sites) {
    it(`${label} carries the ${EVENT_TYPE} literal`, () => {
      const source = readFileSync(resolve(process.cwd(), file), 'utf8')
      expect(source).toContain(literal)
    })
  }

  it('the BE WS bridge maps goal_loop_status onto the existing goals slice', () => {
    const source = readFileSync(
      resolve(process.cwd(), '../lib/server/server_mcp_transport_ws.ml'),
      'utf8',
    )
    // The bridge arm (may wrap across lines):
    //   | "goal_loop_status" ->
    //       Some "goals"
    expect(source).toMatch(/"goal_loop_status"\s*->\s*Some\s+"goals"/)
  })
})
