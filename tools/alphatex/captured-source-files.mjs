import { isDeepStrictEqual } from 'node:util'
import { lstat } from 'node:fs/promises'
import { createReadStream } from 'node:fs'
import { createHash } from 'node:crypto'
import { join } from 'node:path'
import { validateCapturedSource, validateCapturedSourceParts } from './captured-source.mjs'
import { readCaptureFiles } from './session-data.mjs'

export function capturePaths(root, asset) {
  return Object.fromEntries(Object.entries(asset.parts).map(([role, part]) => [role, join(root, part.file)]))
}
export function captureMatches(asset, timeline) {
  if (!isDeepStrictEqual(asset.manifest, timeline.manifest)
      || !isDeepStrictEqual(asset.midiTime, timeline.midiTime)
      || (timeline.audio[0]?.hostTime ?? null) !== asset.manifest.clock.firstAudioHostTime
      || [...timeline.midi.values()].some(track => !asset.manifest.midiSources.some(source => source.id === track.source))) {
    throw new Error('Captured source manifest or clock provenance disagrees with its data')
  }
}
async function readVerifiedCapture(root, asset, { signal } = {}) {
  // Validate identities before constructing paths, including during legacy load.
  validateCapturedSourceParts(asset)
  if (!(await lstat(join(root, 'assets'))).isDirectory()) throw new Error('Project assets must be a directory, not a symlink')
  const files = capturePaths(root, asset)
  for (const [role, file] of Object.entries(files)) {
    if (!(await lstat(file)).isFile()) throw new Error(`Captured source content changed: ${asset.name}`)
    const hash = createHash('sha256')
    for await (const bytes of createReadStream(file, { signal })) hash.update(bytes)
    if (hash.digest('hex') !== asset.parts[role].sha256) throw new Error(`Captured source content changed: ${asset.name}`)
  }
  const timeline = await readCaptureFiles(files, { signal })
  signal?.throwIfAborted()
  return { files, timeline }
}
export async function inspectCaptureAsset(root, asset, options = {}) {
  validateCapturedSource(asset)
  const { files, timeline } = await readVerifiedCapture(root, asset, options)
  captureMatches(asset, timeline)
  return files
}
export async function restoreArrangementCaptureTimes(project, root, options = {}) {
  // Only the older schema-1 omission is upgraded. Present but invalid bounds
  // must still fail strict validation rather than silently being replaced.
  if (project?.schemaVersion !== 1 || project.kind !== 'arrangement' || !Array.isArray(project.assets)) return project
  let restored = project
  for (const [index, asset] of project.assets.entries()) {
    if (asset?.kind !== 'capture' || Object.hasOwn(asset, 'midiTime')) continue
    const { timeline } = await readVerifiedCapture(root, asset, options)
    const upgraded = { ...asset, midiTime: structuredClone(timeline.midiTime) }
    validateCapturedSource(upgraded)
    captureMatches(upgraded, timeline)
    if (restored === project) restored = { ...project, assets: [...project.assets] }
    restored.assets[index] = upgraded
  }
  return restored
}
