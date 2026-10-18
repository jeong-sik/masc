import { parentPort } from 'node:worker_threads'
import { writeFileSync } from 'node:fs'
import { sourceMidiTimeline } from './midi-source-playback.mjs'
import { projectMidiTimeline } from './sequencer-midi.mjs'
parentPort.on('message', async job => {
  try {
    const cancelled = () => Atomics.load(new Int32Array(job.cancel), 0) !== 0
    let result
    if (job.options.format === 'midi') {
      const timeline = job.project.kind === 'midi-source' ? sourceMidiTimeline(job.project, job.options) : projectMidiTimeline(job.project, job.options)
      if (cancelled()) throw new Error('MIDI preparation cancelled')
      writeFileSync(job.path, JSON.stringify(timeline), { flag: 'wx', mode: 0o600 })
      result = { path: job.path, duration: timeline.duration, clippedSamples: 0, format: 'midi', ...(timeline.bindings ? { midiOutput: timeline.bindings[0].destination, midiBindings: timeline.bindings } : {}) }
    } else {
      if (job.options.format !== undefined && job.options.format !== 'wav') throw new Error('Unknown playback format')
      const { renderProject } = await import('./sequencer-audio.mjs')
      result = renderProject(job.project, job.path, { ...job.options, cancelled })
    }
    parentPort.postMessage({ id: job.id, ok: true, result })
  } catch (error) { parentPort.postMessage({ id: job.id, ok: false, error: error.message }) }
})
