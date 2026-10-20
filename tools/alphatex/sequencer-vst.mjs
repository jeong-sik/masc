import { projectMidi } from './sequencer-files.mjs'
import { sequenceEvents } from './sequencer-project.mjs'
import { midiSourcePattern, exportMidiSourcePattern } from './midi-source.mjs'
import { nativeJob, retainRender } from './vst.mjs'
import { renderBoundVst } from './project-sound-files.mjs'
import { validateVstSelection } from './project-sound.mjs'
import { sourceLoopWindow } from './midi-source-playback.mjs'
import { sourceAudioFrames } from './source-audio-clock.mjs'
import { readWaveMetadata } from './wave-file.mjs'
import { readFile } from 'node:fs/promises'
import { createReadStream } from 'node:fs'
import { createHash } from 'node:crypto'

export function projectVstMidi(project, options = {}) {
  if (project?.kind === 'midi-source') {
    const performance = midiSourcePattern(project, options)
    const ports = new Set(performance.events.filter(event => event.kind !== 'meta').map(event => event.port))
    if (ports.size > 1) throw new Error('Independent source MIDI ports require separate instrument instances; use explicit MIDI port outputs')
    // Render the complete original performance. A PCM window retains pre-cut
    // instrument/pedal history instead of fabricating a new attack at entry.
    const bytes = exportMidiSourcePattern(project, options)
    return { bytes, duration: performance.seconds,
      ...(options.loop ? { sourceWindow: sourceLoopWindow(performance, options.sourceLoop),
        midiSha256: createHash('sha256').update(bytes).digest('hex') } : {}) }
  }
  const { seconds } = sequenceEvents(project, options)
  return { bytes: projectMidi(project, options), duration: seconds }
}

// One owned preparation, native child and retention operation. A failed VST
// never starts another instrument or a fallback player.
export function renderVstPhrase({ preparation, selection, sound, outputPath, stateDirectory, loop = false, run = nativeJob }) {
  let cancelled = false, native = null
  const check = () => {
    if (cancelled) { const error = new Error('VST phrase cancelled'); error.code = 'ABORT_ERR'; throw error }
  }
  const promise = (async () => {
    const prepared = await preparation.promise
    const midi = { ...prepared, ...(prepared.sourceWindow ? { sourceWindow: structuredClone(prepared.sourceWindow) } : {}) }
    check()
    const request = { operation: 'render', ...validateVstSelection(selection), midi_path: midi.path, output_path: outputPath,
      ...(loop ? { tail_seconds: 0 } : {}) }
    native = sound ? renderBoundVst(sound, request, { run }) : run(request)
    const result = await native.promise
    check()
    const retained = await retainRender(stateDirectory, result, midi.path)
    try {
      check()
      let window = {}
      if (midi.sourceWindow) {
        if (!Number.isSafeInteger(result.frames) || result.frames <= 0) throw new Error('Invalid source render frame count')
        const metadata = await readWaveMetadata(retained.result.output_path,
          { frames: result.frames, sampleRate: result.sample_rate, channels: 2 })
        const hash = createHash('sha256')
        for await (const chunk of createReadStream(retained.result.output_path)) { check(); hash.update(chunk) }
        if (hash.digest('hex') !== result.wav_sha256) throw new Error('Source render WAV hash does not match its receipt')
        const midiHash = createHash('sha256').update(await readFile(retained.result.midi_path)).digest('hex')
        if (midiHash !== midi.midiSha256 || midiHash !== result.midi_sha256) throw new Error('Source render MIDI differs from the admitted performance')
        const frameRange = sourceAudioFrames(midi.sourceWindow.clock, metadata.sampleRate)
        if (frameRange.frameCount <= 0 || frameRange.offsetFrames + frameRange.frameCount > result.frames) {
          throw new Error('Selected source loop has no complete rendered PCM window')
        }
        window = { sourceWindow: midi.sourceWindow, frameRange,
          duration: frameRange.frameCount / metadata.sampleRate, phraseDuration: frameRange.frameCount / metadata.sampleRate }
      }
      check()
      return { path: retained.result.output_path, duration: result.duration_ms / 1000,
        phraseDuration: midi.duration, clippedSamples: 0, format: 'wav', selection, vst: retained.result, ...window }
    } catch (error) {
      await retained.discard(); throw error
    }
  })()
  return { promise, cancel() {
    cancelled = true
    Atomics.store(preparation.cancel, 0, 1)
    native?.cancel()
  } }
}
