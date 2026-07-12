import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

import * as ts from 'typescript'
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
// wrong path throws ENOENT (loud fail), never a vacuous pass. The source parser
// uses TypeScript AST comparisons, so a suffix rename ("approval:pending:v2")
// does not satisfy "approval:pending".

// event-type -> the backend .ml that emits the quoted literal.
const BACKEND_EMITTED: Record<string, string> = {
  'approval:pending': '../lib/keeper/keeper_approval_queue.ml',
  'approval:resolved': '../lib/keeper/keeper_approval_queue.ml',
  execution_snapshot: '../lib/server/server_dashboard_http_execution_surfaces.ml',
  governance_param_changed: '../lib/server/server_routes_http_routes_activity.ml',
  keeper_chat_appended: '../lib/keeper/keeper_chat_broadcast.ml',
  keeper_chat_queue_changed: '../lib/keeper/keeper_chat_broadcast.ml',
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
})
