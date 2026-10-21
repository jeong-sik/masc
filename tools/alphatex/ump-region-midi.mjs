import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { writeFile } from 'node:fs/promises'
import { join } from 'node:path'
export async function extractUmpRegion(source, cut, { directory, signal, dueAdmission = 'reconstructed',
  executable = fileURLToPath(new URL('./music-arrangement', import.meta.url)) } = {}) {
  const sourceDivisor = cut.sourceDivisor ?? '1', path = join(directory, 'region.json')
  const plan = { schemaVersion: 1, dueAdmission, offset: cut.offset, extent: cut.extent, sourceDivisor, source }
  await writeFile(path, JSON.stringify(plan), { flag: 'wx', mode: 0o400, signal }); signal?.throwIfAborted()
  const child = spawn(executable, ['extract-ump-region', '--file', path], { stdio: ['ignore', 'pipe', 'pipe'] })
  const output = [], details = []; let failure = null
  child.stdout.on('data', bytes => output.push(bytes)); child.stderr.on('data', bytes => details.push(bytes))
  const abort = () => child.kill('SIGTERM')
  signal?.addEventListener('abort', abort, { once: true }); if (signal?.aborted) abort()
  try {
    await new Promise((resolve, reject) => {
      child.once('error', error => { failure = error })
      child.once('close', (code, exitSignal) => {
        if (signal?.aborted) reject(signal.reason)
        else if (failure) reject(failure)
        else if (code !== 0) reject(new Error(Buffer.concat(details).toString('utf8') || `UMP extraction failed: ${code ?? exitSignal}`))
        else resolve()
      })
    })
  } finally { signal?.removeEventListener('abort', abort) }
  const result = JSON.parse(Buffer.concat(output).toString('utf8'))
  if (result?.schemaVersion !== 1 || result.kind !== 'ump-region-events' || result.extent !== cut.extent
      || result.sourceDivisor !== sourceDivisor || !Array.isArray(result.events)) throw new Error('UMP extraction changed its selected span')
  const sources = new Set(source.timeline.bindings.map(binding => binding.source))
  let previous = 0n
  for (const row of result.events) {
    if (typeof row.offset !== 'string' || !/^(0|[1-9][0-9]*)$/.test(row.offset) || BigInt(row.offset) >= (1n << 128n)) throw new Error('Invalid UMP extraction offset')
    const value = BigInt(row.offset)
    if (value < previous || value >= BigInt(cut.extent) || !sources.has(row.source)) throw new Error('UMP extraction changed its source or event range')
    previous = value
  }
  signal?.throwIfAborted()
  return { ...result, offset: cut.offset }
}
