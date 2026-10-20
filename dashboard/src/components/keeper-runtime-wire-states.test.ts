import { describe, expect, it } from 'vitest'

import { runtimeStatesOf, serverRuntimeStates } from './keeper-runtime-wire-states.test-fixture'

const fn = (body: string) => `let before = 1\n\nlet live_runtime_state entry =\n${body}\n\nlet after = function\n  | A -> "other"\n`

describe('runtimeStatesOf', () => {
  it('lists the string results of the arms once each', () => {
    const body = '  match x with\n  | A -> "idle"\n  | B -> "routing"\n  | None -> "idle"'
    expect(runtimeStatesOf(fn(body))).toEqual(['idle', 'routing'])
  })

  it('ignores a comment, and reads an arm that has one before its result', () => {
    const body = '  match x with\n  | A -> "idle" (* was -> "old" *)\n  | B -> (* note *) "routing"'
    expect(runtimeStatesOf(fn(body))).toEqual(['idle', 'routing'])
  })

  it('keeps a state outside lowercase letters and underscores', () => {
    expect(runtimeStatesOf(fn('  match x with\n  | A -> "idle"\n  | B -> "retry_2"'))).toContain('retry_2')
  })

  it('stops at the next top-level definition, including an attribute or extension one', () => {
    const source = 'let live_runtime_state e =\n  match e with\n  | A -> "idle"\n  | B -> "done"\n\nlet%x later = function\n  | C -> "later"\n'
    expect(runtimeStatesOf(source)).toEqual(['idle', 'done'])
  })

  it('does not take a longer function name for the function', () => {
    const source = 'let live_runtime_state_foo e = "phantom"\n\nlet live_runtime_state e =\n  match e with\n  | A -> "idle"\n  | B -> "done"\n'
    expect(runtimeStatesOf(source)).toEqual(['idle', 'done'])
  })

  it('refuses a function whose arms moved elsewhere', () => {
    expect(() => runtimeStatesOf(fn('  match f x with\n  | None -> "idle"'))).toThrow()
  })

  it('refuses a result that is not a plain string literal', () => {
    expect(() => runtimeStatesOf(fn('  match x with\n  | A -> "idle"\n  | B -> String.lowercase_ascii "DONE"'))).toThrow()
    expect(() => runtimeStatesOf(fn('  match x with\n  | A -> "idle"\n  | B -> {|done|}'))).toThrow()
  })

  it('refuses a source without the function', () => {
    expect(() => runtimeStatesOf('let other = 1\n')).toThrow()
  })

  it('reads the server source', () => {
    expect(serverRuntimeStates().length).toBeGreaterThanOrEqual(2)
  })
})
