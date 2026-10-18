import { parentPort } from 'node:worker_threads'
import { dirname } from 'node:path'
import { importArrangementWave, importArrangementMidi, importArrangementCapture, prepareArrangementCapture, saveArrangement, materializeArrangementAssets } from './arrangement-files.mjs'
import { prepareArrangementWave, prepareArrangementMidi, prepareArrangementMixed, prepareArrangementAudio, prepareArrangementCaptureRegions } from './arrangement-playback.mjs'
import { attachRecordedTake } from './arrangement-recording.mjs'

const active = new Map()
parentPort.on('message', async job => {
  if (job.kind === 'cancel') {
    if (job.request !== undefined) active.get(job.request)?.abort()
    else for (const controller of active.values()) controller.abort()
    return
  }
  const controller = new AbortController(), signal = controller.signal
  active.set(job.id, controller)
  try {
    let result
    switch (job.kind) {
      case 'attach-recording': {
        const imported = await importArrangementCapture(job.project, job.path, { projectPath: job.projectPath, signal })
        result = attachRecordedTake(job.project, imported, job.epoch); break
      }
      case 'prepare-capture': result = await prepareArrangementCaptureRegions(job.project, { sourceRoot: job.sourceRoot, directory: job.directory, signal, midiOutput: job.midiOutput, sourceBindings: job.sourceBindings, portBindings: job.portBindings }); break
      case 'prepare-take': result = await prepareArrangementCapture(job.project, job.asset, { sourceRoot: job.sourceRoot, directory: job.directory, signal }); break
      case 'import-take': result = await importArrangementCapture(job.project, job.path, { projectPath: job.projectPath, signal }); break
      case 'prepare-mixed': result = await prepareArrangementMixed(job.project, { sourceRoot: job.sourceRoot, directory: job.directory, signal, midiOutput: job.midiOutput, portBindings: job.portBindings }); break
      case 'prepare-midi': result = await prepareArrangementMidi(job.project, { directory: job.directory, signal, midiOutput: job.midiOutput, portBindings: job.portBindings }); break
      case 'prepare-audio': result = await prepareArrangementAudio(job.project, { sourceRoot: job.sourceRoot, directory: job.directory, signal }); break
      case 'prepare-wave': result = await prepareArrangementWave(job.project, { sourceRoot: job.sourceRoot, directory: job.directory, signal }); break
      case 'import-wave': result = await importArrangementWave(job.project, job.path, { projectPath: job.projectPath, signal }); break
      case 'import-midi': result = await importArrangementMidi(job.project, job.path, { signal }); break
      case 'save': {
        if (job.retainedAssets?.length) {
          // Undo/redo may restore sources absent from the current document.
          // Materialize those sources before changing the editor's asset root.
          const retained = { ...job.project, clips: [], lanes: [], assets: job.retainedAssets }
          await materializeArrangementAssets(retained, job.sourceRoot, dirname(job.path), { signal })
        }
        result = await saveArrangement(job.path, job.project, job.revision, { sourceRoot: job.sourceRoot, signal }); break
      }
      default: throw new Error('Unknown arrangement IO request')
    }
    parentPort.postMessage({ id: job.id, ok: true, result })
  } catch (error) { parentPort.postMessage({ id: job.id, ok: false, cancelled: signal.aborted, error: error.message }) }
  finally { active.delete(job.id) }
})
