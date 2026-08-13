import { readFileSync, readdirSync } from 'node:fs'
import { join, relative, resolve } from 'node:path'

import * as ts from 'typescript'
import { describe, expect, it } from 'vitest'
import { KEEPER_CHAT_CUSTOM_EVENT_NAMES } from './lib/keeper-chat-stream-contract'
import { SSE_EVENT_TYPES } from './types/sse-event-registry'

// Cross-boundary parity gate for the SSE event-type strings the dashboard
// routes by exact comparison or as a SIMPLE_ROUTES key. A backend rename or
// removal silently drops the FE
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
// The assertions are deliberately bilateral: every FE route has a producer or
// explicit external owner, and every registered backend producer has a FE
// route. SSEEventType itself is a closed sum derived from SSE_EVENT_TYPES.
// Schedule remains polling-only and is outside this server-push registry.
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
  broadcast: '../lib/mcp_tool_runtime_comm.ml',
  keeper_handoff: '../lib/keeper/keeper_unified_metrics_broadcast.ml',
  keeper_compaction: '../lib/keeper/keeper_unified_metrics_broadcast.ml',
  keeper_phase_changed: '../lib/keeper/keeper_registry.ml',
  'masc/board_post': '../lib/mcp_tool_runtime_board.ml',
  board_comment: '../lib/mcp_tool_runtime_board.ml',
  'masc/board_delete': '../lib/mcp_tool_runtime_board.ml',
  comment_added: '../lib/server/server_bootstrap_loops.ml',
  post_voted: '../lib/server/server_bootstrap_loops.ml',
  comment_voted: '../lib/server/server_bootstrap_loops.ml',
  reaction_changed: '../lib/server/server_bootstrap_loops.ml',
  internal_agent_runs_changed: '../lib/server/server_runtime_bootstrap.ml',
  'approval:audit': '../lib/keeper/keeper_gate.ml',
  'approval:pending': '../lib/keeper/keeper_approval_queue.ml',
  'approval:resolved': '../lib/keeper/keeper_approval_queue.ml',
  'approval:summary_updated': '../lib/keeper/keeper_approval_queue.ml',
  execution_snapshot: '../lib/server/server_dashboard_http_execution_surfaces.ml',
  runtime_param_changed: '../lib/server/server_routes_http_routes_activity.ml',
  keeper_chat_appended: '../lib/keeper/keeper_chat_broadcast.ml',
  keeper_waiting_inventory_changed: '../lib/keeper/keeper_waiting_inventory_broadcast.ml',
  keeper_compaction_snapshots_changed: '../lib/server/server_dashboard_http_keeper_api.ml',
  ide_cursor_changed: '../lib/server/server_ide_http.ml',
  keeper_composite_changed: '../lib/keeper/keeper_registry_broadcast.ml',
  keeper_heartbeat: '../lib/keeper/keeper_heartbeat_snapshot.ml',
  keeper_turn_complete: '../lib/keeper/keeper_hooks_agent_core.ml',
  agent_core_telemetry_sample: '../lib/runtime/dashboard_agent_core_bridge.ml',
  namespace_truth_snapshot: '../lib/server/server_dashboard_http_namespace_truth.ml',
  operator_digest: '../lib/server/server_dashboard_http_core_digest_refresh.ml',
  operator_snapshot: '../lib/server/server_dashboard_http_execution_surfaces.ml',
  post_created: '../lib/server/server_bootstrap_loops.ml',
  project_snapshot: '../lib/server/server_dashboard_http_namespace_truth.ml',
  transport_health_snapshot: '../lib/server/server_dashboard_http_execution_surfaces.ml',
  fusion_run_status: '../lib/fusion/fusion_sink.ml',
}

// The router normalizes these wire aliases before dispatch. Keep the route key
// in BACKEND_EMITTED and bind its exact producer literal here.
const BACKEND_WIRE_TYPE_ALIASES: Partial<Record<keyof typeof BACKEND_EMITTED, string>> = {
  broadcast: 'masc/broadcast',
}

// event-type -> why it has no masc backend literal to bind to. Keep short and
// justified; every entry is an event the FE routes but masc lib/ does not emit.
const FE_ONLY_OR_EXTERNAL: Record<string, string> = {
  agent_bound:
    'Workspace lifecycle wire alias consumed by the dashboard; the current masc backend has no direct literal emitter.',
  agent_unbound:
    'Workspace lifecycle wire alias consumed by the dashboard; the current masc backend has no direct literal emitter.',
  keeper_guardrail:
    'Agent/runtime guardrail event consumed by the dashboard; the current masc backend has no direct literal emitter.',
  board_post:
    'Legacy board alias; the current masc backend emits masc/board_post.',
  'masc/board_comment':
    'Namespaced board alias; the current masc backend emits board_comment.',
  board_delete:
    'Legacy board alias; the current masc backend emits masc/board_delete.',
  activity:
    'Dashboard activity invalidation signal; current backend activity updates use runtime_param_changed or activity_* events.',
  'agent_core:agent_failed':
    'Agent Core subsystem event bridged into the masc SSE stream, not emitted by masc lib/ (agent_core: prefix).',
  'agent_core:context_compacted':
    'Agent Core subsystem event bridged into the masc SSE stream, not emitted by masc lib/ (agent_core: prefix).',
}

function parseExportedStringConstants(source: string): Map<string, string> {
  const file = ts.createSourceFile('sse-event-registry.ts', source, ts.ScriptTarget.Latest, true)
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
        `SSE exact-route comparison references ${expression.text}, but sse-event-registry.ts does not export it as a string constant`,
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
    if (
      ts.isVariableDeclaration(node)
      && ts.isIdentifier(node.name)
      && node.name.text === 'SIMPLE_ROUTES'
      && node.initializer
    ) {
      const initializer = node.initializer
      if (!ts.isObjectLiteralExpression(initializer)) {
        throw new Error('SIMPLE_ROUTES must remain an object literal for parity extraction')
      }
      for (const property of initializer.properties) {
        if (!ts.isPropertyAssignment(property)) {
          throw new Error('SIMPLE_ROUTES entries must be explicit property assignments')
        }
        if (ts.isIdentifier(property.name) || ts.isStringLiteral(property.name)) {
          found.add(property.name.text)
          continue
        }
        throw new Error('SIMPLE_ROUTES keys must be identifier or string literals')
      }
    }
    if (ts.isBinaryExpression(node)) {
      const eventType = routedEventTypeFromBinaryExpression(node, exportedConstants)
      if (eventType) found.add(eventType)
    }
    ts.forEachChild(node, visit)
  }
  visit(file)
  return found
}

function mlFilesUnder(root: string): string[] {
  const files: string[] = []
  for (const entry of readdirSync(root, { withFileTypes: true })) {
    const path = join(root, entry.name)
    if (entry.isDirectory()) files.push(...mlFilesUnder(path))
    else if (entry.isFile() && entry.name.endsWith('.ml')) files.push(path)
  }
  return files
}

interface BackendEventEvidence {
  eventType: string
  sourceFile: string
}

const NON_DASHBOARD_BROADCAST_LITERALS = new Set([
  // lib/sse.ml transport framing, not dashboard payload event types.
  'lib/sse.ml:message',
  'lib/sse.ml:presence',
  // MCP content item in mcp_server_eio_call_tool.ml, not the adjacent
  // keeper_tool_call broadcast payload.
  'lib/mcp_server_eio_call_tool.ml:text',
])

function parseBackendEmittedEventTypes(libRoot: string): BackendEventEvidence[] {
  const evidence = new Map<string, string>()
  const candidatePattern = /Sse\.broadcast|sse_broadcast|broadcast_cached_surface|broadcast_run_status/
  const literalPatterns = [
    /"type"\s*,\s*`String\s*"([^"]+)"/g,
    /~event_type\s*:\s*"([^"]+)"/g,
    /let\s+[a-z0-9_]*(?:sse_)?event[a-z0-9_]*\s*=\s*"([^"]+)"/g,
  ]

  for (const sourcePath of mlFilesUnder(libRoot)) {
    const source = readFileSync(sourcePath, 'utf8')
    if (!candidatePattern.test(source)) continue
    const sourceFile = relative(resolve(process.cwd(), '..'), sourcePath)
    for (const [patternIndex, pattern] of literalPatterns.entries()) {
      for (const match of source.matchAll(pattern)) {
        const literal = match[1]
        if (!literal || NON_DASHBOARD_BROADCAST_LITERALS.has(`${sourceFile}:${literal}`)) continue
        const eventType = patternIndex === 1
          && sourceFile === 'lib/keeper/keeper_event_bridge.ml'
          ? `agent_core:${literal}`
          : literal
        evidence.set(eventType, sourceFile)
      }
    }
  }

  return [...evidence].map(([eventType, sourceFile]) => ({ eventType, sourceFile }))
}

const sseRegistrySource = readFileSync(resolve(process.cwd(), 'src/types/sse-event-registry.ts'), 'utf8')
const sseRegistryConstants = parseExportedStringConstants(sseRegistrySource)
const sseStoreSource = readFileSync(resolve(process.cwd(), 'src/sse-store.ts'), 'utf8')
const feRouted = parseFeRoutedEventTypes(sseStoreSource, sseRegistryConstants)
const backendEmitted = parseBackendEmittedEventTypes(resolve(process.cwd(), '../lib'))
const classified = new Set([
  ...Object.keys(BACKEND_EMITTED),
  ...Object.keys(FE_ONLY_OR_EXTERNAL),
])

describe('SSE event-type cross-boundary parity (exact-match routes)', () => {
  it('keeps the closed event registry duplicate-free', () => {
    expect(new Set(SSE_EVENT_TYPES).size).toBe(SSE_EVENT_TYPES.length)
  })

  it('extracts identifier and quoted SIMPLE_ROUTES keys', () => {
    const source = `
      const SIMPLE_ROUTES = {
        keeper_heartbeat: { target: 'execution' },
        'masc/board_post': { target: 'board' },
      }
    `
    expect([...parseFeRoutedEventTypes(source, new Map())].sort()).toEqual([
      'keeper_heartbeat',
      'masc/board_post',
    ])
  })

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

  it('registers every FE-routed event type in the closed frontend sum', () => {
    const registered = new Set<string>(SSE_EVENT_TYPES)
    const unregistered = [...feRouted].filter(t => !registered.has(t))
    expect(unregistered, `FE routes missing from SSE_EVENT_TYPES: ${unregistered.join(', ')}`).toEqual([])
  })

  it('routes every registered backend-emitted event on the FE', () => {
    const unrouted = Object.keys(BACKEND_EMITTED).filter(t => !feRouted.has(t))
    expect(unrouted, `backend events without FE routes: ${unrouted.join(', ')}`).toEqual([])
  })

  it('registers every backend-emitted event in the closed frontend sum', () => {
    const registered = new Set<string>(SSE_EVENT_TYPES)
    const unregistered = Object.keys(BACKEND_EMITTED)
      .map(t => BACKEND_WIRE_TYPE_ALIASES[t] ?? t)
      .filter(t => !registered.has(t))
    expect(unregistered, `backend events missing from SSE_EVENT_TYPES: ${unregistered.join(', ')}`).toEqual([])
  })

  it('source-parses a non-empty backend SSE emitter inventory', () => {
    expect(backendEmitted.map(({ eventType }) => eventType)).toEqual(
      expect.arrayContaining(['approval:pending', 'fusion_run_status', 'agent_core:turn_completed']),
    )
  })

  it('accepts every source-discovered backend SSE event in the closed frontend sum', () => {
    const registered = new Set<string>(SSE_EVENT_TYPES)
    const unregistered = backendEmitted.filter(({ eventType }) => !registered.has(eventType))
    expect(
      unregistered,
      `backend SSE emits unregistered event types: ${unregistered
        .map(({ eventType, sourceFile }) => `${eventType} (${sourceFile})`)
        .join(', ')}`,
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
      const wireType = BACKEND_WIRE_TYPE_ALIASES[eventType] ?? eventType
      expect(source).toContain(`"${wireType}"`)
    })
  }

  // Independent source extraction for the approval:* class. This is how
  // approval:summary_updated
  // shipped unrouted: the constant existed in schemas/sse.ts, the payload had
  // schema coverage, and nothing bound it to a refresh — so Auto Judge
  // verdicts settled invisibly until the 120-180s periodic sweep. Keep this
  // producer-side positive control in addition to the bilateral registry gate.
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
