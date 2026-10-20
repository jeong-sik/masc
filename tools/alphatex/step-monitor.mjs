import { Worker } from 'node:worker_threads'
import { randomUUID } from 'node:crypto'
import { validateSound } from './project-sound.mjs'
import { monitorPacket } from './step-monitor-session.mjs'
export { monitorPacket } from './step-monitor-session.mjs'

// The terminal owns note decisions; the worker owns every device demand and
// synth block. No per-block acknowledgement crosses the terminal event loop.
export function openStepMonitor({ sound, output, channel, signal,
  createWorker = (url, options) => new Worker(url, options) }) {
  validateSound(sound)
  if (sound.kind !== 'vst') throw new Error('Choose a VST instrument before monitored step input')
  if (!Number.isInteger(channel) || channel < 0 || channel > 15) throw new Error('Invalid monitor target channel')
  signal?.throwIfAborted()
  sound = structuredClone(sound)
  const id = randomUUID()
  const worker = createWorker(new URL('./step-monitor-worker.mjs', import.meta.url), {
    workerData: { sound, output, channel, id }, name: 'music-monitor' })
  const threadId = worker.threadId
  let held = new Map(), pending = null, inspection = null, snapshot = null
  let stopping = false, closed = false, terminal = null, failure = null
  let resolveReady, rejectReady, resolveDone, rejectDone
  const ready = new Promise((resolve, reject) => { resolveReady = resolve; rejectReady = reject })
  const completion = new Promise((resolve, reject) => { resolveDone = resolve; rejectDone = reject })
  ready.catch(() => {}); completion.catch(() => {})
  const diagnostics = () => structuredClone({
    ...(snapshot ?? { schemaVersion: 1, kind: 'step-monitor', id, channel,
      sound: { name: sound.selection.name, identifier: sound.instrument.identifier,
        version: sound.instrument.version, presetSHA256: sound.preset.sha256 }, pcm: null }),
    worker: { threadId, closed, terminalReceived: terminal !== null, failure: failure?.message ?? null },
  })
  const post = value => { if (!closed) worker.postMessage(value) }
  const fail = reason => {
    failure ??= reason instanceof Error ? reason : new Error('Step monitor failed', { cause: reason })
    rejectReady(failure)
    pending?.reject(failure); pending = null
    // Keep the caller's exact cause even when it cannot be cloned. The worker
    // needs the cancellation decision to retire its owned children.
    try { post({ kind: 'cancel', message: failure.message }) } catch { /* exit/error settles below */ }
  }
  const abort = () => fail(signal.reason)
  signal?.addEventListener('abort', abort, { once: true })
  worker.on('message', message => {
    try {
      if (message.diagnostics) snapshot = message.diagnostics
      switch (message.kind) {
        case 'ready': if (!stopping && !failure) resolveReady(message.device); break
        case 'sent': pending?.resolve(); pending = null; break
        case 'diagnostics': inspection?.resolve(diagnostics()); inspection = null; break
        case 'terminal':
          terminal = message
          if (message.error) fail(message.error)
          rejectReady(failure ?? new Error('Step monitor stopped before playback'))
          break
        default: throw new Error('Invalid monitor worker reply')
      }
    } catch (error) { fail(error) }
  })
  worker.on('messageerror', fail)
  worker.on('error', fail)
  worker.once('exit', code => {
    closed = true
    signal?.removeEventListener('abort', abort)
    if (!terminal || code !== 0) failure ??= new Error(`Monitor worker exited ${code} without confirmed cleanup`)
    if (!stopping && !failure) failure = new Error('Monitor worker ended before stop')
    rejectReady(failure ?? new Error('Step monitor stopped before playback'))
    if (failure) pending?.reject(failure)
    else pending?.resolve()
    pending = null; held.clear()
    inspection?.resolve(diagnostics()); inspection = null
    if (failure) rejectDone(failure)
    else resolveDone(terminal.device)
  })
  if (signal?.aborted) abort()
  return { ready, completion, diagnostics,
    inspect() {
      if (closed) return Promise.resolve(diagnostics())
      if (inspection) return inspection.promise
      let resolve
      const promise = new Promise(done => { resolve = done })
      inspection = { promise, resolve }
      try { post({ kind: 'inspect' }) } catch (error) { fail(error) }
      return promise
    },
    prepare(packet) { return monitorPacket(packet, channel, held) },
    send(prepared) {
      if (failure) return Promise.reject(failure)
      if (stopping) return Promise.resolve()
      if (pending) return Promise.reject(new Error('Consume the pending monitor packet first'))
      held = new Map(prepared.held)
      if (!prepared.messages.length) return Promise.resolve()
      return new Promise((resolve, reject) => {
        pending = { resolve, reject }
        try { post({ kind: 'send', messages: prepared.messages }) } catch (error) { fail(error) }
      })
    },
    stop() {
      if (stopping || closed) return
      stopping = true
      try { post({ kind: 'stop' }) } catch (error) { fail(error) }
    },
    cancel: fail,
  }
}
