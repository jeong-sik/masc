import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

import { describe, expect, it } from 'vitest'

import { PORTRAIT_MAX_PX, PORTRAIT_MIN_PX } from './keeper-portrait'

// OCaml -> dashboard parity for the portrait sizes the server accepts.
//
// The server answers 400 for a size outside Keeper_portrait_draw's range, so
// the dashboard's clamp must use the same numbers. This test reads them from
// the OCaml source rather than trusting the copy (same pattern as
// standalone-lanes-parity.test.ts). A wrong path throws ENOENT and a pattern
// that stops matching throws, rather than passing vacuously.

const DRAW_ML = resolve(__dirname, '../../../lib/keeper_portrait/keeper_portrait_draw.ml')

function ocamlInt(name: string): number {
  const source = readFileSync(DRAW_ML, 'utf8')
  const match = source.match(new RegExp(`^let ${name} = (\\d+)$`, 'm'))
  if (!match?.[1]) throw new Error(`could not find "let ${name} = <int>" in ${DRAW_ML}`)
  return Number(match[1])
}

describe('keeper portrait size parity', () => {
  it('clamps to the renderer\'s smallest size', () => {
    expect(PORTRAIT_MIN_PX).toBe(ocamlInt('min_size'))
  })

  it('clamps to the renderer\'s largest size', () => {
    expect(PORTRAIT_MAX_PX).toBe(ocamlInt('max_size'))
  })
})
