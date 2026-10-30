import { mkdtemp, writeFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { midiClipPlaybackPlan, midiClipEventNanoseconds, validateMidiClipDestination } from './midi-clip-playback.mjs'
import { openPlayback, midiDestinations, midiClipTransportPath } from './playback.mjs'

function initialTempoValue(value) {
  if (value !== undefined && (!Number.isInteger(value) || value < 1 || value > 0xffffffff)) throw new Error('Initial tempo must be a positive UInt32 in 10ns per quarter note')
  return value
}

// One admitted immutable plan owns its files and native child until close.
// Preparation never blocks the editor's stop/route/close decisions.
export class MidiClipPlayer {
  constructor({ destination, initialTempo, notify = () => {}, open = openPlayback, temporaryRoot = tmpdir() } = {}) {
    if (destination !== undefined) validateMidiClipDestination(destination)
    this.destination = destination; this.notify = notify; this.open = open; this.temporaryRoot = temporaryRoot
    this.initialTempo = initialTempoValue(initialTempo)
    this.active = null; this.owners = new Set(); this.state = { kind: 'stopped' }; this.closed = false
  }
  setInitialTempo(value) {
    if (this.closed) throw new Error('Clip player is closed')
    initialTempoValue(value); this.stop(); this.initialTempo = value
  }
  update(state) { this.state = state; this.notify(state) }
  setOutput(destination) {
    if (this.closed) throw new Error('Clip player is closed')
    validateMidiClipDestination(destination)
    this.stop(); this.destination = destination
  }
  play(document) {
    if (this.closed) throw new Error('Clip player is closed')
    if (this.destination === undefined) throw new Error('Choose a native MIDI2 output with o or :midi-output ID')
    const plan = midiClipPlaybackPlan(document, { destination: this.destination, initialTempo: this.initialTempo })
    return this.admit(plan)
  }
  admit(plan) {
    const previous = this.active; this.stop()
    const owner = { plan, cancelled: false, handle: null, admission: new AbortController() }
    this.active = owner; this.owners.add(owner); this.update({ kind: 'preparing', source: plan.source })
    owner.completion = (async () => {
      let directory
      try {
        await previous?.completion
        owner.admission.signal.throwIfAborted()
        directory = await mkdtemp(join(this.temporaryRoot, 'masc-midi-clip-'))
        owner.admission.signal.throwIfAborted()
        const path = join(directory, 'plan.json')
        await writeFile(path, JSON.stringify(plan), { flag: 'wx', mode: 0o600, signal: owner.admission.signal })
        owner.admission.signal.throwIfAborted()
        owner.handle = this.open({ path, format: 'midi-clip', midiOutput: plan.destination, midiClipPlan: plan,
          onEvent: event => {
            if (['ready', 'playing', 'paused', 'stopped'].includes(event.kind)) owner.lastEvent = event
            if (this.active !== owner || owner.cancelled) return
            this.update({ kind: event.kind === 'ready' ? 'starting' : event.kind, source: plan.source, event })
          } })
        if (this.active === owner && !owner.cancelled) this.update({ kind: 'starting', source: plan.source })
        await owner.handle.completion
      } catch (error) {
        if (this.active === owner && !owner.cancelled) this.update({ kind: 'failed', error, source: plan.source })
      } finally {
        try { if (directory) await rm(directory, { recursive: true, force: true }) }
        catch (error) { owner.cleanupFailure = error; if (this.active === owner) this.update({ kind: 'failed', error, source: plan.source }) }
        if (this.active === owner) {
          this.active = null
          if (!owner.cleanupFailure && (owner.cancelled || this.state.kind !== 'failed')) this.update({ kind: 'stopped', source: plan.source, event: owner.lastEvent })
        }
        this.owners.delete(owner)
      }
    })()
    return owner
  }
  stop() {
    const owner = this.active
    if (!owner || owner.cancelled) return
    owner.cancelled = true
    if (owner.handle) owner.handle.stop()
    else owner.admission.abort()
    this.update({ kind: 'stopping', source: owner.plan.source })
  }
  toggle(document) {
    switch (this.state.kind) {
      case 'playing': this.active.handle.pause(); break
      case 'paused': this.active.handle.resume(); break
      case 'preparing': case 'starting': case 'stopping': this.stop(); break
      default: this.play(document)
    }
  }
  restart(document) {
    if (this.closed) throw new Error('Clip player is closed')
    return this.active && !this.active.cancelled ? this.admit(this.active.plan) : this.play(document)
  }
  pause() { if (this.state.kind !== 'playing') throw new Error('Clip is not playing'); this.active.handle.pause() }
  resume() { if (this.state.kind !== 'paused') throw new Error('Clip is not paused'); this.active.handle.resume() }
  status() {
    if (['playing', 'paused'].includes(this.state.kind)) this.active?.handle.status()
  }
  seekEvent(id) {
    if (!['playing', 'paused'].includes(this.state.kind) || !this.active) throw new Error('Play the Clip before seeking an event')
    this.active.handle.seekNanoseconds(midiClipEventNanoseconds(this.active.plan, id))
  }
  async settle() {
    this.stop()
    await Promise.all([...this.owners].map(owner => owner.completion))
  }
  async close() { this.closed = true; await this.settle() }
}

export function midiClipOutputs({ signal, executable = midiClipTransportPath } = {}) {
  return midiDestinations({ signal, executable, protocol: 2 })
}
