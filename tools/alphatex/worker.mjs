import { parentPort } from 'node:worker_threads'
import { renderScore } from './engine.mjs'
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
      default: throw new Error('unknown score worker request')
    }
    parentPort.postMessage({ id: job.id, ok: true, result })
  } catch (error) {
    parentPort.postMessage({ id: job.id, ok: false, error: errorDetail(error) })
  }
})
