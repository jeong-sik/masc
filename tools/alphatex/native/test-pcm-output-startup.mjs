// Compile an isolated production helper. Both refusals happen before engine
// startup; no output is selected as a replacement and no default is changed.
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { mkdtemp, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'

if (process.platform !== 'darwin') { console.log('PCM_OUTPUT_STARTUP_SKIP: CoreAudio requires macOS'); process.exit(0) }
const directory = await mkdtemp(join(tmpdir(), 'masc-pcm-output-startup-'))
try {
  const executable = join(directory, 'music-pcm-output')
  const compiled = spawnSync('xcrun', ['swiftc', '-parse-as-library', '-O',
    ...['PcmRing.swift', 'PcmOutput.swift'].map(name => new URL(name, import.meta.url).pathname),
    '-o', executable, '-framework', 'AVFoundation', '-framework', 'CoreAudio'], { encoding: 'utf8' })
  assert.equal(compiled.error, undefined)
  assert.equal(compiled.signal, null)
  assert.equal(compiled.status, 0, compiled.stderr)
  for (const args of [['--output', `masc-missing-${randomUUID()}`], ['--unknown']]) {
    const child = spawnSync(executable, args, { encoding: 'utf8' })
    assert.equal(child.error, undefined)
    assert.equal(child.signal, null)
    assert.equal(child.status, 1)
    const rows = child.stdout.trim().split('\n').map(line => JSON.parse(line))
    assert.equal(rows.length, 1)
    assert.equal(rows[0].kind, 'error')
    assert.equal(typeof rows[0].message, 'string')
    assert.ok(rows[0].message)
  }
  console.log('PCM_OUTPUT_STRUCTURED_STARTUP_REFUSAL_PASS')
} finally {
  await rm(directory, { recursive: true, force: true })
}
