// Actual native preparation: no CoreMIDI destination is opened and no terminal
// wording/layout is asserted. Inspect emitted wire decisions and saved files.
import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { mkdtemp, readFile, writeFile, rm, access, mkdir, symlink, lstat, readlink, readdir } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createHash } from 'node:crypto'

const exec = promisify(execFile), native = dirname(fileURLToPath(import.meta.url))
const root = await mkdtemp(join(tmpdir(), 'masc-vst-region-projection-'))
const binary = join(root, 'music-midi')
let cases = 0
try {
  await exec('xcrun', ['swiftc', '-parse-as-library', '-O', join(native, 'MidiTransport.swift'),
    join(native, 'MidiRenderProjection.swift'), '-o', binary, '-framework', 'CoreMIDI'])
  const wire = (seconds, bytes, port = 0) => ({ seconds, bytes, port })
  const region = { id: 'trimmed', source: 'source', startSeconds: 0.3, sourceStart: 0.1, sourceEnd: 0.4,
    repeatCount: 3, startNanoseconds: { numerator: '300000000', denominator: '1' },
    periodNanoseconds: { numerator: '300000000', denominator: '1' } }
  const source = { id: 'source', duration: 0.5, events: [wire(0, [0xb0, 7, 90]), wire(0, [0xe0, 0, 65]),
    wire(0, [0xd0, 0]), wire(0.05, [0x90, 60, 90]), wire(0.08, [0xb0, 64, 127]),
    wire(0.1, [0x80, 60, 45]), wire(0.1, [0x90, 62, 80]), wire(0.1, [0x80, 62, 31]),
    wire(0.1, [0xd0, 5]), wire(0.2, [0x90, 64, 70]), wire(0.4, [0x80, 64, 99])] }
  const plan = { schemaVersion: 1, kind: 'vst-arrangement', duration: 1.2, sources: [source], regions: [region] }
  let sequence = 0
  async function prepare(value) {
    const input = join(root, `plan-${++sequence}.json`), output = join(root, `parts-${sequence}`)
    await writeFile(input, JSON.stringify(value))
    const result = await exec(binary, ['export-vst', '--file', input, '--output', output])
    const manifest = JSON.parse(result.stdout)
    assert.deepEqual(JSON.parse(await readFile(join(output, 'manifest.json'), 'utf8')), manifest)
    const rows = await Promise.all(manifest.parts.map(async part => {
      const bytes = await readFile(part.path)
      assert.equal(createHash('sha256').update(bytes).digest('hex'), part.sha256)
      const lines = bytes.toString().trimEnd().split('\n').map(JSON.parse)
      assert.equal(lines.length - 1, part.eventCount)
      return lines.slice(1)
    }))
    return { manifest, rows }
  }
  const { manifest, rows: [events] } = await prepare(plan)
  assert.equal(manifest.parts.length, 1)
  assert.equal(manifest.parts[0].startSeconds, 0.3)
  assert.equal(manifest.parts[0].duration, 0.8999999999999999)
  for (const start of [0, 0.3, 0.6]) {
    const at = events.filter(event => Math.abs(event.seconds - start) < 1e-14)
    const commands = at.map(event => event.bytes)
    for (const bytes of [[0xb0, 7, 90], [0xe0, 0, 65], [0xb0, 64, 127], [0x90, 60, 90],
      [0x80, 60, 45], [0x90, 62, 80], [0x80, 62, 31]]) assert.ok(commands.some(value => JSON.stringify(value) === JSON.stringify(bytes)))
    assert.ok(commands.findIndex(bytes => bytes[0] === 0x90 && bytes[1] === 62)
      < commands.findIndex(bytes => bytes[0] === 0x80 && bytes[1] === 62))
  }
  assert.equal(events.filter(event => JSON.stringify(event.bytes) === JSON.stringify([0x80, 64, 0])).length, 3)
  assert.equal(events.filter(event => JSON.stringify(event.bytes) === JSON.stringify([0xb0, 64, 0])).length, 3)
  assert.ok(!events.some(event => event.bytes[0] === 0x80 && event.bytes[1] === 64 && event.bytes[2] === 99))
  assert.ok(events.every((event, index) => index === 0 || event.seconds >= events[index - 1].seconds))
  cases++

  const independent = structuredClone(plan)
  independent.sources[0].events.push(wire(0.4, [0x90, 67, 95], 2))
  independent.sources[0].events.sort((a, b) => a.seconds - b.seconds)
  independent.regions[0].sourceEnd = 0.5
  independent.regions[0].repeatCount = 1
  independent.regions[0].periodNanoseconds.numerator = '400000000'
  const split = await prepare(independent)
  assert.deepEqual(split.manifest.parts.map(part => part.port), [0, 2])
  assert.ok(split.rows[0].every(event => !(event.bytes[0] === 0x90 && event.bytes[1] === 67)))
  assert.ok(split.rows[1].some(event => event.bytes[0] === 0x90 && event.bytes[1] === 67))
  assert.ok(split.rows[1].some(event => JSON.stringify(event.bytes) === JSON.stringify([0x80, 67, 0])))
  cases++

  const hold = structuredClone(independent)
  hold.sources[0].events = [wire(0, [0xb0, 69, 127]), wire(0, [0x90, 60, 80]), wire(0.4, [0x80, 60, 35])]
  hold.regions[0].sourceStart = 0; hold.regions[0].sourceEnd = 0.5
  hold.regions[0].periodNanoseconds.numerator = '500000000'
  const held = await prepare(hold)
  assert.deepEqual(held.rows[0].at(-1).bytes, [0xb0, 69, 0])
  assert.equal(held.rows[0].filter(event => event.bytes[0] === 0x80).length, 1)
  cases++

  async function refused(value) {
    const input = join(root, `refused-${++sequence}.json`), output = join(root, `refused-${sequence}`)
    await writeFile(input, JSON.stringify(value))
    await assert.rejects(exec(binary, ['export-vst', '--file', input, '--output', output]))
    await assert.rejects(access(output), { code: 'ENOENT' })
  }
  const unknown = structuredClone(plan)
  unknown.sources[0].events = [wire(0.2, [0x90, 60, 90]), wire(0.3, [0xb0, 1, 127])]
  await refused(unknown)

  // Refusal must never acquire cleanup authority over a pre-existing output,
  // including a symlink's target. Exercise both a publishable plan and one
  // that fails after part creation, where cleanup used to be dangerous.
  const sentinel = Buffer.from('\u0000owned source\r\n한글 cafe\u0301🙂\n')
  for (const kind of ['empty-directory', 'nonempty-directory', 'symlink']) {
    for (const value of [plan, unknown]) {
      const input = join(root, `owned-${++sequence}.json`), output = join(root, `owned-${sequence}`)
      const outside = join(root, `outside-${sequence}`)
      await writeFile(input, JSON.stringify(value))
      if (kind === 'symlink') {
        await mkdir(outside)
        await writeFile(join(outside, 'sentinel'), sentinel)
        await symlink(outside, output)
      } else {
        await mkdir(output)
        if (kind === 'nonempty-directory') await writeFile(join(output, 'sentinel'), sentinel)
      }
      const before = await lstat(output), names = await readdir(output)
      await assert.rejects(exec(binary, ['export-vst', '--file', input, '--output', output]))
      const after = await lstat(output)
      assert.equal(after.dev, before.dev)
      assert.equal(after.ino, before.ino)
      assert.deepEqual(await readdir(output), names)
      if (kind === 'symlink') {
        assert.ok(after.isSymbolicLink())
        assert.equal(await readlink(output), outside)
        assert.deepEqual(await readFile(join(outside, 'sentinel')), sentinel)
      } else {
        assert.ok(after.isDirectory())
        if (kind === 'nonempty-directory') assert.deepEqual(await readFile(join(output, 'sentinel')), sentinel)
      }
    }
    cases++
  }

  // One source event can finish its SysEx state while feed emits separate
  // incomplete SysEx fragments around realtime. The host accepts complete
  // messages only; refusing must leave no partially published directory.
  const interleaved = structuredClone(plan)
  interleaved.sources[0].events = [wire(0, [0xf0, 1, 0xf8, 2, 0xf7])]
  interleaved.regions[0].sourceStart = 0
  interleaved.regions[0].sourceEnd = 0.5
  interleaved.regions[0].repeatCount = 1
  interleaved.regions[0].periodNanoseconds.numerator = '500000000'
  await refused(interleaved)
  const completeRealtime = structuredClone(interleaved)
  completeRealtime.sources[0].events = [wire(0, [0x90, 60, 0xf8, 90, 0x80, 60, 0])]
  const complete = await prepare(completeRealtime)
  assert.deepEqual(complete.rows[0].map(event => event.bytes), [[0xf8], [0x90, 60, 90], [0x80, 60, 0]])
  cases++

  const opaque = structuredClone(plan)
  opaque.sources[0].events.unshift(wire(0, [0xf0, 1, 2, 0xf7]))
  await refused(opaque)
  const fragments = structuredClone(plan)
  fragments.sources[0].events = [wire(0, [0xf0, 1]), wire(0.1, [2, 0xf7])]
  await refused(fragments)
  const outside = structuredClone(plan); outside.duration = 0.4
  await refused(outside)
  cases++
  console.log(JSON.stringify({ passed: cases, failed: 0, scope: 'actual native VST region projection; no plug-in or device opened' }))
} finally { await rm(root, { recursive: true, force: true }) }
