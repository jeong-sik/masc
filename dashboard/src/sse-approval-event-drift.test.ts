import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

import { describe, expect, it } from 'vitest'

// HITL approval SSE events (`approval:pending` / `approval:resolved`) are NOT
// part of the atdts-generated event registry (sse_event_generated.ts): they are
// raw event-type strings emitted by the OCaml backend (keeper_approval_queue.ml
// broadcast_pending/broadcast_resolved) and matched by raw string literals in
// the frontend router (sse-store.ts routeServerPushEvent). With no shared
// codegen SSOT, a rename on either side silently breaks the always-visible
// nav-rail/topbar approval badge — the pending-approval signal routes through
// these exact strings, so a drift drops the badge to 0 with the test suite
// still green.
//
// The other approval test in sse-store.test.ts pins only the frontend routing
// (it sends the FE literal to a FE handler). This test closes the gap by
// binding BOTH sources to the same literals, so a rename on either side fails
// CI loudly. The closing quote is part of the asserted substring on purpose: a
// suffix rename like "approval:pending:v2" must NOT satisfy "approval:pending"
// (a bare substring match would let that drift through). OCaml string literals
// are double-quoted and the dashboard's house style is single-quoted, so each
// side's quote is stable under its formatter.
//
// vitest for the dashboard runs with cwd = dashboard/, so the backend source is
// one level up under lib/. A wrong path throws ENOENT (loud fail), never a
// vacuous pass. Deeper fix — move these events into the .atd registry so both
// sides reference one generated constant — is tracked separately.

const APPROVAL_EVENT_TYPES = ['approval:pending', 'approval:resolved'] as const

const backendSource = readFileSync(
  resolve(process.cwd(), '../lib/keeper/keeper_approval_queue.ml'),
  'utf8',
)
const frontendRouterSource = readFileSync(
  resolve(process.cwd(), 'src/sse-store.ts'),
  'utf8',
)

describe('HITL approval SSE event-type cross-boundary contract', () => {
  for (const eventType of APPROVAL_EVENT_TYPES) {
    it(`backend keeper_approval_queue.ml still emits "${eventType}"`, () => {
      expect(backendSource).toContain(`"${eventType}"`)
    })

    it(`frontend sse-store.ts still routes '${eventType}'`, () => {
      expect(frontendRouterSource).toContain(`'${eventType}'`)
    })
  }
})
