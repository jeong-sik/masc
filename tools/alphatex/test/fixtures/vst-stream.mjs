import { createInterface } from 'node:readline'
const mode = process.argv[2]
let total = 0n
const reply = value => process.stdout.write(JSON.stringify(value) + '\n')
createInterface({ input: process.stdin }).on('line', line => {
  const row = JSON.parse(line)
  if (row.kind === 'open') {
    if (mode === 'wait') return
    reply({ kind: 'ready', schemaVersion: 1, sampleRate: row.sampleRate, channels: 2,
      instrument: mode === 'identity' ? { identifier: 'other' } : row.instrument, preset_sha256: row.preset.sha256 })
  } else if (row.kind === 'render') {
    if (mode === 'wait-block') return
    if (mode === 'crash') { process.exitCode = 1; process.stdin.destroy(); return }
    const data = Buffer.alloc(row.frames * 8)
    for (let i = 0; i < data.length; i += 8) {
      data.writeFloatLE(mode === 'nan' ? NaN : .25, i); data.writeFloatLE(-.125, i + 4)
    }
    total += BigInt(row.frames)
    reply({ kind: 'block', id: mode === 'sequence' ? row.id + 1 : row.id, frames: row.frames,
      pcm: mode === 'truncated' ? data.subarray(4).toString('base64') : data.toString('base64') })
  } else if (row.kind === 'stop' && mode !== 'unfinalized') {
    reply({ kind: 'stopped', frames: String(total) })
  }
})
