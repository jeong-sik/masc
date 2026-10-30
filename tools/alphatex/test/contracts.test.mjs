import { test } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, existsSync, rmSync, readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { readScore } from '../engine.mjs'
import { exportWave } from '../audio.mjs'
import { errorDetail } from '../diagnostics.mjs'
import { apc, transmit, viewport, safeText } from '../terminal.mjs'

test('official diagnostics retain the code and original location for invalid properties', () => {
  try {
    readScore(String.raw`\staff {score tab} :4 5.3`)
    assert.fail('invalid staff property was accepted')
  } catch (error) {
    const detail = errorDetail(error)
    assert.match(detail, /AT205/)
    assert.match(detail, /\(1,15\)/)
    assert.match(detail, /Unrecognized property 'tab'/)
  }
})

test('semantic diagnostics retain their code when the importer throws them directly', () => {
  try {
    readScore(String.raw`\ts 4 7 3.3`)
    assert.fail('invalid time signature was accepted')
  } catch (error) {
    assert.match(errorDetail(error), /AT211/)
  }
})

test('cancelled audio stops synthesis and removes its own partial WAV', () => {
  const directory = mkdtempSync(join(tmpdir(), 'masc-score-test-'))
  try {
    const path = join(directory, 'cancelled.wav')
    assert.throws(() => exportWave(':1 0.6 | 0.6 | 0.6', path, { cancelled: () => true }), /cancelled/)
    assert.equal(existsSync(path), false)
    const finished = join(directory, 'finished.wav')
    const result = exportWave(':4 0.6 r 3.6 r', finished)
    const bytes = readFileSync(finished)
    assert.equal(bytes.readUInt32LE(40), bytes.length - 44)
    assert.equal(bytes.readUInt32LE(4), bytes.length - 8)
    assert.ok(result.peak > 0.001)
    assert.throws(() => exportWave(':4 0.6', finished), /EEXIST/)
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
})

test('graphics transport honors Kitty chunk and tmux escape framing', () => {
  const transport = transmit(Buffer.alloc(10000), false)
  const chunks = [...transport.matchAll(/\x1b_G([^;]+);([^\x1b]*)\x1b\\/g)]
  assert.ok(chunks.length > 1)
  assert.ok(chunks.every(chunk => chunk[2].length <= 4096))
  assert.match(chunks.at(-1)[1], /m=0/)
  assert.deepEqual(Buffer.from(chunks.map(chunk => chunk[2]).join(''), 'base64'), Buffer.alloc(10000))
  assert.equal(apc('a=p', '', true), '\x1bPtmux;\x1b\x1b_Ga=p\x1b\x1b\\\x1b\\')
  assert.equal(safeText('title\x1b]52;c;payload\x07'), 'title ]52;c;payload ')
})

test('viewport scroll crops the same source image without crossing its bounds', () => {
  const image = { width: 1200, height: 3000 }
  const args = { columns: 122, rows: 34, cellWidth: 10, cellHeight: 20 }
  const first = viewport(image, { ...args, scroll: 0 })
  const second = viewport(image, { ...args, scroll: first.rows })
  assert.equal(first.top + first.height, second.top)
  const last = viewport(image, { ...args, scroll: Number.MAX_SAFE_INTEGER })
  assert.ok(last.top + last.height <= image.height)
  assert.equal(last.top + last.height, image.height)
})
