import { phraseDocument, importPhraseDocument } from './phrase-arrangement.mjs'
import { parentPort } from 'node:worker_threads'
import { dirname } from 'node:path'
import { importArrangementWave, importArrangementMidi, importArrangementCapture, importCaptureMidi, importArrangementPractice, restorePracticeBacking, inspectPracticePasses, importPracticeMidi, prepareArrangementCapture, readUmpCapture, importUmpVariant, exportUmpCapture, saveArrangement, materializeArrangementAssets } from './arrangement-files.mjs'
import { prepareArrangementWave, prepareArrangementMidi, prepareArrangementMixed, prepareArrangementAudio, prepareArrangementCaptureRegions, prepareArrangementInstrument } from './arrangement-playback.mjs'
import { attachRecordedTake } from './arrangement-recording.mjs'
import { analyzeCalibration } from './audio-calibration.mjs'
import { inspectCalibration } from './calibration-files.mjs'

import { preparePractice } from './arrangement-practice.mjs'
import { prepareSoundSources, finishSoundPlan } from './arrangement-sound.mjs'
import { exportArrangementWave } from './arrangement-export.mjs'

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
      case 'prepare-sound-sources': result = await prepareSoundSources(job.project, { ...job, signal }); break
      case 'prepare-sound-plan': result = await finishSoundPlan(job.project, { ...job, signal }); break
      case 'prepare-phrase': result = phraseDocument(job.project, job.asset); break
      case 'export-wave': result = await exportArrangementWave(job.project, job.path, {
        sourceRoot: job.sourceRoot, directory: job.directory, signal,
        onProgress(progress) {
          if (!signal.aborted && active.get(job.id) === controller) parentPort.postMessage({ kind: 'progress', id: job.id, progress })
        } }); break
      case 'import-phrase': result = importPhraseDocument(job.project, job.document); break
      case 'inspect-calibration': result = await inspectCalibration(job.path, { signal }); break
      case 'analyze-calibration': result = await analyzeCalibration({ ...job, signal }); break
      case 'attach-recording': {
        const imported = await importArrangementCapture(job.project, job.path, { projectPath: job.projectPath, signal })
        result = attachRecordedTake(job.project, imported, job.epoch, job.correction); break
      }
      case 'prepare-capture': result = await prepareArrangementCaptureRegions(job.project, { sourceRoot: job.sourceRoot, directory: job.directory, signal, midiOutput: job.midiOutput, sourceBindings: job.sourceBindings, portBindings: job.portBindings }); break
      case 'prepare-take': result = await prepareArrangementCapture(job.project, job.asset, { sourceRoot: job.sourceRoot, directory: job.directory, signal }); break
      case 'prepare-ump': result = await readUmpCapture(job.project, job.asset, { sourceRoot: job.sourceRoot, directory: job.directory, signal }); break
      case 'import-ump': result = await importUmpVariant(job.project, job.asset, job.ump, { sourceRoot: job.sourceRoot, directory: job.directory, signal }); break
      case 'export-ump': result = await exportUmpCapture(job.project, job.asset, job.path, { sourceRoot: job.sourceRoot, directory: job.directory, signal }); break
      case 'import-take': result = await importArrangementCapture(job.project, job.path, { projectPath: job.projectPath, signal }); break
      case 'import-practice': result = await importArrangementPractice(job.project, job.path, { projectPath: job.projectPath, signal }); break
      case 'capture-midi': case 'capture-midi-region':
        if (job.kind === 'capture-midi-region' && !job.cut) throw new Error('Select a captured MIDI region cut')
        result = await importCaptureMidi(job.project, job.asset, { sourceRoot: job.sourceRoot, directory: job.directory, signal,
          ...(job.kind === 'capture-midi-region' ? { cut: job.cut, nativeExecutable: job.nativeExecutable } : {}) }); break
      case 'practice-backing': result = await restorePracticeBacking(job.project, job.asset, { sourceRoot: job.sourceRoot, directory: job.directory, signal }); break
      case 'practice-midi': case 'practice-midi-region':
        if (job.kind === 'practice-midi-region' && !job.cut) throw new Error('Select a practice MIDI region cut')
        result = await importPracticeMidi(job.project, job.asset, { sourceRoot: job.sourceRoot, directory: job.directory, signal,
          ...(job.kind === 'practice-midi-region' ? { cut: job.cut, nativeExecutable: job.nativeExecutable } : {}) }); break
      case 'practice-passes': case 'practice-pass': result = await inspectPracticePasses(job.project, job.asset, job.pass, { sourceRoot: job.sourceRoot, directory: job.directory, signal }); break
      case 'prepare-mixed': result = await prepareArrangementMixed(job.project, { sourceRoot: job.sourceRoot, directory: job.directory, signal, midiOutput: job.midiOutput, portBindings: job.portBindings }); break
      case 'prepare-midi': result = await prepareArrangementMidi(job.project, { directory: job.directory, signal, midiOutput: job.midiOutput, portBindings: job.portBindings }); break
      case 'prepare-vst': result = await prepareArrangementInstrument(job.project, { sourceRoot: job.sourceRoot, directory: job.directory, signal,
        onProgress(progress) {
          if (!signal.aborted && active.get(job.id) === controller) parentPort.postMessage({ kind: 'progress', id: job.id, progress })
        } }); break
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
    switch (job.kind) {
      case 'prepare-capture': case 'prepare-mixed': case 'prepare-midi': case 'prepare-audio': case 'prepare-wave': case 'prepare-vst':
        result = await preparePractice(job.project, result, { signal }); break
    }
    parentPort.postMessage({ id: job.id, ok: true, result })
  } catch (error) { parentPort.postMessage({ id: job.id, ok: false, cancelled: signal.aborted, error: error.message }) }
  finally { active.delete(job.id) }
})
