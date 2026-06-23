import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

import { describe, expect, it } from 'vitest'

// Cross-boundary parity gate for the SSE event-type strings the dashboard
// routes by EXACT MATCH (`event.type === 'X'` in sse-store.ts). These are the
// approval-class events: a backend rename or removal silently drops the FE
// handler (the badge/feature stops updating) while the test suite stays green,
// because nothing binds the FE literal to the backend emit. PR #22115 fixed
// this for approval:pending / approval:resolved; this generalizes it to every
// exact-match-routed event type.
//
// Each FE-routed event type must be CLASSIFIED below: either it is emitted by a
// masc backend .ml (BACKEND_EMITTED — a rename fails the literal assertion) or
// it is a documented FE-only / external-subsystem event (FE_ONLY_OR_EXTERNAL).
// The FE inventory is PARSED from sse-store.ts and asserted to equal the union
// of both maps, so a new exact-match route forces a classification here instead
// of slipping through unclassified.
//
// Scope (interim, RFC-0049 parity-gate precedent): FE -> backend direction only
// — every FE-routed type must be backend-emitted-or-excepted. The reverse
// (backend emits a type the FE never handles) and full compile-time enforcement
// (closed event-type sum + typed broadcast API + raw-string ban) are the
// keystone, tracked separately (MASC task-1478 sibling / RFC-0004 increment).
//
// vitest cwd = dashboard/, so backend sources are one level up under ../lib. A
// wrong path throws ENOENT (loud fail), never a vacuous pass. The closing quote
// in the assertion anchors the match so a suffix rename ("approval:pending:v2")
// does not satisfy "approval:pending".

// event-type -> the backend .ml that emits the quoted literal.
const BACKEND_EMITTED: Record<string, string> = {
  'approval:pending': '../lib/keeper/keeper_approval_queue.ml',
  'approval:resolved': '../lib/keeper/keeper_approval_queue.ml',
  execution_snapshot: '../lib/server/server_dashboard_http_execution_surfaces.ml',
  governance_param_changed: '../lib/server/server_routes_http_routes_activity.ml',
  keeper_chat_appended: '../lib/keeper/keeper_chat_broadcast.ml',
  keeper_composite_changed: '../lib/server/server_mcp_transport_ws.ml',
  keeper_heartbeat: '../lib/keeper/keeper_heartbeat_snapshot.ml',
  keeper_turn_complete: '../lib/keeper/keeper_hooks_oas.ml',
  namespace_truth_snapshot: '../lib/server/server_mcp_transport_ws.ml',
  operator_digest: '../lib/server/server_dashboard_http_core_digest_refresh.ml',
  operator_snapshot: '../lib/server/server_mcp_transport_ws.ml',
  post_created: '../lib/keeper_runtime/keeper_event_queue.ml',
  project_snapshot: '../lib/server/server_mcp_transport_ws.ml',
  transport_health_snapshot: '../lib/server/server_dashboard_http_execution_surfaces.ml',
}

// event-type -> why it has no masc backend literal to bind to. Keep short and
// justified; every entry is an event the FE routes but masc lib/ does not emit.
const FE_ONLY_OR_EXTERNAL: Record<string, string> = {
  'oas:agent_failed':
    'OAS-subsystem event bridged into the masc SSE stream, not emitted by masc lib/ (oas: prefix).',
}

function parseFeRoutedEventTypes(source: string): Set<string> {
  // The exact-match routing forms in sse-store.ts:
  //   event.type === 'X'
  //   routedType === 'X'
  //   normalizeMascEventType(event.type) === 'X'
  const re =
    /(?:event\.type|routedType|normalizeMascEventType\(event\.type\)) === '([a-zA-Z0-9_:/]+)'/g
  const found = new Set<string>()
  for (const m of source.matchAll(re)) {
    const eventType = m[1]
    if (eventType) found.add(eventType)
  }
  return found
}

const sseStoreSource = readFileSync(resolve(process.cwd(), 'src/sse-store.ts'), 'utf8')
const feRouted = parseFeRoutedEventTypes(sseStoreSource)
const classified = new Set([
  ...Object.keys(BACKEND_EMITTED),
  ...Object.keys(FE_ONLY_OR_EXTERNAL),
])

describe('SSE event-type cross-boundary parity (exact-match routes)', () => {
  it('parses a non-empty FE exact-match routing inventory', () => {
    // Guard against a regex/refactor that silently makes the gate vacuous.
    expect(feRouted.size).toBeGreaterThanOrEqual(Object.keys(BACKEND_EMITTED).length)
  })

  it('classifies every FE-routed event type (no unclassified routes)', () => {
    const unclassified = [...feRouted].filter(t => !classified.has(t))
    expect(
      unclassified,
      `unclassified FE-routed event types (add to BACKEND_EMITTED or FE_ONLY_OR_EXTERNAL): ${unclassified.join(', ')}`,
    ).toEqual([])
  })

  it('has no stale classification (every classified type is still FE-routed)', () => {
    const stale = [...classified].filter(t => !feRouted.has(t))
    expect(stale, `classified but no longer FE-routed (remove from maps): ${stale.join(', ')}`).toEqual(
      [],
    )
  })

  for (const [eventType, backendFile] of Object.entries(BACKEND_EMITTED)) {
    it(`backend ${backendFile.replace('../', '')} still emits "${eventType}"`, () => {
      const source = readFileSync(resolve(process.cwd(), backendFile), 'utf8')
      expect(source).toContain(`"${eventType}"`)
    })
  }
})
