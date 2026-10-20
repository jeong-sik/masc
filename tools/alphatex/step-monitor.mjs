import { unpackMidi } from './session-data.mjs'
import { validateSound } from './project-sound.mjs'
import { openVstStream } from './vst-stream.mjs'
import { openPcmOutput } from './pcm-output.mjs'
import { randomUUID } from 'node:crypto'

// Audition is a declared MIDI1 projection to one selected editor channel. The
// raw recorder owns precision/timestamps; this path plays the next device block.
export function monitorPacket(packet, channel, held = new Map()) {
  const next = new Map(held), messages = []
  for (const message of unpackMidi(packet)) {
    const type = message[0] >>> 4, status = message[1] >>> 4
    if (type === 0 || (type === 1 && message[1] >= 0xf8 && message[1] !== 0xff)) continue
    if (![2, 4].includes(type) || status < 8 || status > 14) throw new Error('Live VST monitoring cannot represent this MIDI message; use raw recording')
    const index = message[2]
    let bytes
    if (type === 2) {
      const length = [12, 13].includes(status) ? 2 : 3
      bytes = Array.from(message).slice(1, length + 1)
      if (bytes.slice(1).some(byte => byte > 127)) throw new Error('Invalid MIDI1 monitor data')
    } else {
      const value = (message[4] * 0x1000000 + message[5] * 0x10000 + message[6] * 0x100 + message[7]) >>> 0
      switch (status) {
        case 8: case 9:
          if (index > 127 || message[3] !== 0 || message[6] !== 0 || message[7] !== 0) throw new Error('Live VST notes cannot represent MIDI2 attributes')
          bytes = [message[1], index, status === 9 ? Math.max(1, value >>> 25) : value >>> 25]; break
        case 10: case 11:
          if (index > 127 || message[3] !== 0) throw new Error('Invalid MIDI2 monitor controller')
          bytes = [message[1], index, value >>> 25]; break
        case 12: continue // The captured project preset owns bank/program.
        case 13:
          if (index !== 0 || message[3] !== 0) throw new Error('Invalid MIDI2 channel pressure')
          bytes = [message[1], value >>> 25]; break
        case 14: {
          if (index !== 0 || message[3] !== 0) throw new Error('Invalid MIDI2 pitch bend')
          const bend = value >>> 18
          bytes = [message[1], bend & 127, bend >>> 7]; break
        }
      }
    }
    if (status === 12 || (status === 11 && [0, 32].includes(index))) continue
    const key = JSON.stringify([packet.source, message[0] & 15, message[1] & 15, index])
    if (message.isNoteOn()) {
      if ([...next.values()].includes(index)) throw new Error('Live VST notes overlap on the selected target channel')
      next.set(key, index)
    } else if (message.isNoteOff()) {
      if (!next.delete(key)) continue // An unrelated source release cannot cut a held target key.
    }
    bytes[0] = (bytes[0] & 0xf0) | channel
    messages.push({ frame: 0, bytes })
  }
  return { held: next, messages }
}

// One slot is sufficient: the MIDI input owner awaits send() before admitting
// its next packet. Audio demand consumes that slot without entering the UI queue.
export function openStepMonitor({ sound, output, channel, signal,
  openOutput = openPcmOutput, openSynth = openVstStream }) {
  validateSound(sound)
  if (sound.kind !== 'vst') throw new Error('Choose a VST instrument before monitored step input')
  sound = structuredClone(sound)
  if (!Number.isInteger(channel) || channel < 0 || channel > 15) throw new Error('Invalid monitor target channel')
  signal?.throwIfAborted()
  const cancellation = new AbortController()
  const id = randomUUID()
  const stopped = new Error('Step monitor stopped')
  let synth = null, pcm = null, slot = null, held = new Map(), stopping = false, failure = null
  let resolveReady, rejectReady
  const ready = new Promise((resolve, reject) => { resolveReady = resolve; rejectReady = reject })
  ready.catch(() => {})
  const fail = reason => {
    failure ??= reason instanceof Error ? reason : new Error('Step monitor failed', { cause: reason })
    cancellation.abort(failure); rejectReady(failure)
    slot?.reject(failure); slot = null
    pcm?.cancel(failure); synth?.cancel(failure)
  }
  const abort = () => fail(signal.reason)
  signal?.addEventListener('abort', abort, { once: true })
  let device
  try {
    pcm = openOutput({ output, signal: cancellation.signal,
      onEvent(event) { if (event.kind === 'playing' && !stopping) resolveReady(device) },
      async provideBlock({ frames, sampleRate, signal: producer }) {
        producer.throwIfAborted()
        if (!synth) {
          synth = openSynth(sound, { sampleRate, signal: cancellation.signal })
          synth.completion.catch(error => { if (error !== stopped) fail(error) })
        }
        await synth.ready
        producer.throwIfAborted()
        const admitted = slot; slot = null
        try {
          const block = await synth.render(frames, admitted?.messages ?? [])
          producer.throwIfAborted()
          admitted?.resolve()
          return block
        } catch (error) {
          if (stopping && !failure) admitted?.resolve()
          else admitted?.reject(error)
          throw error
        }
      } })
  } catch (error) {
    signal?.removeEventListener('abort', abort)
    throw error
  }
  pcm.ready.then(info => { device = info }, fail)
  const completion = (async () => {
    try { await pcm.completion }
    catch (error) { fail(error) }
    finally {
      stopping = true
      rejectReady(failure ?? new Error('Step monitor stopped before playback'))
      slot?.resolve(); slot = null; held.clear()
      if (synth) {
        if (!failure) synth.stop()
        try { await synth.completion } catch (error) { if (error !== stopped) fail(error) }
      }
      signal?.removeEventListener('abort', abort)
    }
    if (failure) throw failure
    return device
  })()
  completion.catch(() => {})
  if (signal?.aborted) abort()
  return { ready, completion,
    diagnostics() {
      return { schemaVersion: 1, kind: 'step-monitor', id, channel,
        sound: { name: sound.selection.name, identifier: sound.instrument.identifier,
          version: sound.instrument.version, presetSHA256: sound.preset.sha256 },
        pcm: pcm.diagnostics() }
    },
    prepare(packet) { return monitorPacket(packet, channel, held) },
    send(prepared) {
      if (failure) return Promise.reject(failure)
      if (stopping) return Promise.resolve() // Editor decisions already admitted still drain.
      if (slot) return Promise.reject(new Error('Consume the pending monitor packet first'))
      held = prepared.held
      if (!prepared.messages.length) return Promise.resolve()
      return new Promise((resolve, reject) => { slot = { messages: prepared.messages, resolve, reject } })
    },
    stop() {
      if (stopping) return
      stopping = true; slot?.resolve(); slot = null
      pcm.stop(); synth?.cancel(stopped)
    },
    cancel: fail,
  }
}
