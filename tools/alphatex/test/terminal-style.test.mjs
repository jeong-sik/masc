import { test } from 'node:test'
import assert from 'node:assert/strict'
import { fitLine, cellSegments, bold, red, cyan } from '../terminal-style.mjs'

const visible = text => text.replace(/\x1b\[[0-9;]*m/g, '')

test('a cut line closes every style it opened', () => {
  const line = [['Phrase', [bold]], [' · ', []], ['SilentRender: selected VST produced silence', [bold, red]]]
  for (const columns of [1, 4, 7, 12, 80]) {
    const drawn = fitLine(line, columns)
    const opened = drawn.match(/\x1b\[[0-9;]+m/g) ?? [], closed = drawn.match(/\x1b\[0m/g) ?? []
    assert.equal(opened.length, closed.length * 2)
    assert.ok(!drawn.endsWith('m') || drawn.endsWith('\x1b[0m'))
    assert.ok(visible(drawn).length < columns)
  }
})

test('segment text cannot write terminal control sequences', () => {
  const drawn = fitLine([['Bass\x1b[2J\x07', [cyan]]], 80)
  assert.equal(visible(drawn), 'Bass [2J ')
})

test('adjacent cells with the same styles share one segment', () => {
  assert.deepEqual(cellSegments([['·', []], ['·', []], ['█', [bold, cyan]], ['━', [cyan]], ['━', [cyan]]]),
    [['··', []], ['█', [bold, cyan]], ['━━', [cyan]]])
})
