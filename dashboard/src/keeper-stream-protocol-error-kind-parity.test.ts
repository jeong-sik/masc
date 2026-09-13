import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

import { describe, expect, it } from 'vitest'

import { KEEPER_STREAM_PROTOCOL_ERROR_KINDS } from './lib/keeper-chat-stream-contract'

// The OCaml emitter is the source of truth for the wire kinds. The dashboard
// decoder rejects any kind outside its own list and keeper-stream.ts turns the
// rejection into a terminal RUN_ERROR, so a kind the backend can emit but the
// dashboard does not list ends a bubble mid-turn and drops the answer of the
// next attempt (sse_timeout and sse_stream_repeating were missing for exactly
// this reason). Hold the two lists equal; a rename or addition on either side
// fails here before it fails in a browser.
const EMITTER_PATH = '../lib/keeper/keeper_chat_events.ml'
const EMITTER_FUNCTION = 'let stream_protocol_error_kind_to_string = function'

function backendEmittedKinds(): string[] {
  const source = readFileSync(resolve(process.cwd(), EMITTER_PATH), 'utf8')
  const start = source.indexOf(EMITTER_FUNCTION)
  expect(start, `${EMITTER_PATH} defines ${EMITTER_FUNCTION}`).toBeGreaterThanOrEqual(0)
  const body = source.slice(start + EMITTER_FUNCTION.length)
  const kinds: string[] = []
  for (const line of body.split('\n').slice(1)) {
    const kind = /^\s*\|\s*[A-Z][A-Za-z0-9_]*\s*->\s*"(?<kind>[a-z0-9_]+)"\s*$/.exec(line)?.groups?.kind
    if (kind === undefined) break
    kinds.push(kind)
  }
  expect(kinds.length, 'the emitter body was read arm by arm').toBeGreaterThan(0)
  return kinds
}

describe('KEEPER_STREAM_PROTOCOL_ERROR kinds', () => {
  it('lists exactly the kinds the backend emits', () => {
    const backend = [...backendEmittedKinds()].sort()
    const dashboard = [...KEEPER_STREAM_PROTOCOL_ERROR_KINDS].sort()
    expect(dashboard).toEqual(backend)
  })

  it('has no duplicate kind', () => {
    expect(new Set(KEEPER_STREAM_PROTOCOL_ERROR_KINDS).size).toBe(KEEPER_STREAM_PROTOCOL_ERROR_KINDS.length)
  })
})
