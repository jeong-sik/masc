// Unit test for the v2 prototype build's top-level const/let -> var rewrite.
// Run: node --test scripts/build-v2.test.mjs
//
// The rewrite is what makes the prototype's shared-global-scope classic scripts
// load without "Identifier already declared" errors (several files re-declare
// `const { useState } = React`). It must touch ONLY top-level (column-0)
// declarations and leave nested const/let and `for (let …)` heads intact.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { topLevelConstToVar } from './build-v2.mjs'

test('rewrites top-level const to var', () => {
  assert.equal(topLevelConstToVar('const x = 1'), 'var x = 1')
})

test('rewrites top-level let to var', () => {
  assert.equal(topLevelConstToVar('let y = 2'), 'var y = 2')
})

test('rewrites the re-declared React hook binding (the actual collision)', () => {
  assert.equal(
    topLevelConstToVar('const { useState } = React;'),
    'var { useState } = React;',
  )
})

test('leaves nested (indented) const/let untouched — block scope preserved', () => {
  assert.equal(topLevelConstToVar('  const z = 3'), '  const z = 3')
  assert.equal(topLevelConstToVar('\tlet w = 4'), '\tlet w = 4')
})

test('leaves `for (let …)` heads untouched — loop scope preserved', () => {
  const src = 'for (let i = 0; i < n; i++) {}'
  assert.equal(topLevelConstToVar(src), src)
})

test('handles a multiline mix: top-level var, nested const kept', () => {
  const input = [
    'const { useState } = React;',
    'function f() {',
    '  const a = 1;',
    '  for (let i = 0; i < 3; i++) {}',
    '}',
    'let g = f;',
  ].join('\n')
  const expected = [
    'var { useState } = React;',
    'function f() {',
    '  const a = 1;',
    '  for (let i = 0; i < 3; i++) {}',
    '}',
    'var g = f;',
  ].join('\n')
  assert.equal(topLevelConstToVar(input), expected)
})

test('does not touch identifiers that merely start with const/let', () => {
  assert.equal(topLevelConstToVar('constant = 5'), 'constant = 5')
  assert.equal(topLevelConstToVar('letterCount = 5'), 'letterCount = 5')
})
