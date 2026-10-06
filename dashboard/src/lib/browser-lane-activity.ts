import { parseTOML, type AST } from 'toml-eslint-parser'
import type { LaneInventoryRow } from '../api/lane-inventory'
import { deleteRuntimeTomlKey, setRuntimeTomlKey } from './runtime-toml-config'

export type BrowserActivityLane = Extract<LaneInventoryRow['selection'], { kind: 'browser' }>['lane']

function keyPath(key: AST.TOMLKey): string[] {
  return key.keys.map(part => part.type === 'TOMLBare' ? part.name : part.value)
}

function browserTable(source: string) {
  const ast = parseTOML(source, { tomlVersion: '1.0' })
  const activity = new Map<BrowserActivityLane, boolean>([['live', true], ['automation', true], ['stagehand', true]])
  const flatPaths = new Map<string, string>()
  let automationTable = false
  // Do not convert a document into ordinary JS objects. The library's static
  // conversion follows inherited properties, so even unrelated provider keys
  // can mutate Object.prototype before validation. AST paths keep names as data.
  const visit = (path: readonly string[], node: AST.TOMLTable | AST.TOMLContentNode): void => {
    if (path[0] !== 'browser') return
    const name = path[1], field = path[2]
    const stringValue = () => {
      if (node.type !== 'TOMLValue' || node.kind !== 'string')
        throw new Error(`${path.join('.')}는 경로 문자열이어야 합니다.`)
      return node.value
    }
    if (name === 'geckodriver' || name === 'binary') {
      if (path.length !== 2) throw new Error(`${path.join('.')}는 경로 문자열이어야 합니다.`)
      flatPaths.set(name, stringValue()); return
    }
    if (name !== undefined && name !== 'live' && name !== 'automation' && name !== 'stagehand')
      throw new Error(`browser.${name}는 지원하지 않는 설정입니다.`)
    if (name === 'automation') automationTable = true
    if (field !== undefined) {
      if (field === 'enabled') {
        if (path.length !== 3 || node.type !== 'TOMLValue' || node.kind !== 'boolean')
          throw new Error(`${path.join('.')}는 true 또는 false여야 합니다.`)
        if (name !== undefined) activity.set(name, node.value)
      } else if (path.length === 3 && (name === 'automation' && (field === 'geckodriver' || field === 'binary')
        || name === 'stagehand' && (field === 'chrome' || field === 'extension' || field === 'profile'))) {
        stringValue()
      } else throw new Error(`${path.join('.')}는 지원하지 않는 설정입니다.`)
      return
    }
    if (node.type !== 'TOMLInlineTable' && !(node.type === 'TOMLTable' && node.kind === 'standard'))
      throw new Error(`${path.join('.')}는 TOML table이어야 합니다.`)
    for (const entry of node.body) visit([...path, ...keyPath(entry.key)], entry.value)
  }
  for (const node of ast.body[0].body) {
    if (node.type === 'TOMLTable') visit(keyPath(node.key), node)
    else visit(keyPath(node.key), node.value)
  }
  if (automationTable && flatPaths.size > 0)
    throw new Error('automation 경로는 [browser]와 [browser.automation] 중 한 곳에만 설정해야 합니다.')
  return { activity, flatPaths }
}

/** Read the selected activity flag. Full backend/path validation belongs to
 * the server preview; opening this editor neither installs nor starts it. */
export function readBrowserActivity(source: string, lane: BrowserActivityLane): { enabled: boolean } {
  return { enabled: browserTable(source).activity.get(lane)! }
}

/** Edit the selected flag using parsed TOML ranges. An automation edit moves
 * accepted flat paths into its table so the server never receives both forms.
 * Unchanged source and inline comments on an existing enabled value survive;
 * comments attached to moved path assignments are not retained by the editor. */
export function writeBrowserActivity(source: string, lane: BrowserActivityLane, enabled: boolean): string {
  const browser = browserTable(source)
  let next = source
  if (lane === 'automation') {
    for (const [key, value] of browser.flatPaths) {
      next = deleteRuntimeTomlKey(next, 'browser', key)
      next = setRuntimeTomlKey(next, 'browser.automation', key, value)
    }
  }
  next = setRuntimeTomlKey(next, `browser.${lane}`, 'enabled', enabled)
  readBrowserActivity(next, lane)
  return next
}
