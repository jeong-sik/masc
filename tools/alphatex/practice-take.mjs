import { mkdir, open } from 'node:fs/promises'
import { createReadStream } from 'node:fs'
import { createHash } from 'node:crypto'
import { join, resolve } from 'node:path'
import { isDeepStrictEqual } from 'node:util'
import { validateProject } from './sequencer-project.mjs'
import { unpackMidi } from './session-data.mjs'
import { nominalMidiFrame, validateRenderClock } from './render-midi-clock.mjs'

async function jsonFile(path, value) {
  const file = await open(path, 'wx', 0o600)
  try { await file.writeFile(JSON.stringify(value, null, 2) + '\n'); await file.sync() }
  finally { await file.close() }
}
async function digest(path) {
  const hash = createHash('sha256')
  for await (const bytes of createReadStream(path)) hash.update(bytes)
  return hash.digest('hex')
}

// An owned fresh directory is a recoverable take even before finalization.
// Only the final receipt certifies clean input/audio closure. Preset bytes stay
// in its private context; diagnostic summaries never expose that context.
export async function openPracticeTake({ path, project, track, sound, backing }) {
  project = structuredClone(validateProject(project)); backing = structuredClone(backing)
  if (typeof path !== 'string' || !path || sound?.kind !== 'vst' || !isDeepStrictEqual(project.sound, sound)
      || backing?.kind !== 'phrase-backing' || backing.track !== track
      || !project.tracks.some(value => value.id === track && value.channel === backing.channel)) throw new Error('Invalid practice recording context')
  path = resolve(path)
  await mkdir(path, { mode: 0o700 }) // no recursive creation or reuse of an existing take
  await jsonFile(join(path, 'context.json'), { schemaVersion: 1, kind: 'practice-take-context', project, track, backing })
  const eventsPath = join(path, 'events.jsonl'), events = await open(eventsPath, 'wx', 0o600)
  let armed = null, count = 0n, final = null, finished = false
  const diagnostics = () => ({ kind: 'practice-take', path, packets: String(count), armed: armed !== null,
    status: final?.status ?? (finished ? 'failed' : armed ? 'recording' : 'opening') })
  return {
    diagnostics,
    async arm(input, renderClock) {
      if (armed || finished) throw new Error('Practice take is already armed or closed')
      validateRenderClock(renderClock)
      if (input?.kind !== 'midi-input' || input.schemaVersion !== 1 || input.protocol !== 2
          || typeof input.source?.id !== 'string') throw new Error('Invalid practice input clock acknowledgement')
      // A zero delta still verifies that the two timebases describe one clock.
      nominalMidiFrame(renderClock.anchor.hostTime, input.clock, renderClock)
      const value = { schemaVersion: 1, kind: 'practice-take-arm', input: structuredClone(input), renderClock: structuredClone(renderClock) }
      await jsonFile(join(path, 'armed.json'), value)
      armed = value
    },
    async append(packet) {
      if (!armed || finished) throw new Error('Practice take is not recording')
      unpackMidi(packet)
      if (packet.kind !== 'midi' || packet.source !== armed.input.source.id || packet.ordinal !== String(count)) throw new Error('Discontinuous practice MIDI packet')
      const row = { packet: structuredClone(packet), nominalFrame: nominalMidiFrame(packet.hostTime, armed.input.clock, armed.renderClock) }
      // Persist the complete original before audition projection and native ACK.
      // Backpressure follows storage completion; no raw packet queue is added.
      await events.writeFile(JSON.stringify(row) + '\n'); await events.sync()
      count++
    },
    async finish({ failure, inputFinal, monitorFinal }) {
      if (finished) throw new Error('Practice take is already closed')
      finished = true
      let error = failure === undefined ? undefined : failure instanceof Error ? failure : new Error('Practice recording failed', { cause: failure })
      try { await events.sync() } catch (cause) { error ??= cause }
      try { await events.close() } catch (cause) { error ??= cause }
      if (!error && armed && (inputFinal?.source !== armed.input.source.id || inputFinal?.success !== true || inputFinal.admittedPackets !== String(count)
          || inputFinal.acknowledgedPackets !== String(count) || inputFinal.discardedPackets !== '0'
          || !isDeepStrictEqual(monitorFinal?.pcm?.clock, armed.renderClock) || monitorFinal?.pcm?.final?.success !== true || !monitorFinal.pcm.nativeClosed || !monitorFinal.pcm.settled
          || (monitorFinal.worker && (!monitorFinal.worker.closed || !monitorFinal.worker.terminalReceived)))) {
        error = new Error('Practice recording did not confirm input/audio retirement')
      }
      const value = { schemaVersion: 1, kind: 'practice-take', status: error ? 'failed' : armed ? 'complete' : 'cancelled',
        packets: String(count), error: error?.message ?? null, inputFinal: inputFinal ?? null, monitorFinal: monitorFinal ?? null,
        files: { context: { file: 'context.json', sha256: await digest(join(path, 'context.json')) },
          events: { file: 'events.jsonl', sha256: await digest(eventsPath) },
          ...(armed ? { arm: { file: 'armed.json', sha256: await digest(join(path, 'armed.json')) } } : {}) } }
      await jsonFile(join(path, 'take.json'), value)
      final = value
      if (error) throw error
      return structuredClone(final)
    },
  }
}
