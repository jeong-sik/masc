// Build-time drift guard for the keeper runtime config sources.
//
// `Keeper_runtime_resolved.source_to_string` is the single source of truth
// for the `source` label on every resolved keeper threshold. The dashboard
// normalizer drops the whole `keeper_runtime` block when it meets a label it
// does not know, and the config panel then draws nothing. This test reads the
// OCaml emit site and asserts it and KEEPER_RUNTIME_SOURCES hold the same set,
// so a new or renamed server label fails here instead of blanking a panel.

import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'
import { describe, expect, it } from 'vitest'
import { KEEPER_RUNTIME_SOURCES } from './dashboard-execution'

const here = dirname(fileURLToPath(import.meta.url))
// dashboard/src/types → repo root is three levels up.
const repoRoot = resolve(here, '../../..')

// Scope to the `source_to_string` arms (`| Constructor -> "label"`) so the
// comments and the other functions in the file are not picked up.
function serverSourceLabels(): string[] {
  const src = readFileSync(resolve(repoRoot, 'lib/keeper/keeper_runtime_resolved.ml'), 'utf8')
  const start = src.indexOf('let source_to_string = function')
  expect(start, 'source_to_string present in keeper_runtime_resolved.ml').toBeGreaterThan(-1)
  const body = src.slice(start, src.indexOf('\nlet ', start + 1))
  return [...body.matchAll(/\|\s*[A-Z][A-Za-z_]*\s*->\s*"([a-z_]+)"/g)]
    .map((m) => m[1])
    .filter((label): label is string => label !== undefined)
}

describe('KEEPER_RUNTIME_SOURCES drift guard', () => {
  it('holds exactly the labels Keeper_runtime_resolved.source_to_string emits', () => {
    const server = serverSourceLabels()
    expect(server.length).toBeGreaterThan(0)
    expect([...server].sort()).toEqual([...KEEPER_RUNTIME_SOURCES].sort())
  })
})
