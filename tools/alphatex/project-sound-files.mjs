import { writeFile, unlink } from 'node:fs/promises'
import { nativeJob } from './vst.mjs'
import { validateSound, validateVstSelection } from './project-sound.mjs'

export function captureVstSound(selection, { run = nativeJob } = {}) {
  const chosen = validateVstSelection(selection), job = run({ operation: 'snapshot', ...chosen })
  return { cancel: () => job.cancel(), promise: job.promise.then(result => validateSound({ kind: 'vst', selection: chosen,
    preset: result.preset, instrument: { identifier: result.instrument?.identifier, version: result.instrument?.version } })) }
}

export function renderBoundVst(sound, request, { run = nativeJob } = {}) {
  validateSound(sound)
  if (sound.kind !== 'vst') throw new Error('Choose a bound VST sound')
  let cancelled = false, child = null, created = false
  const path = request.output_path + '.vstpreset'
  const check = () => { if (cancelled) { const error = new Error('VST sound preparation cancelled'); error.code = 'ABORT_ERR'; throw error } }
  const promise = (async () => {
    try {
      await writeFile(path, Buffer.from(sound.preset.data, 'base64'), { flag: 'wx', mode: 0o400 }); created = true
      check()
      child = run({ ...request, ...validateVstSelection(sound.selection), preset_path: path, expected_instrument: sound.instrument, operation: 'render' })
      const result = await child.promise
      check()
      if (result.preset_sha256 !== sound.preset.sha256) throw new Error('Rendered VST preset does not match the project sound')
      return result
    } finally { if (created) await unlink(path) }
  })()
  return { promise, cancel() { cancelled = true; child?.cancel() } }
}
