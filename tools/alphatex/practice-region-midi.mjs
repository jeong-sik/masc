import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { practiceRange, practiceRegionTime, practiceUnsigned } from './practice-source.mjs'

export async function extractPracticeRegion(asset, packets, cut, { directory, signal,
  executable = fileURLToPath(new URL('./music-arrangement', import.meta.url)) } = {}) {
  const range = practiceRange(asset), full = practiceRegionTime(asset, { offset: '0', extent: range.extent })
  practiceRegionTime(asset, cut)
  const sourceDivisor = cut.sourceDivisor ?? '1', path = join(directory, 'region.json')
  const plan = { schemaVersion: 1, offset: cut.offset, extent: cut.extent, sourceDivisor,
    source: { id: asset.id, extent: range.extent, timeline: { schemaVersion: 4, duration: full.durationSeconds,
      clock: { origin: range.origin, ...asset.metadata.input.clock },
      bindings: [{ source: asset.metadata.input.source.id, destination: asset.metadata.input.source.id }], packets } } }
  await writeFile(path, JSON.stringify(plan), { flag: 'wx', mode: 0o400, signal }); signal?.throwIfAborted()
  const child = spawn(executable, ['extract-practice-region', '--file', path], { stdio: ['ignore', 'pipe', 'pipe'] })
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
        else if (code !== 0) reject(new Error(Buffer.concat(details).toString('utf8') || `Practice extraction failed: ${code ?? exitSignal}`))
        else resolve()
      })
    })
  } finally { signal?.removeEventListener('abort', abort) }
  const result = JSON.parse(Buffer.concat(output).toString('utf8'))
  if (result?.schemaVersion !== 1 || result.kind !== 'practice-region-events' || result.extent !== cut.extent
      || result.sourceDivisor !== sourceDivisor || !Array.isArray(result.events)) throw new Error('Practice extraction changed its selected span')
  let previous = 0n
  for (const row of result.events) {
    const value = practiceUnsigned(row.offset, (1n << 128n) - 1n)
    if (value < previous || value >= BigInt(cut.extent) || row.source !== asset.metadata.input.source.id) throw new Error('Practice extraction changed its source or event range')
    previous = value
  }
  signal?.throwIfAborted()
  return result
}
