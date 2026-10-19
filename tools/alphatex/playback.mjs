import { spawn } from 'node:child_process'
import { createInterface } from 'node:readline'
import { fileURLToPath } from 'node:url'

export const transportPath = fileURLToPath(new URL('./music-transport', import.meta.url))

// One owned child is one transport. Completion means its pipes and process have
// closed, rather than merely receiving a stopped acknowledgement.
export function openPlayback({ path, output, loop = false, onEvent = () => {}, signal,
  executable = transportPath, spawnProcess = spawn } = {}) {
  signal?.throwIfAborted()
  if (typeof path !== 'string' || !path) throw new Error('A WAV path is required')
  if (output !== undefined && (typeof output !== 'string' || !output)) throw new Error('Invalid output UID')
  if (typeof loop !== 'boolean') throw new Error('Invalid loop selection')
  const args = ['play', '--file', path, ...(output === undefined ? [] : ['--output', output]), ...(loop ? ['--loop'] : [])]
  const child = spawnProcess(executable, args, { stdio: ['pipe', 'pipe', 'pipe'] })
  let failure = null, final = null, current = null, firstDevice = null, started = false, closed = false, stopping = false, detail = ''
  let resolveReady, rejectReady, resolveDone, rejectDone
  const ready = new Promise((resolve, reject) => { resolveReady = resolve; rejectReady = reject })
  const completion = new Promise((resolve, reject) => { resolveDone = resolve; rejectDone = reject })
  // Callers may await either phase; keep rejection observed until they attach.
  ready.catch(() => {}); completion.catch(() => {})
  function fail(error) {
    if (failure) return
    failure = error
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
          || event.duration <= 0 || event.currentTime < 0 || event.currentTime > event.duration
          || typeof event.device?.id !== 'string' || !event.device.id || typeof event.device.name !== 'string'
          || !Number.isInteger(event.device.outputs) || event.device.outputs <= 0 || event.loop !== loop) {
        throw new Error('Malformed playback state')
      }
      if (output !== undefined && event.device.id !== output || firstDevice !== null && event.device.id !== firstDevice) {
        throw new Error('Playback output differs from the selected device')
      }
      if (!current && event.kind !== 'playing' && event.kind !== 'stopped') throw new Error('Playback did not begin with a playing acknowledgement')
      firstDevice ??= event.device.id
      current = event
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
    pause: () => command('pause'), resume: () => command('resume'), status: () => command('status'),
    seek(seconds) {
      if (!Number.isFinite(seconds) || seconds < 0 || !current || seconds > current.duration) throw new Error('Seek must be between zero and the WAV duration, inclusive')
      command('seek', { seconds })
    },
    // Terminal teardown may require immediate termination of only this child.
    terminate() { stopping = true; if (!closed) child.kill('SIGKILL') },
  }
}
