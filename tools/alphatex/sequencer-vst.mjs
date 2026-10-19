import { projectMidi } from './sequencer-files.mjs'
import { sequenceEvents } from './sequencer-project.mjs'
import { midiSourcePattern, exportMidiSourcePattern } from './midi-source.mjs'
import { nativeJob, retainRender } from './vst.mjs'
import { renderBoundVst } from './project-sound-files.mjs'
import { validateVstSelection } from './project-sound.mjs'

export function projectVstMidi(project, options = {}) {
  if (project?.kind === 'midi-source') {
    if (options.loop) throw new Error('Source clip looping requires expression-state reconstruction')
    const performance = midiSourcePattern(project, options)
    const ports = new Set(performance.events.filter(event => event.kind !== 'meta').map(event => event.port))
    if (ports.size > 1) throw new Error('Independent source MIDI ports require separate instrument instances; use explicit MIDI port outputs')
    return { bytes: exportMidiSourcePattern(project, options), duration: performance.seconds }
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
    const midi = await preparation.promise
    check()
    const request = { operation: 'render', ...validateVstSelection(selection), midi_path: midi.path, output_path: outputPath,
      ...(loop ? { tail_seconds: 0 } : {}) }
    native = sound ? renderBoundVst(sound, request, { run }) : run(request)
    const result = await native.promise
    check()
    const retained = await retainRender(stateDirectory, result, midi.path)
    if (cancelled) { await retained.discard(); check() }
    return { path: retained.result.output_path, duration: result.duration_ms / 1000,
      phraseDuration: midi.duration, clippedSamples: 0, format: 'wav', selection, vst: retained.result }
  })()
  return { promise, cancel() {
    cancelled = true
    Atomics.store(preparation.cancel, 0, 1)
    native?.cancel()
  } }
}
