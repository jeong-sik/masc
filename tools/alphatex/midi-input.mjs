import { spawn } from 'node:child_process'
import { createInterface } from 'node:readline'
import { fileURLToPath } from 'node:url'
import { unpackMidi } from './session-data.mjs'

export const midiInputPath = fileURLToPath(new URL('./music-midi-input', import.meta.url))
const maximumPendingWords = 65_536 // same 256 KiB native input backlog
function sourceUID(value) {
  const number = Number(value)
  if (typeof value !== 'string' || !Number.isInteger(number) || number < -2147483648 || number > 2147483647 || String(number) !== value) throw new Error('Choose an exact MIDI source UID')
  return value
}
function counter(value) {
  if (typeof value !== 'string') throw new Error('Invalid MIDI input counter')
  const parsed = BigInt(value)
  if (parsed < 0n || parsed > 0xffffffffffffffffn || String(parsed) !== value) throw new Error('Invalid MIDI input counter')
  return parsed
}

export async function listMidiSources({ signal, executable = midiInputPath, spawnProcess = spawn } = {}) {
  signal?.throwIfAborted()
  const child = spawnProcess(executable, ['--sources'], { stdio: ['ignore', 'pipe', 'pipe'] })
  let output = '', detail = '', failure
  child.stdout.setEncoding('utf8').on('data', text => { output += text })
  child.stderr.setEncoding('utf8').on('data', text => { detail += text })
  for (const stream of [child.stdout, child.stderr]) stream.on('error', error => { failure ??= error; child.kill('SIGTERM') })
  const abort = () => child.kill('SIGTERM')
  signal?.addEventListener('abort', abort, { once: true })
  if (signal?.aborted) abort()
  try {
    await new Promise((resolve, reject) => {
      child.once('error', error => { failure ??= error })
      child.once('close', (code, exitSignal) => {
        if (signal?.aborted) reject(signal.reason)
        else if (failure) reject(failure)
        else if (code !== 0) reject(new Error(detail || `MIDI discovery ended: ${code ?? exitSignal}`))
        else resolve()
      })
    })
  } finally { signal?.removeEventListener('abort', abort) }
  signal?.throwIfAborted()
  const result = JSON.parse(output), identities = new Set()
  if (result.kind !== 'midi-sources' || result.schemaVersion !== 1 || !Array.isArray(result.sources)) throw new Error('Invalid MIDI source catalog')
  for (const source of result.sources) {
    const uid = sourceUID(source?.id)
    if (typeof source.name !== 'string' || identities.has(uid)) throw new Error('Invalid MIDI source catalog identity')
    identities.add(uid)
  }
  return result.sources
}
// onPacket owns the admitted decision through its promise. The native owner
// cannot expose another packet until that promise settles and we acknowledge it.
// stop drains admitted input; abort/consumer failure rejects after child closure
// and after any admitted consumer operation settles. No audio/output is opened.
export function openMidiInput({ source, onPacket, signal, executable = midiInputPath, spawnProcess = spawn }) {
  sourceUID(source)
  if (typeof onPacket !== 'function') throw new Error('Provide the MIDI input packet consumer')
  signal?.throwIfAborted()
  const consumer = new AbortController()
  const child = spawnProcess(executable, ['--source', source], { stdio: ['pipe', 'pipe', 'pipe'] })
  let failure, closed = false, stopping = false, active = false, final, expected = 0n, inFlight = false, detail = ''
  let resolveReady, rejectReady, resolveClose
  const ready = new Promise((resolve, reject) => { resolveReady = resolve; rejectReady = reject })
  const closure = new Promise(resolve => { resolveClose = resolve })
  let processing = Promise.resolve()
  ready.catch(() => {})
  const fail = error => {
    failure ??= error instanceof Error ? error : new Error(String(error))
    consumer.abort(failure); rejectReady(failure)
    if (!closed) child.kill('SIGTERM')
  }
  const abort = () => fail(signal.reason)
  const write = value => {
    if (closed || child.stdin.destroyed) throw new Error('MIDI input command stream is closed')
    child.stdin.write(JSON.stringify(value) + '\n')
  }
  function stop() {
    if (closed || stopping) return
    stopping = true
    try { write({ kind: 'stop' }) } catch (error) { fail(error) }
  }
  const lines = createInterface({ input: child.stdout, crlfDelay: Infinity })
  lines.on('line', line => {
    if (failure || closed) return
    try {
      const event = JSON.parse(line)
      if (final) throw new Error('MIDI input data after finalization')
      switch (event.kind) {
        case 'midi-input':
          if (active || event.schemaVersion !== 1 || event.protocol !== 2 || event.source?.id !== source || typeof event.source.name !== 'string'
            || event.clock?.kind !== 'mach-host-time' || ![event.clock.numer, event.clock.denom].every(value => Number.isInteger(value) && value > 0 && value <= 0xffffffff)) throw new Error('Invalid selected MIDI input acknowledgement')
          active = true; resolveReady(event); break
        case 'midi': {
          if (!active || inFlight || event.source !== source || counter(event.ordinal) !== expected || counter(event.hostTime) < 0n
            || !Array.isArray(event.words) || !event.words.length || event.words.length > maximumPendingWords) throw new Error('Invalid ordered MIDI input packet')
          unpackMidi(event) // validates complete UMP framing/protocol/word values
          inFlight = true
          processing = processing.then(async () => {
            if (failure) return
            await onPacket(event, { signal: consumer.signal })
            if (failure || closed) return
            expected++; inFlight = false
            write({ kind: 'ack', ordinal: event.ordinal })
          }).catch(fail)
          break
        }
        case 'stopped':
          if (!active || inFlight || event.source !== source || event.success !== true || event.pendingWords !== 0
            || counter(event.admittedPackets) !== expected || counter(event.acknowledgedPackets) !== expected || counter(event.discardedPackets) !== 0n) throw new Error(event.error || 'MIDI input did not drain successfully')
          final = event; break
        case 'error': throw new Error(typeof event.message === 'string' ? event.message : 'MIDI input failed')
        default: throw new Error('Unknown MIDI input event')
      }
    } catch (error) { fail(error) }
  })
  for (const stream of [lines, child.stdout, child.stderr, child.stdin]) stream.on('error', error => {
    if (stream !== child.stdin || error.code !== 'EPIPE' || !stopping) fail(error)
  })
  child.stderr.setEncoding('utf8').on('data', text => { detail += text })
  child.once('error', fail)
  child.once('close', (code, exitSignal) => {
    closed = true; lines.close(); signal?.removeEventListener('abort', abort)
    if (code !== 0 || !final) fail(new Error(detail || `MIDI input closed without successful finalization: ${code ?? exitSignal}`))
    if (!active || failure) rejectReady(failure ?? new Error('MIDI input closed before admission'))
    resolveClose()
  })
  signal?.addEventListener('abort', abort, { once: true })
  if (signal?.aborted) abort()
  const completion = closure.then(async () => { await processing; if (failure) throw failure; return final })
  completion.catch(() => {})
  return { ready, completion, stop }
}
