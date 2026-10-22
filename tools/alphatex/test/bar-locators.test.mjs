import test from 'node:test'
import assert from 'node:assert/strict'
import { newEditor, editorCommand, editorAction, editorView } from '../sequencer-editor.mjs'
import { importMidiSource } from '../midi-source.mjs'
import { PPQ } from '../sequencer-project.mjs'

const bar = 4 * PPQ
const phrase = (...lines) => lines.reduce((editor, line) => editorCommand(editor, line).editor, newEditor())

test('> and < change a 4/4 phrase by whole bars and a loop that reached the end follows it', () => {
  let editor = phrase()
  assert.equal(editor.project.length, 4 * bar)
  editor = editorAction(editor, { kind: 'bars', delta: 1 })
  assert.equal(editor.project.length, 5 * bar)
  assert.deepEqual(editor.project.loop, { start: 0, end: 5 * bar })
  editor = editorAction(editorAction(editor, { kind: 'bars', delta: -1 }), { kind: 'undo' })
  assert.equal(editor.project.length, 5 * bar)
  assert.equal(editorCommand(editor, 'bars 2').editor.project.length, 2 * bar)
})

test('a partial last bar is completed by > and dropped by <', () => {
  const editor = phrase('length 18')
  assert.equal(editorAction(editor, { kind: 'bars', delta: 1 }).project.length, 5 * bar)
  assert.equal(editorAction(editor, { kind: 'bars', delta: -1 }).project.length, 4 * bar)
})

test('shortening refuses to cut a note or a loop and names the bar', () => {
  const noted = phrase('note C4 12 2')
  assert.throws(() => editorAction(noted, { kind: 'bars', delta: -1 }), /A note reaches past bar 3/)
  const looped = phrase('loop 4 14')
  assert.throws(() => editorAction(looped, { kind: 'bars', bars: 3 }), /loop reaches past bar 3/)
  assert.throws(() => editorAction(phrase(), { kind: 'bars', bars: 0 }), /at least one bar/)
})

test('{ and } put the loop on the bars under the cursor', () => {
  let editor = phrase('cursor 5 C4')
  editor = editorAction(editor, { kind: 'locator', side: 'left' })
  assert.deepEqual(editor.project.loop, { start: bar, end: 4 * bar })
  editor = editorAction(editorCommand(editor, 'cursor 9 C4').editor, { kind: 'locator', side: 'right' })
  assert.deepEqual(editor.project.loop, { start: bar, end: 3 * bar })
  // A start placed after the end makes the loop that one bar.
  editor = editorAction(editorCommand(editor, 'cursor 13 C4').editor, { kind: 'locator', side: 'left' })
  assert.deepEqual(editor.project.loop, { start: 3 * bar, end: 4 * bar })
  assert.deepEqual(editorAction(editor, { kind: 'undo' }).project.loop, { start: bar, end: 3 * bar })
})

test('the last locator stops at a phrase end inside a bar', () => {
  const editor = editorAction(phrase('length 18', 'cursor 17 C4'), { kind: 'locator', side: 'right' })
  assert.deepEqual(editor.project.loop, { start: 0, end: 18 * PPQ })
})

// One conductor track with 3/4 at tick 0 and one note held for four bars.
const chunk = (tag, data) => { const head = Buffer.alloc(8); head.write(tag); head.writeUInt32BE(data.length, 4); return Buffer.concat([head, Buffer.from(data)]) }
function threeFour() {
  const header = Buffer.alloc(6); header.writeUInt16BE(1); header.writeUInt16BE(2, 2); header.writeUInt16BE(480, 4)
  const conductor = [0, 255, 88, 4, 3, 2, 24, 8, 0, 255, 47, 0]
  const notes = [0, 0x90, 60, 96, 0xad, 0x00, 0x80, 60, 64, 0, 255, 47, 0]
  return importMidiSource(Buffer.concat([chunk('MThd', header), chunk('MTrk', conductor), chunk('MTrk', notes)]))
}

test('imported MIDI locators follow its time-signature map and keep the source unchanged', () => {
  const editor = newEditor(threeFour()), threeBeats = 3 * 480
  const placed = editorAction({ ...editor, tick: threeBeats + 10 }, { kind: 'locator', side: 'left' })
  assert.deepEqual(editorView(placed).loop, { start: threeBeats, end: 4 * threeBeats })
  assert.equal(placed.project, editor.project)
  assert.throws(() => editorAction(editor, { kind: 'bars', delta: 1 }), /keeps the length of its performance/)
  // The cursor can rest on the end tick, itself a bar line; the loop is the last bar.
  const last = editorAction({ ...editor, tick: 4 * threeBeats }, { kind: 'locator', side: 'left' })
  assert.deepEqual(editorView(last).loop, { start: 3 * threeBeats, end: 4 * threeBeats })
})
