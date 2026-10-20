import { spawn } from 'node:child_process'
import { createInterface } from 'node:readline'
import { fileURLToPath } from 'node:url'

export const pcmOutputPath = fileURLToPath(new URL('./music-pcm-output', import.meta.url))
function counter(value) {
  if (typeof value !== 'string' || !/^(0|[1-9][0-9]*)$/.test(value) || BigInt(value) > 0xffffffffffffffffn) throw new Error('Invalid PCM frame counter')
  return BigInt(value)
}
// Device-clocked requests own one producer operation. Completion joins both
// native closure and that operation; stop aborts the producer before teardown.
export function openPcmOutput({ output, provideBlock, signal, onEvent = () => {},
  executable = pcmOutputPath, spawnProcess = spawn } = {}) {
  if ((output !== undefined && (typeof output !== 'string' || !output)) || typeof provideBlock !== 'function') throw new Error('Choose PCM output and a block producer')
  signal?.throwIfAborted()
  const child = spawnProcess(executable, output === undefined ? [] : ['--output', output], { stdio: ['pipe', 'pipe', 'pipe'] })
  const producer = new AbortController()
  let failure = null, info = null, playing = false, stopping = false, closed = false, final = null, job = null
  let nextID = 1n, sent = 0n, detail = ''
  let resolveReady, rejectReady, resolveClose, rejectClose
  const ready = new Promise((resolve, reject) => { resolveReady = resolve; rejectReady = reject })
  const nativeClose = new Promise((resolve, reject) => { resolveClose = resolve; rejectClose = reject })
  ready.catch(() => {}); nativeClose.catch(() => {})
  function fail(reason) {
    failure ??= reason instanceof Error ? reason : new Error('PCM output failed', { cause: reason })
    rejectReady(failure); producer.abort(failure)
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
      if (final) throw new Error('PCM output replied after finalization')
      switch (event?.kind) {
        case 'ready':
          if (info || event.schemaVersion !== 1 || typeof event.device?.id !== 'string' || !event.device.id
              || typeof event.device.name !== 'string' || (output !== undefined && event.device.id !== output)
              || !Number.isInteger(event.sampleRate) || event.sampleRate <= 0 || event.sampleRate > 0xffffffff
              || !Number.isInteger(event.blockFrames) || event.blockFrames <= 0 || event.blockFrames > 2 ** 24
              || event.prefillFrames !== event.blockFrames * 2) throw new Error('Invalid selected PCM output acknowledgement')
          info = structuredClone(event); resolveReady(structuredClone(info)); break
        case 'need': {
          if (!info || job || counter(event.id) !== nextID || event.frames !== info.blockFrames || counter(event.startFrame) !== sent) throw new Error('Unexpected PCM output demand')
          nextID++
          if (stopping) break
          const request = { id: event.id, startFrame: event.startFrame, frames: event.frames,
            sampleRate: info.sampleRate, signal: producer.signal }
          const owned = Promise.resolve().then(() => {
            producer.signal.throwIfAborted()
            return provideBlock(request)
          }).then(pcm => {
            if (stopping || failure || closed) return
            if (!Buffer.isBuffer(pcm) || pcm.length !== request.frames * 8) throw new Error('Producer returned incomplete stereo PCM')
            for (let i = 0; i < pcm.length; i += 4) if (!Number.isFinite(pcm.readFloatLE(i))) throw new Error('Producer returned nonfinite PCM')
            producer.signal.throwIfAborted()
            child.stdin.write(JSON.stringify({ kind: 'block', id: request.id, pcm: pcm.toString('base64') }) + '\n')
            sent += BigInt(request.frames)
          }).catch(error => { if (!stopping || failure) fail(error) }).finally(() => { if (job === owned) job = null })
          job = owned; break
        }
        case 'playing':
          if (!info || playing || sent < BigInt(info.prefillFrames)) throw new Error('Unexpected PCM playback acknowledgement')
          playing = true; break
        case 'stopped': {
          if (!info || !stopping || event.success !== true || counter(event.admittedFrames) !== sent
              || counter(event.underrunFrames) !== 0n
              || counter(event.renderedFrames) + counter(event.discardedFrames) !== sent) throw new Error('PCM output did not finalize admitted audio')
          final = structuredClone(event); break
        }
        default: throw new Error('Invalid PCM output event')
      }
      onEvent(event)
    } catch (error) { fail(error) }
  })
  for (const stream of [lines, child.stdout, child.stderr]) stream.once('error', fail)
  child.once('error', fail)
  child.stdin.on('error', error => { if (error.code !== 'EPIPE' || !stopping) fail(error) })
  child.stderr.setEncoding('utf8').on('data', text => { detail = (detail + text).slice(-64 * 1024) })
  child.once('close', (code, exitSignal) => {
    closed = true; signal?.removeEventListener('abort', abort); lines.close()
    if (!failure && (code !== 0 || !final)) fail(new Error(detail || `PCM output closed without finalization: ${code ?? exitSignal}`))
    if (failure) rejectClose(failure)
    else resolveClose(final)
  })
  const completion = (async () => {
    try { return await nativeClose }
    finally { await job }
  })()
  completion.catch(() => {})
  if (signal?.aborted) abort()
  return { ready, completion,
    stop() {
      if (stopping || closed || failure) return
      stopping = true; producer.abort(new Error('PCM output stopped'))
      try { child.stdin.end('{"kind":"stop"}\n') } catch (error) { fail(error) }
    },
    cancel(reason = new Error('PCM output cancelled')) { fail(reason) },
  }
}
