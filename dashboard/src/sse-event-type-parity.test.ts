import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

import * as ts from 'typescript'
import { describe, expect, it } from 'vitest'
import { KEEPER_CHAT_CUSTOM_EVENT_NAMES } from './lib/keeper-chat-stream-contract'

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
// wrong path throws ENOENT (loud fail), never a vacuous pass. The source parser
// uses TypeScript AST comparisons, so a suffix rename ("approval:pending:v2")
// does not satisfy "approval:pending".

// event-type -> the backend .ml that EMITS the quoted literal.
//
// Emits, not merely mentions. A consumer that matches on the same literal
// satisfies the assertion just as well as the producer does, and binding one
// here makes the gate green while the real emitter is free to rename -- which
// is the exact failure this file exists to prevent. Four entries pointed at
// server_mcp_transport_ws.ml, whose dashboard_slice_for_sse_type matches these
// literals to pick a delta slice; it reads them, it does not emit them.
//
// When adding an entry, find the site that builds the broadcast payload
// (`"type", `String "..."` or `~event_type:"..."`), not the site that branches
// on it.
const BACKEND_EMITTED: Record<string, string> = {
  'approval:audit': '../lib/keeper/keeper_gate.ml',
  'approval:pending': '../lib/keeper/keeper_approval_queue.ml',
  'approval:resolved': '../lib/keeper/keeper_approval_queue.ml',
  'approval:summary_updated': '../lib/keeper/keeper_approval_queue.ml',
  execution_snapshot: '../lib/server/server_dashboard_http_execution_surfaces.ml',
  runtime_param_changed: '../lib/server/server_routes_http_routes_activity.ml',
  keeper_chat_appended: '../lib/keeper/keeper_chat_broadcast.ml',
  keeper_waiting_inventory_changed: '../lib/keeper/keeper_waiting_inventory_broadcast.ml',
  ide_cursor_changed: '../lib/server/server_ide_http.ml',
  keeper_composite_changed: '../lib/keeper/keeper_registry_broadcast.ml',
  keeper_heartbeat: '../lib/keeper/keeper_heartbeat_snapshot.ml',
  keeper_turn_complete: '../lib/keeper/keeper_hooks_agent_core.ml',
  agent_core_telemetry_sample: '../lib/runtime/dashboard_agent_core_bridge.ml',
  operator_digest: '../lib/server/server_dashboard_http_core_digest_refresh.ml',
  operator_snapshot: '../lib/server/server_dashboard_http_execution_surfaces.ml',
  post_created: '../lib/keeper_runtime/keeper_event_queue.ml',
  project_snapshot: '../lib/server/server_dashboard_http_namespace_truth.ml',
  transport_health_snapshot: '../lib/server/server_dashboard_http_execution_surfaces.ml',
  fusion_run_status: '../lib/fusion/fusion_sink.ml',
  workspace_message_delivery_changed: '../lib/server/server_bootstrap_loops.ml',
}

// event-type -> why it has no masc backend literal to bind to. Keep short and
// justified; every entry is an event the FE routes but masc lib/ does not emit.
const FE_ONLY_OR_EXTERNAL: Record<string, string> = {
  'agent_core:agent_failed':
    'Agent Core subsystem event bridged into the masc SSE stream, not emitted by masc lib/ (agent_core: prefix).',
}

function parseExportedStringConstants(source: string): Map<string, string> {
  const file = ts.createSourceFile('schemas/sse.ts', source, ts.ScriptTarget.Latest, true)
  const constants = new Map<string, string>()
  for (const statement of file.statements) {
    if (!ts.isVariableStatement(statement)) continue
    const exported = statement.modifiers?.some(modifier => modifier.kind === ts.SyntaxKind.ExportKeyword)
    if (!exported) continue
    for (const declaration of statement.declarationList.declarations) {
      if (!ts.isIdentifier(declaration.name) || !declaration.initializer) continue
      if (ts.isStringLiteral(declaration.initializer)) {
        constants.set(declaration.name.text, declaration.initializer.text)
      }
    }
  }
  return constants
}

function isEventTypeAccess(expression: ts.Expression): boolean {
  return (
    ts.isPropertyAccessExpression(expression)
    && ts.isIdentifier(expression.expression)
    && expression.expression.text === 'event'
    && expression.name.text === 'type'
  )
}

function isNormalizeEventTypeCall(expression: ts.Expression): boolean {
  if (!ts.isCallExpression(expression)) return false
  const argument = expression.arguments[0]
  return (
    ts.isIdentifier(expression.expression)
    && expression.expression.text === 'normalizeMascEventType'
    && expression.arguments.length === 1
    && argument !== undefined
    && isEventTypeAccess(argument)
  )
}

function isExactRouteOperand(expression: ts.Expression): boolean {
  return (
    isEventTypeAccess(expression)
    || (ts.isIdentifier(expression) && expression.text === 'routedType')
    || isNormalizeEventTypeCall(expression)
  )
}

function routedEventTypeFromExpression(
  expression: ts.Expression,
  exportedConstants: ReadonlyMap<string, string>,
): string | null {
  if (ts.isStringLiteral(expression)) return expression.text
  if (ts.isIdentifier(expression)) {
    const value = exportedConstants.get(expression.text)
    if (!value) {
      throw new Error(
        `SSE exact-route comparison references ${expression.text}, but schemas/sse.ts does not export it as a string constant`,
      )
    }
    return value
  }
  return null
}

function routedEventTypeFromBinaryExpression(
  expression: ts.BinaryExpression,
  exportedConstants: ReadonlyMap<string, string>,
): string | null {
  if (expression.operatorToken.kind !== ts.SyntaxKind.EqualsEqualsEqualsToken) return null
  if (isExactRouteOperand(expression.left)) {
    return routedEventTypeFromExpression(expression.right, exportedConstants)
  }
  if (isExactRouteOperand(expression.right)) {
    return routedEventTypeFromExpression(expression.left, exportedConstants)
  }
  return null
}

function parseFeRoutedEventTypes(
  source: string,
  exportedConstants: ReadonlyMap<string, string>,
): Set<string> {
  const found = new Set<string>()
  const file = ts.createSourceFile('sse-store.ts', source, ts.ScriptTarget.Latest, true)
  function visit(node: ts.Node): void {
    if (ts.isBinaryExpression(node)) {
      const eventType = routedEventTypeFromBinaryExpression(node, exportedConstants)
      if (eventType) found.add(eventType)
    }
    ts.forEachChild(node, visit)
  }
  visit(file)
  return found
}

const sseSchemaSource = readFileSync(resolve(process.cwd(), 'src/schemas/sse.ts'), 'utf8')
const sseSchemaConstants = parseExportedStringConstants(sseSchemaSource)
const sseStoreSource = readFileSync(resolve(process.cwd(), 'src/sse-store.ts'), 'utf8')
const feRouted = parseFeRoutedEventTypes(sseStoreSource, sseSchemaConstants)
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

  // Reverse direction, scoped to the approval:* class. The interim scope note
  // at the top of this file excludes "backend emits a type the FE never
  // handles", and that exclusion is exactly how approval:summary_updated
  // shipped unrouted: the constant existed in schemas/sse.ts, the payload had
  // schema coverage, and nothing bound it to a refresh — so Auto Judge
  // verdicts settled invisibly until the 120-180s periodic sweep. Full-surface
  // reverse parity remains the closed-sum keystone's job; this pins the one
  // class the HITL queue's liveness depends on.
  const backendApprovalEvents = ((): string[] => {
    const source = readFileSync(
      resolve(process.cwd(), '../lib/keeper/keeper_approval_queue.ml'),
      'utf8',
    )
    const found = new Set<string>()
    for (const match of source.matchAll(/"(approval:[a-z_]+)"/g)) {
      const eventType = match[1]
      if (eventType !== undefined) found.add(eventType)
    }
    return [...found]
  })()

  it('parses a non-empty backend approval:* inventory', () => {
    // Positive control: a rename or regex drift that matches nothing must fail
    // loud here rather than vacuously pass the assertion below.
    expect(backendApprovalEvents).toContain('approval:pending')
  })

  it('routes every backend-emitted approval:* event on the FE', () => {
    const unrouted = backendApprovalEvents.filter(t => !feRouted.has(t))
    expect(
      unrouted,
      `backend emits these approval events but sse-store.ts never routes them, so the HITL queue will not refresh on them: ${unrouted.join(', ')}`,
    ).toEqual([])
  })
})

describe('Keeper chat custom-event cross-language parity', () => {
  const projectorSource = readFileSync(
    resolve(process.cwd(), '../lib/server/server_keeper_chat_agui_projection.ml'),
    'utf8',
  )
  const streamRouteSource = readFileSync(
    resolve(process.cwd(), '../lib/server/server_routes_http_keeper_stream.ml'),
    'utf8',
  )
  const mappingStart = projectorSource.indexOf('let custom_event_name_to_string = function')
  const mappingEnd = projectorSource.indexOf('\nlet custom ', mappingStart)
  const mappingSource = projectorSource.slice(mappingStart, mappingEnd)
  const ocamlNames = [...`${mappingSource}\n${streamRouteSource}`.matchAll(/"(KEEPER_[A-Z_]+)"/g)]
    .map(match => match[1])
    .filter((name): name is string => name !== undefined)

  it('binds the OCaml wire codec to the Dashboard vocabulary', () => {
    expect(mappingStart).toBeGreaterThanOrEqual(0)
    expect(mappingEnd).toBeGreaterThan(mappingStart)
    expect([...new Set(ocamlNames)].sort()).toEqual([...KEEPER_CHAT_CUSTOM_EVENT_NAMES].sort())
  })

  it('has no open Keeper_chat_events custom constructor', () => {
    const eventSource = readFileSync(
      resolve(process.cwd(), '../lib/keeper/keeper_chat_events.ml'),
      'utf8',
    )
    expect(eventSource).not.toMatch(/\|\s*Custom\s+of/)
  })
})
