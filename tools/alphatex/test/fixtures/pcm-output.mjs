import { createInterface } from 'node:readline'
const mode = process.argv[2]
if (mode === 'cancel-race') process.on('SIGTERM', () => {})
let next = 1n, admitted = 0n
const reply = row => process.stdout.write(JSON.stringify(row) + '\n')
const need = () => reply({ kind: 'need', id: String(next++), frames: 8, startFrame: String(admitted) })
reply({ kind: 'ready', schemaVersion: 1, device: { id: mode === 'identity' ? 'other' : 'owned', name: 'Owned fixture' }, sampleRate: 48000, blockFrames: 8, prefillFrames: 16 })
need()
createInterface({ input: process.stdin }).on('line', line => {
  const row = JSON.parse(line)
  if (row.kind === 'block') {
    admitted += 8n
    if (admitted === 16n) reply({ kind: 'playing' })
    if (mode === 'underrun' && admitted === 16n) { reply({ kind: 'error', message: 'PCM underrun' }); return }
    if (mode === 'demand') reply({ kind: 'need', id: '999', frames: 8, startFrame: '0' })
    else need()
  } else if (row.kind === 'stop') {
    if (mode !== 'unfinalized') reply({ kind: 'stopped', success: true,
      admittedFrames: String(admitted), renderedFrames: mode === 'total' ? '999' : '0',
      discardedFrames: String(admitted), underrunFrames: '0' })
    if (mode === 'exit') process.exitCode = 1
  }
})
