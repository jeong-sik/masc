import { parentPort } from 'node:worker_threads'
import { importMidiSource } from './midi-source.mjs'
import { renderScore, midiForScore } from './engine.mjs'
import { writeFileSync } from 'node:fs'
import { exportWave } from './audio.mjs'
import { errorDetail } from './diagnostics.mjs'

parentPort.on('message', job => {
  try {
    let result
    switch (job.kind) {
      case 'render': result = renderScore(job.source, job.options); break
      case 'audio': result = exportWave(job.source, job.path, {
        ...job.options, cancelled: () => Atomics.load(new Int32Array(job.cancel), 0) !== 0,
      }); break
      case 'source': {
        const { score, midi } = midiForScore(job.source, { ...job.options, smf1Mode: true })
        result = importMidiSource(midi.toBinary(), { name: score.title || 'Score',
          notation: { kind: 'alphatex', source: job.source, ...(job.options?.tracks === undefined ? {} : { tracks: job.options.tracks }) } })
        break
      }
      case 'midi': {
        const { midi } = midiForScore(job.source, { ...job.options, smf1Mode: true })
        writeFileSync(job.path, Buffer.from(midi.toBinary()), { flag: 'wx', mode: 0o600 })
        result = { kind: 'midi', path: job.path }
        break
      }
      default: throw new Error('unknown score worker request')
    }
    parentPort.postMessage({ id: job.id, ok: true, result })
  } catch (error) {
    parentPort.postMessage({ id: job.id, ok: false, error: errorDetail(error) })
  }
})
