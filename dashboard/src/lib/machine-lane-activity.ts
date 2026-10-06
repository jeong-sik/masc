import { parseTOML, type AST } from 'toml-eslint-parser'
import type { LaneInventoryRow } from '../api/lane-inventory'
import { setRuntimeTomlKey } from './runtime-toml-config'

export type MachineActivityLane = Extract<LaneInventoryRow['selection'], { kind: 'machine' }>['machine']

function keyPath(key: AST.TOMLKey): string[] {
  return key.keys.map(part => part.type === 'TOMLBare' ? part.name : part.value)
}

function tableEntries(node: AST.TOMLTable | AST.TOMLContentNode, path: string): readonly AST.TOMLKeyValue[] {
  if (node.type === 'TOMLInlineTable' || (node.type === 'TOMLTable' && node.kind === 'standard'))
    return node.body
  throw new Error(`${path}는 TOML table이어야 합니다.`)
}

/** Match Machine_configuration: omitted flags are on, but unknown machines,
 * keys and non-booleans are errors. Full Runtime validation remains server-owned. */
export function readMachineActivity(source: string, lane: MachineActivityLane): { enabled: boolean } {
  const ast = parseTOML(source, { tomlVersion: '1.0' })
  const values = new Map<MachineActivityLane, boolean>([['msx', true], ['dos', true]])
  // Walk decoded AST paths, never a JavaScript object built from TOML keys.
  // getStaticTOMLValue's whole-document conversion follows inherited keys:
  // __proto__ can mutate Object.prototype before shape validation runs.
  const visit = (path: readonly string[], node: AST.TOMLTable | AST.TOMLContentNode): void => {
    if (path[0] !== 'machines') return
    const machine = path[1]
    if (machine !== undefined && machine !== 'msx' && machine !== 'dos')
      throw new Error(`machines.${machine}는 지원하지 않는 설정입니다.`)
    const field = path[2]
    if (field !== undefined && field !== 'enabled')
      throw new Error(`machines.${machine}.${field}는 지원하지 않는 설정입니다.`)
    if (field !== undefined) {
      if (path.length !== 3 || node.type !== 'TOMLValue' || node.kind !== 'boolean')
        throw new Error(`machines.${machine}.enabled는 true 또는 false여야 합니다.`)
      // Reaching a field necessarily passed the closed machine-name check.
      if (machine === 'msx' || machine === 'dos') values.set(machine, node.value)
      return
    }
    for (const entry of tableEntries(node, path.join('.')))
      visit([...path, ...keyPath(entry.key)], entry.value)
  }
  for (const node of ast.body[0].body) {
    if (node.type === 'TOMLTable') visit(keyPath(node.key), node)
    else visit(keyPath(node.key), node.value)
  }
  return { enabled: values.get(lane)! }
}

/** Parsed value ranges retain comments and support tables, dotted keys and
 * inline tables. Only the selected machine's enabled value is changed. */
export function writeMachineActivity(source: string, lane: MachineActivityLane, enabled: boolean): string {
  readMachineActivity(source, lane)
  const next = setRuntimeTomlKey(source, `machines.${lane}`, 'enabled', enabled)
  readMachineActivity(next, lane)
  return next
}
