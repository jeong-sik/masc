import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

const OBSERVER_SOURCE = 'lib/keeper/keeper_composite_observer.ml'
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

/** The string results of the arms of the top-level OCaml function `name`, each
 *  once, in order. Throws when the function is no longer a plain list of
 *  `-> "state"` arms, so a refactor there is a failure here, not a smaller set. */
export function armResultsOf(source: string, name: string): readonly string[] {
  const start = new RegExp(`^let ${name}(?![\\w'])`, 'm').exec(source)?.index
  if (start === undefined) throw new Error(`${name} not found`)
  const rest = source.slice(start + 1)
  const end = NEXT_DEFINITION.exec(rest)?.index
  const body = rest.slice(0, end).replace(OCAML_COMMENT, '')
  if (QUOTED_STRING.test(body)) throw new Error(`${name} uses a quoted string literal`)
  const literals = body.match(STRING_LITERAL)?.length ?? 0
  const results = [...body.matchAll(STRING_RESULT)].map(m => m[1]!)
  if (results.length !== literals) {
    throw new Error(`${name} has ${literals} string literals but ${results.length} are arm results`)
  }
  const states = [...new Set(results)]
  if (states.length < MIN_STATES) throw new Error(`${name} lists ${states.length} states`)
  return states
}

function observerStates(name: string): readonly string[] {
  return armResultsOf(readFileSync(resolve(repoRoot(), OBSERVER_SOURCE), 'utf8'), name)
}

/** Runtime (KCL) states the server writes into the composite snapshot. The
 *  dashboard keeps its own copies of these alphabets, and a copy that stops
 *  matching names a state the server never sends. */
export const serverRuntimeStates = (): readonly string[] => observerStates('live_runtime_state')

/** Turn-cycle (KTC) phases the server writes into the composite snapshot. */
export const serverTurnPhases = (): readonly string[] => observerStates('turn_phase_to_string')

/** Decision-pipeline (KDP) stages the server writes into the composite snapshot. */
export const serverDecisionStages = (): readonly string[] => observerStates('decision_stage_to_string')
