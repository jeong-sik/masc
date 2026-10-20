import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

const OBSERVER_SOURCE = 'lib/keeper/keeper_composite_observer.ml'
const RUNTIME_STATE_FN = /^let live_runtime_state(?![\w'])/m
const NEXT_DEFINITION = /\n(?:let|and|type|module|exception|open|val)(?![\w'])/
const OCAML_COMMENT = /\(\*[\s\S]*?\*\)/g
const QUOTED_STRING = /\{[a-z_]*\|/
const STRING_LITERAL = /"[^"]*"/g
const STRING_RESULT = /->\s*"([^"]*)"/g
// One state is a function that no longer lists the alphabet (for example its
// arms moved into a helper), not an alphabet.
const MIN_STATES = 2

function repoRoot(): string {
  const cwd = process.cwd()
  return cwd.endsWith('/dashboard') ? resolve(cwd, '..') : cwd
}

/** Runtime (KCL) state strings the server writes into the composite snapshot:
 *  the string results of `live_runtime_state`. The dashboard keeps its own
 *  copies of this alphabet, and a copy that stops matching names a state the
 *  server never sends. Throws when the function is no longer a plain list of
 *  `-> "state"` arms, so a refactor there is a failure here, not a smaller set. */
export function serverRuntimeStates(): readonly string[] {
  return runtimeStatesOf(readFileSync(resolve(repoRoot(), OBSERVER_SOURCE), 'utf8'))
}

export function runtimeStatesOf(source: string): readonly string[] {
  const start = RUNTIME_STATE_FN.exec(source)?.index
  if (start === undefined) throw new Error(`live_runtime_state not found in ${OBSERVER_SOURCE}`)
  const rest = source.slice(start + 1)
  const end = NEXT_DEFINITION.exec(rest)?.index
  const body = rest.slice(0, end).replace(OCAML_COMMENT, '')
  if (QUOTED_STRING.test(body)) throw new Error('live_runtime_state uses a quoted string literal')
  const literals = body.match(STRING_LITERAL)?.length ?? 0
  const results = [...body.matchAll(STRING_RESULT)].map(m => m[1]!)
  if (results.length !== literals) {
    throw new Error(`live_runtime_state has ${literals} string literals but ${results.length} are arm results`)
  }
  const states = [...new Set(results)]
  if (states.length < MIN_STATES) throw new Error(`live_runtime_state lists ${states.length} states`)
  return states
}
