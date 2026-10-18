import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, writeFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { devices } from '../capture.mjs'

test('discovery cancellation rejects AbortError and spawn failure rejects its actual cause', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'masc-discovery-cancel-'))
  const executable = join(directory, 'discovery')
  try {
    await writeFile(executable, `#!/usr/bin/env node
process.stdout.write(JSON.stringify({kind: 'devices', audio: [], midi: []}))
`, { mode: 0o700 })
    const controller = new AbortController()
    const discovery = devices({ executable, signal: controller.signal })
    // Register rejection handling before cancellation to avoid unhandled rejections.
    const rejected = assert.rejects(discovery, { name: 'AbortError' })
    controller.abort()
    await rejected
    await assert.rejects(devices({ executable, signal: controller.signal }), { name: 'AbortError' })
    await assert.rejects(devices({ executable: join(directory, 'missing') }), { code: 'ENOENT' })
    assert.deepEqual(await devices({ executable }), { kind: 'devices', audio: [], midi: [] })
  } finally { await rm(directory, { recursive: true, force: true }) }
})
