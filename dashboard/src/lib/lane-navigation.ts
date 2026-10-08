import { parseTOML, type AST } from 'toml-eslint-parser'
import { LANE_IDS } from '../api/dashboard-standalone-lanes'
import type { LaneInventoryRow } from '../api/lane-inventory'

export type LaneNavigationTarget = { workspace: string } & (
  | { kind: 'exact'; lane: typeof LANE_IDS[number] }
  | { kind: 'browser'; lane: 'live' | 'automation' | 'stagehand' }
  | { kind: 'machine'; machine: 'msx' | 'dos' }
  | { kind: 'declaration'; path: string; installation: string | null }
  | { kind: 'instance'; instance: string; incarnation: string }
)
export type RuntimeLaneTarget = Extract<LaneNavigationTarget, { kind: 'exact' | 'browser' | 'machine' }>
export type ParsedLaneTarget = { kind: 'none' } | { kind: 'invalid'; message: string } | { kind: 'target'; target: LaneNavigationTarget }
const text = (value: unknown): value is string => typeof value === 'string' && value.length > 0
export function parseLaneTarget(raw: string | undefined): ParsedLaneTarget {
  if (raw === undefined) return { kind: 'none' }
  try {
    const value: unknown = JSON.parse(raw)
    if (typeof value !== 'object' || value === null || Array.isArray(value)) throw new Error()
    const fields = value as Record<string, unknown>
    if (!text(fields.workspace)) throw new Error()
    let target: LaneNavigationTarget
    switch (fields.kind) {
      case 'exact':
        if (!LANE_IDS.some(lane => lane === fields.lane)) throw new Error()
        target = { kind: 'exact', workspace: fields.workspace, lane: fields.lane as typeof LANE_IDS[number] }; break
      case 'browser':
        if (fields.lane !== 'live' && fields.lane !== 'automation' && fields.lane !== 'stagehand') throw new Error()
        target = { kind: 'browser', workspace: fields.workspace, lane: fields.lane }; break
      case 'machine':
        if (fields.machine !== 'msx' && fields.machine !== 'dos') throw new Error()
        target = { kind: 'machine', workspace: fields.workspace, machine: fields.machine }; break
      case 'declaration':
        if (!text(fields.path) || fields.installation !== null && !text(fields.installation)) throw new Error()
        target = { kind: 'declaration', workspace: fields.workspace, path: fields.path, installation: fields.installation }; break
      case 'instance':
        if (!text(fields.instance) || !text(fields.incarnation)) throw new Error()
        target = { kind: 'instance', workspace: fields.workspace, instance: fields.instance, incarnation: fields.incarnation }; break
      default: throw new Error()
    }
    if (Object.keys(fields).length !== Object.keys(target).length || Object.keys(fields).some(key => !Object.hasOwn(target, key))) throw new Error()
    return { kind: 'target', target }
  } catch { return { kind: 'invalid', message: 'The Lane link has an invalid or incomplete target.' } }
}

export function laneTargetFor(row: LaneInventoryRow, workspace: string): LaneNavigationTarget {
  const selection = row.selection
  switch (selection.kind) {
    case 'exact': return { workspace, kind: 'exact', lane: selection.lane_id }
    case 'browser': return { workspace, kind: 'browser', lane: selection.lane }
    case 'machine': return { workspace, kind: 'machine', machine: selection.machine }
    case 'manual_instance': return { workspace, kind: 'instance', instance: selection.instance_id, incarnation: selection.incarnation }
    case 'declaration': return { workspace, kind: 'declaration', path: selection.source_path,
      installation: row.state.kind === 'package' && row.state.declaration?.kind === 'valid' ? row.state.declaration.installation_id : null }
  }
}
export function laneTargetParams(target: LaneNavigationTarget, diagnostics = false): Record<string, string> {
  return { section: diagnostics ? 'internal-agents' : target.kind === 'declaration' || target.kind === 'instance' ? 'lane-addons' : 'runtime',
    ...(!diagnostics && target.kind !== 'declaration' && target.kind !== 'instance' ? { view: 'config' } : {}), lane_target: JSON.stringify(target) }
}
export function laneTargetLabel(target: LaneNavigationTarget): string {
  switch (target.kind) {
    case 'exact': return target.lane
    case 'browser': return `browser.${target.lane}`
    case 'machine': return `machines.${target.machine}`
    case 'declaration': return target.path
    case 'instance': return `${target.instance} · incarnation ${target.incarnation}`
  }
}

export function declarationIdentity(source: string): string {
  const ast = parseTOML(source, { tomlVersion: '1.0' })
  for (const node of ast.body[0].body) {
    if (node.type !== 'TOMLKeyValue' || node.key.keys.length !== 1) continue
    const key = node.key.keys[0]!
    if ((key.type === 'TOMLBare' ? key.name : key.value) === 'id'
      && node.value.type === 'TOMLValue' && node.value.kind === 'string' && node.value.value.trim()) return node.value.value
  }
  throw new Error('The file installation ID is not confirmed.')
}

/** Select the decoded TOML node in the existing draft; never search its text
 * for a header or insert configuration while navigating. */
export function runtimeTargetRange(source: string, target: Exclude<RuntimeLaneTarget, { kind: 'exact' }>): [number, number] | null {
  const wanted = target.kind === 'browser' ? ['browser', target.lane] : ['machines', target.machine]
  const ast = parseTOML(source, { tomlVersion: '1.0' })
  let exact: [number, number] | null = null, flatAutomation: [number, number] | null = null
  const visit = (path: string[], node: AST.TOMLTable | AST.TOMLKeyValue) => {
    const full = [...path, ...node.key.keys.map(part => part.type === 'TOMLBare' ? part.name : part.value)]
    if (full[0] !== wanted[0]) return
    if (full[1] === wanted[1]) exact ??= node.range
    if (target.kind === 'browser' && target.lane === 'automation' && full.length === 2
      && (full[1] === 'geckodriver' || full[1] === 'binary')) flatAutomation ??= node.range
    if (node.type === 'TOMLKeyValue' && node.value.type === 'TOMLInlineTable')
      for (const entry of node.value.body) visit(full, entry)
  }
  for (const node of ast.body[0].body) {
    visit([], node)
    if (node.type === 'TOMLTable') {
      const base = node.key.keys.map(part => part.type === 'TOMLBare' ? part.name : part.value)
      for (const entry of node.body) visit(base, entry)
    }
  }
  return exact ?? flatAutomation
}
