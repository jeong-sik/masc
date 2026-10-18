import { parentPort } from 'node:worker_threads'
import { renderProject } from './sequencer-audio.mjs'
parentPort.on('message', job => {
  try {
    const result = renderProject(job.project, job.path, { ...job.options,
      cancelled: () => Atomics.load(new Int32Array(job.cancel), 0) !== 0 })
    parentPort.postMessage({ id: job.id, ok: true, result })
  } catch (error) { parentPort.postMessage({ id: job.id, ok: false, error: error.message }) }
})
