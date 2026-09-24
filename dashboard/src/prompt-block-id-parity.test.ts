import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

import { describe, expect, it } from 'vitest'

import {
  decodeTurnInputComponentId,
  decodeTurnPromptBlockId,
  TURN_PROMPT_BLOCK_IDS,
} from './api/dashboard-turn-records'

// Backend -> frontend parity for the prompt block ids a TurnRecord carries.
//
// The decoder rejects a record whose `blocks` or `input_components` name an id
// outside TURN_PROMPT_BLOCK_IDS, and the whole record then decodes to null.
// Prompt_block_id gained Skill_compositions in #34284 and every Keeper turn
// has carried that block since; the dashboard list did not, so the turn
// record view and the last-prompt view dropped every live row.
//
// Two independent reads of the OCaml source must agree before the comparison
// counts: the constructors of `type t` and the arms of `to_string`. to_string
// has no wildcard, so a read that stops early shows up as a mismatch between
// the two rather than as a shorter list that happens to equal the dashboard's.
const BLOCK_ID_PATH = '../lib/types/prompt_block_id.ml'
const BLOCK_ID_TYPE = 'type t ='
const BLOCK_ID_EMITTER = 'let to_string = function'

const TURN_RECORD_PATH = '../lib/types/turn_record.ml'
const COMPONENT_TYPE = 'type input_component_id ='
const COMPONENT_EMITTER = 'let input_component_id_to_string = function'
// The one input component that carries a payload; its arm spells the prefix
// the decoder parses, so it is read separately from the literal arms.
const PROMPT_COMPONENT_CTOR = 'Prompt_block'

// OCaml comments nest, so a depth counter rather than a regex.
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

function readSource(path: string): string {
  return withoutComments(readFileSync(resolve(process.cwd(), path), 'utf8'))
}

// The text from `marker` up to the next definition that starts at column 0.
function topLevelItem(source: string, marker: string): string {
  const start = source.indexOf(marker)
  if (start < 0) throw new Error(`source does not define ${marker}`)
  const rest = source.slice(start + marker.length)
  const end = rest.search(/\n(?:let|type|and|module|open|include|exception)\b/)
  return end < 0 ? rest : rest.slice(0, end)
}

function declaredConstructors(source: string, marker: string): string[] {
  const names: string[] = []
  for (const match of topLevelItem(source, marker).matchAll(/\|\s*(?<ctor>[A-Z][A-Za-z0-9_]*)/g)) {
    const ctor = match.groups?.ctor
    if (ctor !== undefined) names.push(ctor)
  }
  return names
}

type EmitterArm = { ctor: string; wire: string }

function literalArms(source: string, marker: string): EmitterArm[] {
  const arms: EmitterArm[] = []
  const armPattern = /\|\s*(?<ctor>[A-Z][A-Za-z0-9_]*)\s*->\s*"(?<wire>[a-z0-9_]+)"/g
  for (const match of topLevelItem(source, marker).matchAll(armPattern)) {
    const ctor = match.groups?.ctor
    const wire = match.groups?.wire
    if (ctor !== undefined && wire !== undefined) arms.push({ ctor, wire })
  }
  return arms
}

describe('Prompt_block_id parity', () => {
  const source = readSource(BLOCK_ID_PATH)
  const constructors = declaredConstructors(source, BLOCK_ID_TYPE)
  const arms = literalArms(source, BLOCK_ID_EMITTER)

  it('reads to_string through every constructor of the OCaml variant', () => {
    expect(constructors.length).toBeGreaterThan(0)
    expect(arms.map(arm => arm.ctor).sort()).toEqual([...constructors].sort())
  })

  it('lists exactly the block ids the backend emits', () => {
    expect([...TURN_PROMPT_BLOCK_IDS].sort()).toEqual(arms.map(arm => arm.wire).sort())
  })

  it('decodes every block id as a block and as a prompt input component', () => {
    for (const { wire } of arms) {
      expect(decodeTurnPromptBlockId(wire)).toBe(wire)
      expect(decodeTurnInputComponentId(`prompt.${wire}`)).toBe(`prompt.${wire}`)
    }
  })

  it('still rejects an id no backend emits', () => {
    expect(decodeTurnPromptBlockId('block_from_a_future_server')).toBeNull()
    expect(decodeTurnInputComponentId('prompt.block_from_a_future_server')).toBeNull()
    expect(decodeTurnInputComponentId('prompt.')).toBeNull()
  })
})

describe('Turn_record input_component_id parity', () => {
  const source = readSource(TURN_RECORD_PATH)
  const constructors = declaredConstructors(source, COMPONENT_TYPE)
  const arms = literalArms(source, COMPONENT_EMITTER)
  const emitter = topLevelItem(source, COMPONENT_EMITTER)

  it('reads the emitter through every constructor except the prompt one', () => {
    expect(constructors).toContain(PROMPT_COMPONENT_CTOR)
    expect(arms.map(arm => arm.ctor).sort())
      .toEqual(constructors.filter(ctor => ctor !== PROMPT_COMPONENT_CTOR).sort())
  })

  it('spells the prompt component as the prefix the dashboard parses', () => {
    expect(emitter).toMatch(/\|\s*Prompt_block\s+block\s*->\s*"prompt\."\s*\^\s*Prompt_block_id\.to_string\s+block/)
  })

  it('decodes every literal component the backend emits', () => {
    for (const { wire } of arms) {
      expect(decodeTurnInputComponentId(wire)).toBe(wire)
    }
  })
})
