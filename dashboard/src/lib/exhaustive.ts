/**
 * assertExhaustive — compile-time exhaustiveness assertion for closed unions.
 *
 * Use after a `switch` over every variant of a closed union type. If a new
 * variant is added without updating the switch, TypeScript will fail to
 * compile this call with TS2345 ("Argument of type 'X' is not assignable to
 * parameter of type 'never'"), pointing the diff straight at the missing arm.
 *
 * Without this helper, the common TypeScript anti-pattern is:
 *
 *     switch (tone) {
 *       case 'bad':  return 'red'
 *       case 'warn': return 'amber'
 *       case 'ok':           // ← collapse onto default silently
 *       default:     return 'green'
 *     }
 *
 * which loses the compile-time signal when a new variant ('pending', etc.)
 * is added. The new variant flows through the `default` arm and gets the
 * wrong colour at runtime with no warning.
 *
 * With `assertExhaustive`, the same switch becomes:
 *
 *     switch (tone) {
 *       case 'bad':  return 'red'
 *       case 'warn': return 'amber'
 *       case 'ok':   return 'green'
 *     }
 *     return assertExhaustive(tone, 'Tone')
 *
 * Adding 'pending' to the union now fails the build at this line until the
 * new case is handled. Mirror of the OCaml `_ -> false` catch-all hunt fixed
 * in masc-mcp PR #16747 (FSM Sparse Match anti-pattern, see
 * software-development.md §"AI 코드 생성 안티패턴" §4).
 *
 * The runtime `throw` is the never-reached fallback: TypeScript's type system
 * guarantees `value` is `never` at the call site, so an invariant violation
 * means an upstream cast eroded the type — fail loudly instead of producing
 * silent wrong output.
 */
export function assertExhaustive(value: never, context: string): never {
  throw new Error(`assertExhaustive: unexpected ${context} value: ${String(value)}`)
}
