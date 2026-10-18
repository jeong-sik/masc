import { spawn } from 'node:child_process'
import { createInterface } from 'node:readline'
import { fileURLToPath } from 'node:url'
import { readCapture } from './session-data.mjs'

export const nativePath = fileURLToPath(new URL('./music-native', import.meta.url))

export async function devices({ executable = nativePath, signal } = {}) {
  const aborted = () => new DOMException('Device discovery cancelled', 'AbortError')
  if (signal?.aborted) throw aborted()
  const child = spawn(executable, ['devices'], { stdio: ['ignore', 'pipe', 'pipe'] })
  let output = '', detail = '', failure = null, cancelled = false
  child.stdout.setEncoding('utf8').on('data', text => { output += text })
  child.stderr.setEncoding('utf8').on('data', text => { detail += text })
  const cancel = () => { cancelled = true; child.kill('SIGTERM') }
  signal?.addEventListener('abort', cancel, { once: true })
  try {
    // close follows stdout/stderr closure, including spawn failures. Cancellation
    // owns the process until that boundary so the terminal can safely be restored.
    await new Promise((resolve, reject) => {
      child.once('error', error => { failure = error })
      child.once('close', (code, exitSignal) => {
        if (cancelled) reject(aborted())
        else if (failure) reject(failure)
        else if (code !== 0) reject(new Error(detail || `Device discovery ended: ${code ?? exitSignal}`))
        else resolve()
      })
    })
  } finally { signal?.removeEventListener('abort', cancel) }
  const result = JSON.parse(output)
  if (result.kind !== 'devices' || !Array.isArray(result.audio) || !Array.isArray(result.midi)) throw new Error('Invalid device discovery response')
  for (const device of result.audio) {
    if (typeof device.id !== 'string' || typeof device.name !== 'string'
      || !Number.isSafeInteger(device.inputs) || !Number.isSafeInteger(device.outputs)) throw new Error('Invalid audio device')
  }
  for (const source of result.midi) {
    if (typeof source.id !== 'string' || typeof source.name !== 'string') throw new Error('Invalid MIDI input')
  }
  return result
}

// The returned completion owns the child through file finalization. Callers must
// await it even when closing the view; stop is idempotent and does not kill WAV writes.
export function record(options) { return inputSession({ ...options, command: 'record' }) }
export function monitorInput(options) { return inputSession({ ...options, command: 'monitor' }) }

function inputSession({ command, input, midi = 'all', directory, monitorOutput, onEvent = () => {}, executable = nativePath }) {
  if (typeof input !== 'string' || !input) throw new Error('Choose an audio input UID')
  if (command === 'record' && (typeof directory !== 'string' || !directory)) throw new Error('Choose a recording directory')
  if (command === 'monitor' && (typeof monitorOutput !== 'string' || !monitorOutput)) throw new Error('Choose a monitoring output UID')
  const args = [command, '--input', input]
  if (command === 'record') args.push('--midi', midi, '--directory', directory)
  if (monitorOutput != null) args.push('--monitor-output', monitorOutput)
  const child = spawn(executable, args,
    { stdio: ['pipe', 'pipe', 'pipe'] })
  let failure = null, stopped = false, detail = '', final = null
  const stop = () => {
    if (stopped) return
    stopped = true
    if (!child.stdin.destroyed) child.stdin.end('stop\n')
  }
  const fail = error => { failure ??= error; stop() }
  child.stdin.on('error', error => {
    // A child can finish and close stdin before its close event arrives.
    if (error.code !== 'EPIPE') fail(error)
  })
  child.stderr.setEncoding('utf8').on('data', text => { detail += text })
  const lines = createInterface({ input: child.stdout, crlfDelay: Infinity })
  lines.on('line', line => {
    try {
      const event = JSON.parse(line)
      if (!['recording', 'monitoring', 'audio', 'midi', 'stopped', 'error'].includes(event.kind)) throw new Error('Unknown capture event')
      if (event.kind === 'monitoring') {
        const info = event.monitoring
        if (!monitorOutput || info?.state !== 'active' || info.input?.id !== input || info.output?.id !== monitorOutput
          || !Number.isFinite(info.sampleRate) || info.sampleRate <= 0 || !Number.isSafeInteger(info.channels) || info.channels <= 0
          || info.latency?.kind !== 'device-reported' || ![info.latency.inputSeconds, info.latency.outputSeconds].every(value => Number.isFinite(value) && value >= 0)) throw new Error('Invalid selected input monitoring acknowledgement')
      }
      if (event.kind === 'error') failure ??= new Error(event.message)
      if (event.kind === 'stopped') final = event.session
      onEvent(event)
    } catch (error) { fail(error) }
  })
  const completion = new Promise((resolve, reject) => {
    child.once('error', error => { failure ??= error })
    child.once('close', async (code, signal) => {
      lines.close()
      try {
        if (failure) throw failure
        if (code !== 0 || !final || final.state !== (command === 'record' ? 'recorded' : 'monitored')) throw new Error(final?.failure || detail || `Input session ended: ${code ?? signal}`)
        if (command === 'monitor') { resolve(final); return }
        const timeline = await readCapture(directory)
        if (timeline.manifest.state !== 'recorded') throw new Error(timeline.manifest.failure || 'Recording failed')
        resolve(timeline)
      } catch (error) { reject(error) }
    })
  })
  return { stop, completion }
}
