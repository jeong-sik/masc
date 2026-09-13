import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

import { describe, expect, it } from 'vitest'

import { KEEPER_STREAM_PROTOCOL_ERROR_KINDS } from './lib/keeper-chat-stream-contract'

// The OCaml emitter is the source of truth for the wire kinds. The dashboard
// decoder rejects any kind outside its own list; on the operation-projection
// path that rejection is synthesised into a RUN_ERROR that ends the bubble
// mid-turn and drops the answer of the next attempt (sse_timeout and
// sse_stream_repeating were missing for exactly this reason). Hold the two
// lists equal; a rename or addition on either side fails here before it fails
// in a browser.
//
// Two independent reads of the OCaml source must agree before the comparison
// counts: the constructors of the variant declaration and the arms of the
// emitter function. The compiler makes the emitter cover every constructor
// (it has no wildcard), so a read that stops early on either side shows up as
// a mismatch between the two, not as a shorter list that happens to equal the
// dashboard's.
const EMITTER_PATH = '../lib/keeper/keeper_chat_events.ml'
const KIND_TYPE = 'type stream_protocol_error_kind ='
const EMITTER_FUNCTION = 'let stream_protocol_error_kind_to_string = function'

// OCaml comments nest, so a depth counter rather than a regex; a comment
// between two arms or two constructors must not end the read.
function withoutComments(source: string): string {
  let depth = 0
  const kept: string[] = []
  for (let i = 0; i < source.length; i += 1) {
    if (source.startsWith('(*', i)) {
      depth += 1
      i += 1
      continue
    }
    if (depth > 0 && source.startsWith('*)', i)) {
      depth -= 1
      i += 1
      continue
    }
    if (depth === 0) kept.push(source.charAt(i))
  }
  return kept.join('')
}

// The text from `marker` up to the next definition that starts at column 0,
// which is where a variant declaration or a one-function body ends.
function topLevelItem(source: string, marker: string): string {
  const start = source.indexOf(marker)
  if (start < 0) throw new Error(`${EMITTER_PATH} does not define ${marker}`)
  const rest = source.slice(start + marker.length)
  const end = rest.search(/\n(?:let|type|and|module|open|include|exception)\b/)
  return end < 0 ? rest : rest.slice(0, end)
}

function declaredConstructors(source: string): string[] {
  const names: string[] = []
  for (const match of topLevelItem(source, KIND_TYPE).matchAll(/\|\s*(?<ctor>[A-Z][A-Za-z0-9_]*)/g)) {
    const ctor = match.groups?.ctor
    if (ctor !== undefined) names.push(ctor)
  }
  return names
}

type EmitterArm = { ctor: string; kind: string }

function emitterArms(source: string): EmitterArm[] {
  const arms: EmitterArm[] = []
  const armPattern = /\|\s*(?<ctor>[A-Z][A-Za-z0-9_]*)\s*->\s*"(?<kind>[a-z0-9_]+)"/g
  for (const match of topLevelItem(source, EMITTER_FUNCTION).matchAll(armPattern)) {
    const ctor = match.groups?.ctor
    const kind = match.groups?.kind
    if (ctor !== undefined && kind !== undefined) arms.push({ ctor, kind })
  }
  return arms
}

describe('KEEPER_STREAM_PROTOCOL_ERROR kinds', () => {
  const source = withoutComments(readFileSync(resolve(process.cwd(), EMITTER_PATH), 'utf8'))
  const constructors = declaredConstructors(source)
  const arms = emitterArms(source)

  it('reads the emitter through every constructor of the OCaml variant', () => {
    expect(constructors.length).toBeGreaterThan(0)
    expect(arms.map(arm => arm.ctor).sort()).toEqual([...constructors].sort())
  })

  it('lists exactly the kinds the backend emits', () => {
    expect([...KEEPER_STREAM_PROTOCOL_ERROR_KINDS].sort()).toEqual(arms.map(arm => arm.kind).sort())
  })

  it('has no duplicate kind', () => {
    expect(new Set(KEEPER_STREAM_PROTOCOL_ERROR_KINDS).size).toBe(KEEPER_STREAM_PROTOCOL_ERROR_KINDS.length)
  })
})
