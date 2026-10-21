import { describe, expect, it } from 'vitest'

import {
  armResultsOf,
  serverDecisionStages,
  serverRuntimeStates,
  serverTurnPhases,
} from './keeper-runtime-wire-states.test-fixture'

const FN = 'live_runtime_state'
const fn = (body: string) => `let before = 1\n\nlet ${FN} entry =\n${body}\n\nlet after = function\n  | A -> "other"\n`

describe('armResultsOf', () => {
  it('lists the string results of the arms once each', () => {
    const body = '  match x with\n  | A -> "idle"\n  | B -> "routing"\n  | None -> "idle"'
    expect(armResultsOf(fn(body), FN)).toEqual(['idle', 'routing'])
  })

  it('ignores a comment, and reads an arm that has one before its result', () => {
    const body = '  match x with\n  | A -> "idle" (* was -> "old" *)\n  | B -> (* note *) "routing"'
    expect(armResultsOf(fn(body), FN)).toEqual(['idle', 'routing'])
  })

  it('keeps a state outside lowercase letters and underscores', () => {
    expect(armResultsOf(fn('  match x with\n  | A -> "idle"\n  | B -> "retry_2"'), FN)).toContain('retry_2')
  })

  it('stops at the next top-level definition, including an attribute or extension one', () => {
    const source = `let ${FN} e =\n  match e with\n  | A -> "idle"\n  | B -> "done"\n\nlet%x later = function\n  | C -> "later"\n`
    expect(armResultsOf(source, FN)).toEqual(['idle', 'done'])
  })

  it('does not take a longer function name for the function', () => {
    const source = `let ${FN}_foo e = "phantom"\n\nlet ${FN} e =\n  match e with\n  | A -> "idle"\n  | B -> "done"\n`
    expect(armResultsOf(source, FN)).toEqual(['idle', 'done'])
  })

  it('refuses a function whose arms moved elsewhere', () => {
    expect(() => armResultsOf(fn('  match f x with\n  | None -> "idle"'), FN)).toThrow()
  })

  it('refuses a result that is not a plain string literal', () => {
    expect(() => armResultsOf(fn('  match x with\n  | A -> "idle"\n  | B -> String.lowercase_ascii "DONE"'), FN)).toThrow()
    expect(() => armResultsOf(fn('  match x with\n  | A -> "idle"\n  | B -> {|done|}'), FN)).toThrow()
  })

  it('refuses a source without the function', () => {
    expect(() => armResultsOf('let other = 1\n', FN)).toThrow()
  })
})

describe('the server source', () => {
  it('lists each composite axis the dashboard draws', () => {
    expect(serverRuntimeStates().length).toBeGreaterThanOrEqual(2)
    expect(serverTurnPhases().length).toBeGreaterThanOrEqual(2)
    expect(serverDecisionStages().length).toBeGreaterThanOrEqual(2)
  })
})
