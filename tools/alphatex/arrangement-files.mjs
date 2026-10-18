import { readFile, open, mkdir, mkdtemp, lstat, link, rm, chmod } from 'node:fs/promises'
import { createReadStream, createWriteStream } from 'node:fs'
import { Transform } from 'node:stream'
import { pipeline } from 'node:stream/promises'
import { createHash } from 'node:crypto'
import { basename, dirname, join, resolve } from 'node:path'
import { importMidiSource } from './midi-source.mjs'
import { readWaveMetadata } from './wave-file.mjs'
import { arrangementID, editArrangement, validateArrangement } from './arrangement.mjs'
import { saveProject, loadProject } from './sequencer-files.mjs'

async function digestFile(path, { signal } = {}) {
  const hash = createHash('sha256')
  for await (const bytes of createReadStream(path, { signal })) hash.update(bytes)
  return hash.digest('hex')
}
function waveInfo(metadata) {
  const { frames, dataOffset, dataBytes, ...format } = metadata
  const count = Number(frames)
  if (!Number.isSafeInteger(count)) throw new Error('WAV source frame count is not representable')
  return { ...format, frames: count }
}
function equalMetadata(a, b) {
  return ['encoding','channels','sampleRate','bitsPerSample','validBits','blockAlign','frames'].every(key => a[key] === b[key])
}
async function directory(path) {
  await mkdir(path, { recursive: true, mode: 0o700 })
  if (!(await lstat(path)).isDirectory()) throw new Error('Project assets must be a directory, not a symlink')
}
async function inspectWaveAsset(root, asset, options = {}) {
  const folder = join(root, 'assets')
  if (!(await lstat(folder)).isDirectory()) throw new Error('Project assets must be a directory, not a symlink')
  const path = join(root, asset.file)
  if (!(await lstat(path)).isFile()) throw new Error('WAV source must be a regular project asset')
  const actualHash = await digestFile(path, options)
  if (actualHash !== asset.sha256) throw new Error(`WAV source content changed: ${asset.name}`)
  const metadata = waveInfo(await readWaveMetadata(path, {}, options))
  if (!equalMetadata(metadata, asset.metadata)) throw new Error(`WAV source metadata changed: ${asset.name}`)
  options.signal?.throwIfAborted()
  return path
}
async function copyWaveAsset(input, root, { signal } = {}) {
  signal?.throwIfAborted()
  const folder = join(root, 'assets')
  await directory(folder)
  const temporary = await mkdtemp(join(folder, '.import-'))
  const candidate = join(temporary, 'source.wav')
  try {
    const hash = createHash('sha256')
    const observe = new Transform({ transform(bytes, _, done) { hash.update(bytes); done(null, bytes) } })
    await pipeline(createReadStream(input), observe, createWriteStream(candidate, { flags: 'wx', mode: 0o600 }), { signal })
    const metadata = waveInfo(await readWaveMetadata(candidate, {}, { signal })), sha256 = hash.digest('hex')
    const file = `assets/${sha256}.wav`, target = join(root, file)
    const handle = await open(candidate, 'r')
    try { await handle.sync() } finally { await handle.close() }
    await chmod(candidate, 0o444)
    signal?.throwIfAborted()
    try { await link(candidate, target) }
    catch (error) {
      if (error.code !== 'EEXIST') throw error
      await inspectWaveAsset(root, { file, sha256, metadata, name: basename(input) }, { signal })
    }
    const parent = await open(folder, 'r')
    try { await parent.sync() } finally { await parent.close() }
    signal?.throwIfAborted()
    return { kind: 'wave', file, sha256, metadata }
  } finally { await rm(temporary, { recursive: true, force: true }) }
}

// Import into project-owned storage, never hard-link the musician's original.
// Asset names are labels; the shared immutable filename is content-addressed.
export async function importArrangementWave(project, input, { projectPath, name = basename(input), signal } = {}) {
  validateArrangement(project)
  if (typeof projectPath !== 'string' || !projectPath) throw new Error('Choose a project path before importing WAV')
  const asset = { ...await copyWaveAsset(input, dirname(resolve(projectPath)), { signal }),
    id: arrangementID(project.assets, 'asset'), name }
  const document = editArrangement(project, { kind: 'asset-add', asset })
  return { project: document, asset: asset.id }
}
export async function importArrangementMidi(project, input, { name = basename(input), signal } = {}) {
  validateArrangement(project)
  const source = importMidiSource(await readFile(input, { signal }), { name })
  signal?.throwIfAborted()
  const asset = { kind: 'midi', id: arrangementID(project.assets, 'asset'), name, source }
  return { project: editArrangement(project, { kind: 'asset-add', asset }), asset: asset.id }
}
export async function verifyArrangementAssets(project, root, options = {}) {
  validateArrangement(project)
  const paths = new Map()
  for (const asset of project.assets) if (asset.kind === 'wave') paths.set(asset.id, await inspectWaveAsset(resolve(root), asset, options))
  options.signal?.throwIfAborted()
  return paths
}
export async function loadArrangement(path, options = {}) {
  options.signal?.throwIfAborted()
  const loaded = await loadProject(path, options)
  validateArrangement(loaded.project)
  await verifyArrangementAssets(loaded.project, dirname(loaded.path), options)
  return loaded
}
export async function materializeArrangementAssets(project, sourceRoot, targetRoot, { signal } = {}) {
  validateArrangement(project)
  targetRoot = resolve(targetRoot)
  const originalRoot = resolve(sourceRoot)
  const paths = await verifyArrangementAssets(project, originalRoot, { signal })
  if (targetRoot !== originalRoot) {
    for (const asset of project.assets) if (asset.kind === 'wave') {
      const copied = await copyWaveAsset(paths.get(asset.id), targetRoot, { signal })
      if (copied.sha256 !== asset.sha256 || !equalMetadata(copied.metadata, asset.metadata)) throw new Error('WAV source changed during save-as')
    }
  }
  signal?.throwIfAborted()
}
export async function saveArrangement(path, project, revision = null, { sourceRoot = dirname(resolve(path)), signal } = {}) {
  await materializeArrangementAssets(project, sourceRoot, dirname(resolve(path)), { signal })
  // Once the revision-protected publication starts, its existing retained-inode
  // protocol owns completion; cancellation cannot turn a committed save into failure.
  return saveProject(path, project, revision)
}
