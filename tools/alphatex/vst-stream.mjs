import { spawn } from 'node:child_process'
import { createInterface } from 'node:readline'
import { validateSound } from './project-sound.mjs'

// The audio consumer owns the clock and requests one block at a time. No
// speculative audio queue, audio device, or external MIDI endpoint is opened.
export function openVstStream(sound, { sampleRate = 44100, signal,
  command = 'masc-vst-host', args = [], spawnProcess = spawn } = {}) {
  validateSound(sound)
  if (sound.kind !== 'vst') throw new Error('Choose a project-bound VST sound')
  sound = { selection: { plugin_path: sound.selection.plugin_path, plugin_name: sound.selection.plugin_name },
    instrument: { identifier: sound.instrument.identifier, version: sound.instrument.version },
    preset: { data: sound.preset.data, sha256: sound.preset.sha256 } }
  if (!Number.isInteger(sampleRate) || sampleRate <= 0 || sampleRate > 0xffffffff) throw new Error('Invalid VST stream sample rate')
  signal?.throwIfAborted()
  const opening = JSON.stringify({ kind: 'open', schemaVersion: 1, sampleRate,
    plugin_path: sound.selection.plugin_path, plugin_name: sound.selection.plugin_name,
    instrument: sound.instrument, preset: sound.preset }) + '\n'
  const child = spawnProcess(command, [...args, '--stream'], { stdio: ['pipe', 'pipe', 'pipe'] })
  let failure = null, closed = false, stopping = false, admitted = false, final = null, pending = null
  let sequence = 0, frames = 0n, detail = ''
  let resolveReady, rejectReady, resolveDone, rejectDone
  const ready = new Promise((resolve, reject) => { resolveReady = resolve; rejectReady = reject })
  const completion = new Promise((resolve, reject) => { resolveDone = resolve; rejectDone = reject })
  ready.catch(() => {}); completion.catch(() => {})
  function fail(error) {
    failure ??= error instanceof Error ? error : new Error('VST stream failed', { cause: error })
    rejectReady(failure)
    pending?.reject(failure); pending = null
    if (!closed) child.kill('SIGTERM')
  }
  const abort = () => fail(signal.reason)
  signal?.addEventListener('abort', abort, { once: true })
  const lines = createInterface({ input: child.stdout, crlfDelay: Infinity })
  lines.on('line', line => {
    if (failure || closed) return
    try {
      const event = JSON.parse(line)
      if (event?.kind === 'error' && typeof event.message === 'string') throw new Error(event.message)
      if (final) throw new Error('VST stream replied after finalization')
      switch (event?.kind) {
        case 'ready':
          if (admitted || event.schemaVersion !== 1 || event.sampleRate !== sampleRate || event.channels !== 2
              || event.instrument?.identifier !== sound.instrument.identifier || event.instrument?.version !== sound.instrument.version
              || event.preset_sha256 !== sound.preset.sha256) throw new Error('VST stream sound acknowledgement mismatch')
          admitted = true; resolveReady(event); break
        case 'block': {
          if (!admitted || !pending || event.id !== pending.id || event.frames !== pending.frames || typeof event.pcm !== 'string') throw new Error('Unexpected VST PCM block')
          const pcm = Buffer.from(event.pcm, 'base64')
          if (pcm.toString('base64') !== event.pcm || pcm.length !== event.frames * 2 * 4) throw new Error('Invalid VST PCM block length')
          for (let i = 0; i < pcm.length; i += 4) if (!Number.isFinite(pcm.readFloatLE(i))) throw new Error('Nonfinite VST PCM sample')
          frames += BigInt(event.frames)
          const owner = pending; pending = null; owner.resolve(pcm); break
        }
        case 'stopped':
          if (!admitted || !stopping || pending || event.frames !== String(frames)) throw new Error('VST stream did not finalize admitted blocks')
          final = event; break
        default: throw new Error('Invalid VST stream acknowledgement')
      }
    } catch (error) { fail(error) }
  })
  lines.once('error', fail); child.stdout.once('error', fail); child.stderr.once('error', fail)
  child.once('error', fail)
  child.stdin.on('error', error => { if (error.code !== 'EPIPE' || !stopping) fail(error) })
  child.stderr.setEncoding('utf8').on('data', text => { detail = (detail + text).slice(-64 * 1024) })
  child.once('close', (code, exitSignal) => {
    closed = true; signal?.removeEventListener('abort', abort); lines.close()
    if (!failure && (code !== 0 || !final)) fail(new Error(detail || `VST stream closed without finalization: ${code ?? exitSignal}`))
    if (failure) rejectDone(failure)
    else resolveDone(final)
  })
  try { child.stdin.write(opening) } catch (error) { fail(error) }
  if (signal?.aborted) abort()
  return { ready, completion,
    render(count, messages = []) {
      if (failure) return Promise.reject(failure)
      if (closed || stopping || !admitted) return Promise.reject(new Error('VST stream is not accepting blocks'))
      if (pending) return Promise.reject(new Error('Consume the pending VST block before requesting another'))
      if (!Number.isInteger(count) || count <= 0 || count > 2 ** 24 || !Array.isArray(messages)) return Promise.reject(new Error('Invalid VST block request'))
      if (!Number.isSafeInteger(sequence + 1)) return Promise.reject(new Error('VST block sequence exceeds JSON integer precision'))
      return new Promise((resolve, reject) => {
        try {
          const request = JSON.stringify({ kind: 'render', id: sequence + 1, frames: count, messages })
          pending = { id: ++sequence, frames: count, resolve, reject }
          child.stdin.write(request + '\n')
        } catch (error) { fail(error); reject(error) }
      })
    },
    stop() {
      if (closed || stopping || failure) return
      stopping = true
      child.stdin.end('{"kind":"stop"}\n')
    },
    cancel(reason = new Error('VST stream cancelled')) { fail(reason) },
  }
}
