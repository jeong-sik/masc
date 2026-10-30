import { mkdtemp, writeFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { validateSound } from './project-sound.mjs'
import { openSynthStream } from './synth-stream.mjs'

// The lease outlives preparation and child close. Stop/cancel latch before a
// child exists so a late font write can never open a retired synth.
export function openFluidStream(sound, { sampleRate = 44100, signal, directory = tmpdir(), spawnProcess } = {}) {
  validateSound(sound)
  if (sound.engine?.kind !== 'fluidsynth') throw new Error('Choose a bound FluidSynth sound')
  if (!Number.isInteger(sampleRate) || sampleRate <= 0 || sampleRate > 0xffffffff) throw new Error('Invalid SoundFont stream sample rate')
  signal?.throwIfAborted()
  sound = structuredClone(sound)
  const controller = new AbortController()
  let root, owner, stopping = false
  const cancel = (reason = new Error('SoundFont stream cancelled')) => {
    const error = reason instanceof Error ? reason : new Error('SoundFont stream cancelled', { cause: reason })
    controller.abort(error); owner?.cancel(error)
  }
  const abort = () => cancel(signal.reason)
  signal?.addEventListener('abort', abort, { once: true })
  let resolveReady, rejectReady
  const ready = new Promise((resolve, reject) => { resolveReady = resolve; rejectReady = reject })
  ready.catch(() => {})
  const earlyStop = () => { rejectReady(new Error('SoundFont stream stopped before opening')); return { kind: 'stopped', frames: '0' } }
  const completion = (async () => {
    let result
    try {
      root = await mkdtemp(join(directory, 'soundfont-stream-'))
      controller.signal.throwIfAborted()
      const path = join(root, 'bound.sf2')
      if (!stopping) await writeFile(path, Buffer.from(sound.font.data, 'base64'), { flag: 'wx', mode: 0o400 })
      controller.signal.throwIfAborted()
      if (stopping) result = earlyStop()
      else {
        owner = openSynthStream({ command: 'python3', args: [fileURLToPath(new URL('./soundfont_stream.py', import.meta.url))],
          spawnProcess, signal: controller.signal, label: 'SoundFont',
          opening: { kind: 'open', schemaVersion: 1, sampleRate, engine: sound.engine, bankStyle: sound.bankStyle,
            font: { path, sha256: sound.font.sha256 } },
          acknowledge: event => event.fontSha256 === sound.font.sha256 && event.bankStyle === sound.bankStyle
            && event.engine?.kind === 'fluidsynth' && event.engine.version === sound.engine.version
            && event.engine.controlFrames === sound.engine.controlFrames,
        })
        owner.ready.then(resolveReady, rejectReady)
        result = await owner.completion
      }
    } catch (error) { rejectReady(error); throw error }
    finally {
      try { if (root) await rm(root, { recursive: true, force: true }) }
      finally { signal?.removeEventListener('abort', abort) }
    }
    // Child finalization is only one stage; cancellation stays authoritative
    // through the final asynchronous font cleanup as well.
    controller.signal.throwIfAborted()
    return result
  })()
  completion.catch(() => {})
  if (signal?.aborted) abort()
  return { ready, completion,
    render(frames, messages) { return owner ? owner.render(frames, messages) : Promise.reject(new Error('SoundFont stream is preparing')) },
    stop() { stopping = true; owner?.stop() }, cancel,
  }
}
