// Run against an isolated compiled helper. Both refusals happen before engine
// startup; no output is selected as a replacement and no default is changed.
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { randomUUID } from 'node:crypto'

const executable = process.argv[2]
assert.ok(executable, 'pass the isolated music-pcm-output executable')
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
