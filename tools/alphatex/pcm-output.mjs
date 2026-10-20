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
  let nativeError = null, receiptError = null, settled = false
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
    if (closed) return
    try {
      const event = JSON.parse(line)
      if (final) throw new Error('PCM output replied after finalization')
      // Failure cancels production, but native closure and its final counters
      // remain owned. In particular, error followed by stopped is not silence.
      if (event?.kind === 'error' && typeof event.message === 'string') {
        nativeError ??= { kind: 'error', message: event.message }
        fail(new Error(event.message)); return
      }
      if (failure && event?.kind !== 'stopped') return
      switch (event?.kind) {
        case 'ready':
          if (info || event.schemaVersion !== 2 || typeof event.device?.id !== 'string' || !event.device.id
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
          if (!info || typeof event.success !== 'boolean' || !['none', 'underrun', 'render-format'].includes(event.fault)) throw new Error('Invalid PCM output final receipt')
          const admitted = counter(event.admittedFrames), rendered = counter(event.renderedFrames), discarded = counter(event.discardedFrames)
          const missing = counter(event.underrunFrames), faultFrames = counter(event.faultFrames)
          const completed = counter(event.demand?.completedBlocks), last = counter(event.demand?.lastResponseNanoseconds)
          const max = counter(event.demand?.maxResponseNanoseconds)
          const playingBlocks = counter(event.demand?.playingBlocks), playingMax = counter(event.demand?.maxPlayingResponseNanoseconds)
          if (event.demand.pendingNanoseconds !== null) counter(event.demand.pendingNanoseconds)
          if (admitted > sent || rendered + discarded !== admitted || completed * BigInt(info.blockFrames) !== admitted
              || completed >= nextID || max < last || (completed === 0n && (last !== 0n || max !== 0n))
              || playingBlocks > completed || playingMax > max || (playingBlocks === 0n && playingMax !== 0n)
              || (event.fault === 'none' && (missing !== 0n || faultFrames !== 0n))
              || (event.fault === 'underrun' && (missing === 0n || faultFrames < missing))
              || (event.fault === 'render-format' && (missing !== 0n || faultFrames === 0n))
              || (event.success && (!stopping || event.fault !== 'none' || admitted !== sent))) throw new Error('PCM output did not finalize admitted audio')
          final = structuredClone(event)
          if (!event.success) fail(new Error(nativeError?.message ?? 'PCM output failed'))
          break
        }
        default: throw new Error('Invalid PCM output event')
      }
      onEvent(event)
    } catch (error) { receiptError = error.message; fail(error) }
  })
  for (const stream of [lines, child.stdout, child.stderr]) stream.once('error', fail)
  child.once('error', fail)
  child.stdin.on('error', error => { if (error.code !== 'EPIPE' || !stopping) fail(error) })
  child.stderr.setEncoding('utf8').on('data', text => { detail = (detail + text).slice(-64 * 1024) })
  child.once('close', (code, exitSignal) => {
    closed = true; lines.close()
    if (!failure && (code !== 0 || !final)) fail(new Error(detail || `PCM output closed without finalization: ${code ?? exitSignal}`))
    if (failure) rejectClose(failure)
    else resolveClose(final)
  })
  const completion = (async () => {
    try {
      let result
      try { result = await nativeClose }
      finally { await job }
      if (failure) throw failure
      return result
    } finally { settled = true; signal?.removeEventListener('abort', abort) }
  })()
  completion.catch(() => {})
  if (signal?.aborted) abort()
  return { ready, completion,
    diagnostics() {
      return structuredClone({ schemaVersion: 1, requestedOutput: output ?? null, device: info?.device ?? null,
        format: info ? { sampleRate: info.sampleRate, blockFrames: info.blockFrames, prefillFrames: info.prefillFrames } : null,
        playing, nativeClosed: closed, settled, requestedBlocks: String(nextID - 1n), sentFrames: String(sent),
        nativeError, final, receiptError, failure: failure?.message ?? null })
    },
    stop() {
      if (stopping || closed || failure) return
      stopping = true; producer.abort(new Error('PCM output stopped'))
      try { child.stdin.end('{"kind":"stop"}\n') } catch (error) { fail(error) }
    },
    cancel(reason = new Error('PCM output cancelled')) { fail(reason) },
  }
}
