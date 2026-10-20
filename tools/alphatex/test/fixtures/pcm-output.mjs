import { createInterface } from 'node:readline'
const mode = process.argv[2]
if (mode === 'cancel-race') process.on('SIGTERM', () => {})
let next = 1n, admitted = 0n
let demandTimer
const reply = row => process.stdout.write(JSON.stringify(row) + '\n')
const need = () => reply({ kind: 'need', id: String(next++), frames: 8, startFrame: String(admitted) })
const final = (success = true, fault = 'none') => ({ kind: 'stopped', success, fault,
  faultFrames: fault === 'none' ? '0' : '8', admittedFrames: String(admitted),
  renderedFrames: mode === 'total' ? '999' : success ? '0' : String(admitted),
  discardedFrames: success ? String(admitted) : '0', underrunFrames: fault === 'underrun' ? '8' : '0',
  demand: { completedBlocks: String(admitted / 8n), lastResponseNanoseconds: admitted ? '17' : '0',
    playingBlocks: String(admitted > 16n ? admitted / 8n - 2n : 0n), maxPlayingResponseNanoseconds: admitted > 16n ? '19' : '0',
    maxResponseNanoseconds: admitted ? '19' : '0', pendingNanoseconds: null } })
reply({ kind: 'ready', schemaVersion: 2, device: { id: mode === 'identity' ? 'other' : 'owned', name: 'Owned fixture' }, sampleRate: 48000, blockFrames: 8, prefillFrames: 16 })
need()
createInterface({ input: process.stdin }).on('close', () => clearTimeout(demandTimer)).on('line', line => {
  const row = JSON.parse(line)
  if (row.kind === 'block') {
    admitted += 8n
    if (admitted === 16n) reply({ kind: 'playing' })
    if (['fault-final','format-final'].includes(mode) && admitted === 16n) {
      const fault = mode === 'fault-final' ? 'underrun' : 'render-format'
      reply({ kind: 'error', message: fault }); reply(final(false, fault))
      process.exitCode = 1; process.stdin.destroy(); return
    }
    if (mode === 'underrun' && admitted === 16n) { reply({ kind: 'error', message: 'PCM underrun' }); return }
    if (mode === 'demand') reply({ kind: 'need', id: '999', frames: 8, startFrame: '0' })
    else if (mode === 'paced') demandTimer = setTimeout(need, 2)
    else need()
  } else if (row.kind === 'stop') {
    clearTimeout(demandTimer)
    if (mode !== 'unfinalized') reply(final())
    if (mode === 'exit') process.exitCode = 1
  }
})
