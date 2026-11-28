import test from 'node:test'
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

const viewer = fileURLToPath(new URL('../viewer.mjs', import.meta.url))
// The bend is what needs smf1Mode: alphaTab otherwise emits a MIDI 2.0
// per-note bend that a Standard MIDI File cannot hold.
const riff = '\\title "Riff"\n.\n:4 3.6{b (0 4)} 5.6 7.6 5.6 | 3.5 5.5 7.5 5.5\n'

function exportScore(args) {
  const directory = mkdtempSync(join(tmpdir(), 'alphatex-export-'))
  const score = join(directory, 'riff.atex')
  writeFileSync(score, riff)
  const run = spawnSync(process.execPath, [viewer, score, ...args(directory)], { encoding: 'utf8' })
  return { directory, run }
}

test('--export-midi writes a Standard MIDI File without a terminal', () => {
  const { directory, run } = exportScore(directory => ['--export-midi', join(directory, 'riff.mid')])
  try {
    assert.equal(run.status, 0, run.stderr)
    assert.equal(JSON.parse(run.stdout).bars, 2)
    const midi = readFileSync(join(directory, 'riff.mid'))
    assert.equal(midi.subarray(0, 4).toString('latin1'), 'MThd')
    assert.equal(midi.readUInt16BE(8), 0, 'SMF format 0')
    assert.equal(midi.subarray(14, 18).toString('latin1'), 'MTrk')
  } finally { rmSync(directory, { recursive: true, force: true }) }
})

test('a score that does not parse exits 65 with its diagnostics', () => {
  const directory = mkdtempSync(join(tmpdir(), 'alphatex-export-'))
  try {
    const score = join(directory, 'bad.atex')
    writeFileSync(score, '\\title "Bad"\n.\n:4 3.6 }}}\n')
    const run = spawnSync(process.execPath, [viewer, score, '--export-midi', join(directory, 'bad.mid')], { encoding: 'utf8' })
    assert.equal(run.status, 65, run.stderr)
    assert.match(run.stderr, /AT202/)
  } finally { rmSync(directory, { recursive: true, force: true }) }
})

test('--export-midi does not overwrite an existing file', () => {
  const { directory, run } = exportScore(directory => {
    writeFileSync(join(directory, 'taken.mid'), 'kept')
    return ['--export-midi', join(directory, 'taken.mid')]
  })
  try {
    assert.equal(run.status, 1)
    assert.equal(readFileSync(join(directory, 'taken.mid'), 'utf8'), 'kept')
  } finally { rmSync(directory, { recursive: true, force: true }) }
})

test('--audio-max-bytes stops a WAV that would pass the limit and leaves no file', () => {
  const { directory, run } = exportScore(directory => ['--audio', join(directory, 'riff.wav'), '--audio-max-bytes', '50000'])
  try {
    assert.equal(run.status, 73, run.stderr)
    assert.match(run.stderr, /passes 50000 bytes/)
    assert.equal(existsSync(join(directory, 'riff.wav')), false)
  } finally { rmSync(directory, { recursive: true, force: true }) }
})

test('--audio-max-bytes lets a WAV within the limit through', () => {
  const limit = 20 * 1024 * 1024
  const { directory, run } = exportScore(directory => ['--audio', join(directory, 'riff.wav'), '--audio-max-bytes', String(limit)])
  try {
    assert.equal(run.status, 0, run.stderr)
    const size = statSync(join(directory, 'riff.wav')).size
    assert.ok(size > 44 && size <= limit, `a WAV of ${size} bytes`)
  } finally { rmSync(directory, { recursive: true, force: true }) }
})

test('a limit that is not a positive integer is refused before any file is written', () => {
  const { directory, run } = exportScore(directory => ['--export-midi', join(directory, 'riff.mid'), '--audio', join(directory, 'riff.wav'), '--audio-max-bytes', '0'])
  try {
    assert.equal(run.status, 1)
    assert.match(run.stderr, /--audio-max-bytes must be a positive integer/)
    assert.equal(existsSync(join(directory, 'riff.mid')), false)
    assert.equal(existsSync(join(directory, 'riff.wav')), false)
  } finally { rmSync(directory, { recursive: true, force: true }) }
})
