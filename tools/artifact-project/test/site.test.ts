import { test, mock } from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import { mkdir, mkdtemp, writeFile, realpath } from 'node:fs/promises'
import { syncBuiltinESMExports } from 'node:module'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { collectSite } from '../src/site.ts'

for (const change of ['replace-read-file', 'add-chunk']) {
  test(`rejects ${change} while later output files are being collected`, async () => {
    const source = await realpath(await mkdtemp(join(tmpdir(), 'masc-site-race-'))), output = join(source, 'dist')
    await mkdir(output)
    await writeFile(join(output, 'a.js'), 'globalThis.first=true')
    await writeFile(join(output, 'b.js'), 'globalThis.second=true')
    await writeFile(join(output, 'index.html'), '<p>entry</p>')
    const original = fs.promises.open
    let changed = false
    // Schedule a real filesystem mutation at the I/O boundary after a.js has
    // been captured. Reads still use actual file handles and real file bytes.
    const replacement = async (...args: Parameters<typeof original>) => {
      if (String(args[0]) === join(output, 'b.js') && !changed) {
        changed = true
        if (change === 'replace-read-file') await writeFile(join(output, 'a.js'), 'globalThis.first=false')
        else await writeFile(join(output, 'late.js'), 'globalThis.added=true')
      }
      return original(...args)
    }
    const mocked = mock.method(fs.promises, 'open', replacement)
    syncBuiltinESMExports()
    try {
      const failure = await collectSite(source, 'dist', 'index.html').then(() => null, (error: unknown) => error)
      assert.equal(changed, true, 'the real concurrent mutation must be triggered')
      assert.ok(failure instanceof Error)
      assert.match(failure.message, /changed while collecting/)
    } finally { mocked.mock.restore(); syncBuiltinESMExports() }
  })
}
