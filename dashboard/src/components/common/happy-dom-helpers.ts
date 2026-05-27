// Test-only type fixtures for happy-dom-backed unit tests.
//
// `vitest` runs this dashboard's tests against happy-dom rather than a
// real browser. happy-dom implements `document.execCommand` as an
// optional method, but neither the real DOM `Document` type nor
// happy-dom's exported type spell that out cleanly — copy-button tests
// have to cast through `unknown` to stub it. Two test files (`copyable-code`,
// `copy-id-button`) shipped the exact same three-line fixture; centralise
// the cast types here so a future API tweak (e.g. happy-dom typing
// `execCommand` natively) only updates one place.
//
// `export type` only — keeps this module type-only at the import boundary
// so production bundlers tree-shake the file out cleanly.

export type ExecCommandFn = (cmd: string) => boolean
export type HappyDomDocument = { execCommand?: ExecCommandFn }
