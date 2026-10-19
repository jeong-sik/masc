import { spawn } from 'node:child_process'
import { createInterface } from 'node:readline'
import { fileURLToPath } from 'node:url'
import { randomUUID } from 'node:crypto'

export const transportPath = fileURLToPath(new URL('./music-transport', import.meta.url))
export const midiTransportPath = fileURLToPath(new URL('./music-midi', import.meta.url))
export const arrangementTransportPath = fileURLToPath(new URL('./music-arrangement', import.meta.url))
export async function midiDestinations({ executable = midiTransportPath, signal } = {}) {
  signal?.throwIfAborted()
  const child = spawn(executable, ['destinations'], { stdio: ['ignore', 'pipe', 'pipe'] })
  let output = '', detail = '', failure = null, cancelled = false
  child.stdout.setEncoding('utf8').on('data', text => { output += text })
  child.stderr.setEncoding('utf8').on('data', text => { detail += text })
  const abort = () => { cancelled = true; child.kill('SIGTERM') }
  signal?.addEventListener('abort', abort, { once: true })
  try {
    await new Promise((resolve, reject) => {
      child.once('error', error => { failure = error })
      child.once('close', (code, exitSignal) => {
        if (cancelled) reject(signal.reason)
        else if (failure) reject(failure)
        else if (code !== 0) reject(new Error(detail || `MIDI discovery ended: ${code ?? exitSignal}`))
        else resolve()
      })
    })
  } finally { signal?.removeEventListener('abort', abort) }
  const result = JSON.parse(output)
  if (result.kind !== 'destinations' || !Array.isArray(result.destinations)) throw new Error('Malformed MIDI destination list')
  const ids = new Set()
  for (const device of result.destinations) {
    if (device.kind !== 'midi' || device.protocol !== 1 || typeof device.id !== 'string' || !device.id
        || typeof device.name !== 'string' || ids.has(device.id)) throw new Error('Malformed MIDI destination identity')
    ids.add(device.id)
  }
  return result.destinations
}

// One owned child is one transport. Completion means its pipes and process have
// closed, rather than merely receiving a stopped acknowledgement.
export function openPlayback({ path, output, midiOutput, midiBindings, loop = false, format = 'wave', onEvent = () => {}, signal,
  executable = ['wave-arrangement', 'mixed-arrangement', 'capture-session', 'capture-arrangement', 'hybrid-arrangement', 'capture-audio-arrangement'].includes(format) ? arrangementTransportPath : midiOutput === undefined ? transportPath : midiTransportPath, spawnProcess = spawn } = {}) {
  signal?.throwIfAborted()
  const hybrid = format === 'hybrid-arrangement'
  const captured = ['capture-session', 'capture-arrangement'].includes(format), mixed = format === 'mixed-arrangement' || captured || hybrid
  if (!['wave', 'wave-arrangement', 'midi-arrangement', 'mixed-arrangement', 'capture-session', 'capture-arrangement', 'hybrid-arrangement', 'capture-audio-arrangement'].includes(format) || ['wave-arrangement', 'capture-audio-arrangement'].includes(format) && midiOutput !== undefined || format === 'capture-audio-arrangement' && loop) throw new Error('Invalid arrangement playback route or loop')
  if ((format === 'midi-arrangement' || mixed) && (midiOutput === undefined || midiBindings === undefined || mixed && format !== 'mixed-arrangement' && loop)) throw new Error('MIDI arrangement requires explicit bindings; captured looping is not connected yet')
  if (mixed && !captured && output === undefined) throw new Error('Mixed arrangement requires an explicit audio output')
  if (typeof path !== 'string' || !path) throw new Error('A playback source path is required')
  if (output !== undefined && (typeof output !== 'string' || !output)) throw new Error('Invalid output UID')
  if (midiOutput !== undefined && (typeof midiOutput !== 'string' || !midiOutput)) throw new Error('Invalid MIDI destination ID')
  if (!mixed && output !== undefined && midiOutput !== undefined) throw new Error('Choose an audio output or a MIDI destination')
  if (midiBindings !== undefined) {
    if (midiOutput === undefined || !Array.isArray(midiBindings) || !midiBindings.length
        || midiBindings.some(binding => !Number.isSafeInteger(binding?.port) || binding.port < 0 || binding.port > ((format === 'midi-arrangement' || mixed) ? Number.MAX_SAFE_INTEGER : 127)
          || typeof binding.destination !== 'string' || !binding.destination)
        || new Set(midiBindings.map(binding => binding.port)).size !== midiBindings.length
        || (hybrid ? midiBindings.some(binding => ![1, 2].includes(binding.protocol)) : false)
        || new Set(midiBindings.map(binding => hybrid ? JSON.stringify([binding.destination, binding.protocol]) : binding.destination)).size !== midiBindings.length
        || midiBindings[0].destination !== midiOutput) throw new Error('Invalid MIDI source bindings')
    midiBindings = midiBindings.map(({ port, destination, protocol }) => ({ port, destination, ...(hybrid ? { protocol } : {}) }))
  }
  if (typeof loop !== 'boolean') throw new Error('Invalid loop selection')
  const selectedID = mixed ? output : midiOutput ?? output
  const selection = mixed || midiOutput === undefined ? (output === undefined ? [] : ['--output', output]) : ['--destination', midiOutput]
  const args = ['play', '--file', path, ...selection, ...(loop ? ['--loop'] : [])]
  const child = spawnProcess(executable, args, { stdio: ['pipe', 'pipe', 'pipe'] })
  let failure = null, final = null, current = null, firstDevice = null, started = false, closed = false, stopping = false, detail = ''
  let resolveReady, rejectReady, resolveDone, rejectDone
  const epochs = new Map()
  function rejectEpochs(error) { for (const pending of epochs.values()) pending.reject(error); epochs.clear() }
  const ready = new Promise((resolve, reject) => { resolveReady = resolve; rejectReady = reject })
  const completion = new Promise((resolve, reject) => { resolveDone = resolve; rejectDone = reject })
  // Callers may await either phase; keep rejection observed until they attach.
  ready.catch(() => {}); completion.catch(() => {})
  function fail(error) {
    if (failure) return
    failure = error
    rejectEpochs(error)
    rejectReady(error)
    if (!closed) child.kill('SIGTERM')
  }
  const lines = createInterface({ input: child.stdout, crlfDelay: Infinity })
  lines.on('line', line => {
    if (failure || closed) return
    try {
      const event = JSON.parse(line)
      if (event.kind === 'error') {
        if (typeof event.message !== 'string' || !event.message) throw new Error('Malformed playback error')
        fail(new Error(event.message))
        onEvent(event); return
      }
      if (!['playing', 'paused', 'stopped'].includes(event.kind) || final
          || !Number.isFinite(event.currentTime) || !Number.isFinite(event.duration)
          || (midiBindings === undefined ? event.duration <= 0 : event.duration < 0) || event.currentTime < 0 || event.currentTime > event.duration
          || typeof event.device?.id !== 'string' || !event.device.id || typeof event.device.name !== 'string'
          || (mixed || midiOutput === undefined ? !Number.isInteger(event.device.outputs) || event.device.outputs <= 0
            : event.device.kind !== 'midi' || event.device.protocol !== 1) || event.loop !== loop) {
        throw new Error('Malformed playback state')
      }
      if (mixed && (event.format !== format || event.clock?.kind !== 'mach-host-time')) throw new Error('Missing combined arrangement clock')
      if (format === 'capture-audio-arrangement' && (event.format !== format || event.clock?.kind !== 'mach-host-time')) throw new Error('Missing captured audio arrangement clock')
      if (midiBindings !== undefined) {
        if (!Array.isArray(event.bindings) || event.bindings.length !== midiBindings.length
            || event.bindings.some((binding, index) => binding.port !== midiBindings[index].port
              || binding.device?.id !== midiBindings[index].destination || binding.device.kind !== 'midi'
              || binding.device.protocol !== (hybrid ? midiBindings[index].protocol : captured ? 2 : 1) || typeof binding.device.name !== 'string')) {
          throw new Error('Playback source ports differ from the selected bindings')
        }
      }
      if (selectedID !== undefined && event.device.id !== selectedID || firstDevice !== null && event.device.id !== firstDevice) {
        throw new Error('Playback output differs from the selected device')
      }
      if (!current && event.kind !== 'playing' && event.kind !== 'stopped') throw new Error('Playback did not begin with a playing acknowledgement')
      firstDevice ??= event.device.id
      current = event
      if (event.recordingRequest !== undefined) {
        const pending = epochs.get(event.recordingRequest)
        if (pending) {
          epochs.delete(event.recordingRequest)
          if (event.kind === 'playing') pending.resolve(event)
          else pending.reject(new Error('Arrangement is not playing at recording admission'))
        }
      }
      if (event.kind === 'stopped') rejectEpochs(new Error('Playback stopped before recording admission'))
      if (event.kind === 'stopped') final = event
      else if (event.kind === 'playing') { started = true; resolveReady(event) }
      onEvent(event)
    } catch (error) { fail(error) }
  })
  lines.once('error', fail)
  child.stdout.once('error', fail)
  child.stdin.once('error', fail)
  child.stderr.setEncoding('utf8').on('data', text => { detail += text })
  child.once('error', fail)
  const abort = () => { stopping = true; child.kill('SIGTERM') }
  signal?.addEventListener('abort', abort, { once: true })
  child.once('close', (code, exitSignal) => {
    closed = true; signal?.removeEventListener('abort', abort); lines.close()
    rejectEpochs(failure ?? new Error('Playback closed before recording admission'))
    if (failure || code !== 0 || !final) {
      const error = failure ?? new Error(detail.trim() || `Playback ended without finalization: ${code ?? exitSignal}`)
      rejectReady(error); rejectDone(error)
    } else {
      if (!started) rejectReady(new Error('Playback stopped before starting'))
      else resolveReady(current)
      resolveDone(final)
    }
  })
  function command(kind, extra = {}) {
    if (failure) throw failure
    if (closed || stopping) throw new Error('Playback is stopping or closed')
    if (!current || current.kind === 'stopped') throw new Error('Playback is not ready')
    child.stdin.write(JSON.stringify({ kind, ...extra }) + '\n')
  }
  function stop() {
    if (failure || closed || stopping) return
    stopping = true
    if (!child.stdin.destroyed) child.stdin.end('{"kind":"stop"}\n')
  }
  if (signal?.aborted) abort()
  return { ready, completion, stop,
    recordingEpoch({ signal } = {}) {
      if (loop) return Promise.reject(new Error('Loop recording requires cycle-aware take placement'))
      if (format === 'wave') return Promise.reject(new Error('Recording epochs require an arrangement'))
      if (signal?.aborted) return Promise.reject(signal.reason)
      const request = randomUUID()
      return new Promise((resolve, reject) => {
        const clear = () => { epochs.delete(request); signal?.removeEventListener('abort', abort) }
        const abort = () => { clear(); reject(signal.reason) }
        epochs.set(request, { resolve: event => { clear(); resolve(event) }, reject: error => { clear(); reject(error) } })
        signal?.addEventListener('abort', abort, { once: true })
        try { command('recordingEpoch', { request }) }
        catch (error) { clear(); reject(error) }
      })
    },
    pause: () => command('pause'), resume: () => command('resume'), status: () => command('status'),
    seek(seconds) {
      if (!Number.isFinite(seconds) || seconds < 0 || !current || seconds > current.duration) throw new Error('Seek must be between zero and the playback duration, inclusive')
      command('seek', { seconds })
    },
    // The native owner handles SIGTERM by releasing its held MIDI keys before
    // closing. Completion still owns that cleanup; SIGKILL would leave notes on.
    terminate() { stopping = true; if (!closed) child.kill('SIGTERM') },
  }
}
