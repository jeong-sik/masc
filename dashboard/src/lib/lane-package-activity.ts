import { parseTOML, type AST } from 'toml-eslint-parser'

function keyPath(key: AST.TOMLKey): string[] {
  return key.keys.map(part => part.type === 'TOMLBare' ? part.name : part.value)
}

/** Read only the root identity/activity from decoded AST nodes. Full declaration
 * and manifest validation is server-owned. No whole-document JS object is built. */
function activity(source: string, installationId: string) {
  const ast = parseTOML(source, { tomlVersion: '1.0' })
  let id: string | null = null, enabled = true
  let range: [number, number] | null = null
  for (const node of ast.body[0].body) {
    const path = keyPath(node.key)
    if (path[0] !== 'enabled' && path[0] !== 'id') continue
    if (path.length !== 1 || node.type !== 'TOMLKeyValue' || node.value.type !== 'TOMLValue')
      throw new Error(`${path[0]} must be a root scalar. Repair the original TOML first.`)
    if (path[0] === 'id') {
      if (node.value.kind !== 'string' || !node.value.value.trim()) throw new Error('Installation ID must be non-empty text.')
      id = node.value.value
    } else {
      if (node.value.kind !== 'boolean') throw new Error('enabled must be true or false. Repair the original TOML first.')
      enabled = node.value.value; range = node.value.range
    }
  }
  if (id !== installationId) throw new Error('This file now identifies a different installation. Refresh the declaration list before editing it.')
  return { enabled, range }
}

export function readPackageActivity(source: string, installationId: string): boolean {
  return activity(source, installationId).enabled
}

/** Replace only the root boolean's value range, or add its omitted key before
 * any table. Binding fields, comments, key spelling and unrelated bytes survive. */
export function writePackageActivity(source: string, installationId: string, enabled: boolean): string {
  const before = activity(source, installationId)
  if (before.enabled === enabled) return source
  const next = before.range === null ? `enabled = ${enabled}\n${source}`
    : source.slice(0, before.range[0]) + String(enabled) + source.slice(before.range[1])
  activity(next, installationId)
  return next
}
