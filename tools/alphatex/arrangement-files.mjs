import { verifyPhraseSnapshot, importPhraseDocument } from './phrase-arrangement.mjs'
import { capturePartNames, validateCaptureManifest } from './captured-source.mjs'
import { readCaptureFiles, readCapture, jsonLines } from './session-data.mjs'
import { capturePaths, captureMatches, inspectCaptureAsset } from './captured-source-files.mjs'
import { practicePartNames, practiceRange, practiceRegionTime } from './practice-source.mjs'
import { practicePasses } from './practice-passes.mjs'
import { practiceMidi } from './practice-midi.mjs'
import { captureMidi } from './capture-midi.mjs'
import { extractUmpRegion } from './ump-region-midi.mjs'
import { materializeUmp } from './ump-source.mjs'
import { captureRange, captureRegionTime } from './capture-time.mjs'
import { practicePaths, readPracticeFiles, inspectPracticeAsset } from './practice-source-files.mjs'
import { readFile, writeFile, rename, open, mkdir, mkdtemp, lstat, link, rm, chmod } from 'node:fs/promises'
import { createReadStream, createWriteStream } from 'node:fs'
import { Transform } from 'node:stream'
import { pipeline } from 'node:stream/promises'
import { createHash } from 'node:crypto'
import { isDeepStrictEqual } from 'node:util'
import { basename, dirname, join, resolve } from 'node:path'
import { tmpdir } from 'node:os'
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
// The capture's JSONL and manifest bytes are source material too. Publish
// private immutable copies with the same exclusive content identity as WAVs.
async function copyDataPart(input, root, { signal, kind = 'capture' } = {}) {
  if (!['capture', 'practice'].includes(kind)) throw new Error('Unknown source part kind')
  signal?.throwIfAborted()
  const folder = join(root, 'assets'); await directory(folder)
  const temporary = await mkdtemp(join(folder, '.import-')), candidate = join(temporary, `source.${kind}`)
  try {
    const hash = createHash('sha256')
    const observe = new Transform({ transform(bytes, _, done) { hash.update(bytes); done(null, bytes) } })
    await pipeline(createReadStream(input), observe, createWriteStream(candidate, { flags: 'wx', mode: 0o600 }), { signal })
    const sha256 = hash.digest('hex'), file = `assets/${sha256}.${kind}`, target = join(root, file)
    const handle = await open(candidate, 'r'); try { await handle.sync() } finally { await handle.close() }
    await chmod(candidate, kind === 'practice' ? 0o400 : 0o444); signal?.throwIfAborted()
    try { await link(candidate, target) }
    catch (error) {
      if (error.code !== 'EEXIST') throw error
      const stat = await lstat(target)
      if (!stat.isFile() || kind === 'practice' && (stat.mode & 0o077) || await digestFile(target, { signal }) !== sha256) throw new Error('Source content or privacy changed at publication')
    }
    const parent = await open(folder, 'r'); try { await parent.sync() } finally { await parent.close() }
    signal?.throwIfAborted()
    return { file, sha256 }
  } finally { await rm(temporary, { recursive: true, force: true }) }
}
export async function importArrangementCapture(project, input, { projectPath, name = basename(input), signal } = {}) {
  validateArrangement(project)
  if (typeof projectPath !== 'string' || !projectPath) throw new Error('Choose a project path before importing a captured take')
  const root = dirname(resolve(projectPath)), parts = {}
  for (const [role, filename] of Object.entries(capturePartNames)) {
    const copied = role === 'audio' ? await copyWaveAsset(join(input, filename), root, { signal })
      : await copyDataPart(join(input, filename), root, { signal })
    parts[role] = { file: copied.file, sha256: copied.sha256 }
  }
  const timeline = await readCaptureFiles(capturePaths(root, { parts }), { signal })
  const asset = { kind: 'capture', id: arrangementID(project.assets, 'asset'), name, parts,
    midiTime: structuredClone(timeline.midiTime),
    manifest: structuredClone(validateCaptureManifest(timeline.manifest)) }
  captureMatches(asset, timeline); signal?.throwIfAborted()
  return { project: editArrangement(project, { kind: 'asset-add', asset }), asset: asset.id }
}
export async function importArrangementPractice(project, input, { projectPath, name = basename(input), signal } = {}) {
  validateArrangement(project)
  if (typeof projectPath !== 'string' || !projectPath) throw new Error('Choose a project path before importing a practice take')
  const root = dirname(resolve(projectPath)), parts = {}
  // Copy before decoding: the receipt, frozen preset and packets are validated
  // from the private project-owned bytes that will actually survive save-as.
  for (const [role, filename] of Object.entries(practicePartNames)) parts[role] = await copyDataPart(join(input, filename), root, { signal, kind: 'practice' })
  const { metadata, identities } = await readPracticeFiles(practicePaths(root, { parts }), { signal })
  if (metadata.packets === '0') throw new Error('Practice take contains no MIDI packets to arrange')
  if (Object.keys(parts).some(role => parts[role].sha256 !== identities[role])) throw new Error('Practice source changed during import')
  const asset = { kind: 'practice', id: arrangementID(project.assets, 'asset'), name, parts, metadata }
  signal?.throwIfAborted()
  return { project: editArrangement(project, { kind: 'asset-add', asset }), asset: asset.id }
}
export async function prepareArrangementPractice(project, assetID, { sourceRoot, directory: parent, signal } = {}) {
  validateArrangement(project); signal?.throwIfAborted()
  const asset = project.assets.find(asset => asset.id === assetID && asset.kind === 'practice')
  if (!asset) throw new Error('Choose a raw practice take')
  const files = await inspectPracticeAsset(sourceRoot, asset, { signal }), temporary = await mkdtemp(join(parent, 'practice-'))
  try {
    const parts = {}
    for (const [role, filename] of Object.entries(practicePartNames)) {
      const candidate = join(temporary, filename), hash = createHash('sha256')
      const observe = new Transform({ transform(bytes, _, done) { hash.update(bytes); done(null, bytes) } })
      await pipeline(createReadStream(files[role]), observe, createWriteStream(candidate, { flags: 'wx', mode: 0o600 }), { signal })
      if (hash.digest('hex') !== asset.parts[role].sha256) throw new Error('Practice source changed during playback preparation')
      await chmod(candidate, 0o400); parts[role] = candidate
    }
    const read = await readPracticeFiles(parts, { signal })
    if (!isDeepStrictEqual(read.metadata, asset.metadata)) throw new Error('Practice clock provenance changed during playback preparation')
    signal?.throwIfAborted()
    return { directory: temporary }
  } catch (error) { await rm(temporary, { recursive: true, force: true }); throw error }
}
// Recover a draft from verified private bytes. The new MIDI variant can be
// edited independently; raw take parts stay immutable. Cleanup precedes reply.
export async function restorePracticeBacking(project, assetID, { sourceRoot, directory = tmpdir(), signal } = {}) {
  const snapshot = await prepareArrangementPractice(project, assetID, { sourceRoot, directory, signal })
  try {
    const asset = project.assets.find(asset => asset.id === assetID)
    const bytes = await readFile(join(snapshot.directory, 'context.json'), { signal })
    if (createHash('sha256').update(bytes).digest('hex') !== asset.parts.context.sha256) throw new Error('Practice context changed during backing restoration')
    const context = JSON.parse(bytes.toString('utf8')), phrase = context.project
    phrase.title += ' backing'
    phrase.tracks.find(track => track.id === context.track).muted = true
    signal?.throwIfAborted()
    return importPhraseDocument(project, phrase)
  } finally { await rm(snapshot.directory, { recursive: true, force: true }) }
}
// Read the verified frozen clock privately; return only its derived selection.
export async function inspectPracticePasses(project, assetID, pass, { sourceRoot, directory = tmpdir(), signal } = {}) {
  const snapshot = await prepareArrangementPractice(project, assetID, { sourceRoot, directory, signal })
  try {
    const asset = project.assets.find(asset => asset.id === assetID)
    const bytes = await readFile(join(snapshot.directory, 'context.json'), { signal })
    if (createHash('sha256').update(bytes).digest('hex') !== asset.parts.context.sha256) throw new Error('Practice context changed during pass inspection')
    const context = JSON.parse(bytes.toString('utf8'))
    const result = practicePasses(asset, context.backing, pass)
    signal?.throwIfAborted()
    return { asset: assetID, ...result }
  } finally { await rm(snapshot.directory, { recursive: true, force: true }) }
}
export async function importPracticeMidi(project, assetID, { sourceRoot, directory = tmpdir(), signal, cut, nativeExecutable } = {}) {
  const snapshot = await prepareArrangementPractice(project, assetID, { sourceRoot, directory, signal })
  try {
    const asset = project.assets.find(asset => asset.id === assetID), values = {}
    for (const role of ['context', 'events']) {
      const bytes = await readFile(join(snapshot.directory, practicePartNames[role]), { signal })
      if (createHash('sha256').update(bytes).digest('hex') !== asset.parts[role].sha256) throw new Error('Practice content changed during MIDI derivation')
      values[role] = bytes.toString('utf8')
    }
    const packets = values.events.trimEnd().split('\n').map(line => JSON.parse(line).packet)
    let region
    if (cut) {
      const range = practiceRange(asset), full = practiceRegionTime(asset, { offset: '0', extent: range.extent })
      practiceRegionTime(asset, cut)
      region = await extractUmpRegion({ id: asset.id, extent: range.extent,
        timeline: { schemaVersion: 4, duration: full.durationSeconds, clock: { origin: range.origin, ...asset.metadata.input.clock },
          bindings: [{ source: asset.metadata.input.source.id, destination: asset.metadata.input.source.id }], packets } }, cut,
      { directory: snapshot.directory, signal, executable: nativeExecutable })
    }
    const source = practiceMidi(asset, JSON.parse(values.context), packets, { signal, region })
    return importPhraseDocument(project, source)
  } finally { await rm(snapshot.directory, { recursive: true, force: true }) }
}
export async function importCaptureMidi(project, assetID, { sourceRoot, directory = tmpdir(), signal, cut, nativeExecutable } = {}) {
  const snapshot = await prepareArrangementCapture(project, assetID, { sourceRoot, directory, signal })
  try {
    const asset = project.assets.find(asset => asset.id === assetID)
    const packets = []
    for await (const packet of jsonLines(join(snapshot.directory, capturePartNames.midi), { signal })) packets.push(packet)
    let region
    if (cut) {
      captureRegionTime(asset, cut)
      const range = captureRange(asset), full = captureRegionTime(asset, { offset: '0', extent: range.extent })
      const used = new Set(packets.map(packet => packet.source))
      // Offline state identities only. CoreMIDI destinations are never opened;
      // preserve opaque input IDs and omit selected inputs with no packets.
      const bindings = asset.manifest.midiSources.filter(source => used.has(source.id))
        .map((source, index) => ({ source: source.id, destination: String(index) }))
      region = await extractUmpRegion({ id: asset.id, extent: range.extent,
        timeline: { schemaVersion: 4, duration: full.durationSeconds,
          clock: { origin: range.origin, numer: asset.manifest.clock.numer, denom: asset.manifest.clock.denom }, bindings, packets } },
      { offset: cut.offset, extent: cut.extent }, { directory: snapshot.directory, signal, executable: nativeExecutable, dueAdmission: 'original' })
    }
    const source = await captureMidi(asset, packets, { tempo: project.tempo, meter: project.meter, signal, region })
    signal?.throwIfAborted()
    return importPhraseDocument(project, source)
  } finally { await rm(snapshot.directory, { recursive: true, force: true }) }
}
// The viewer owns these snapshots until it drains WAV playback/export and
// restores the terminal. A project asset mutation cannot change an open take.
export async function prepareArrangementCapture(project, assetID, { sourceRoot, directory: parent, signal, original = false } = {}) {
  validateArrangement(project); signal?.throwIfAborted()
  const asset = project.assets.find(asset => asset.id === assetID && asset.kind === 'capture')
  if (!asset) throw new Error('Choose a captured take')
  const files = await inspectCaptureAsset(sourceRoot, asset, { signal }), temporary = await mkdtemp(join(parent, 'take-'))
  try {
    for (const [role, filename] of Object.entries(capturePartNames)) {
      const candidate = join(temporary, filename), hash = createHash('sha256')
      const observe = new Transform({ transform(bytes, _, done) { hash.update(bytes); done(null, bytes) } })
      await pipeline(createReadStream(files[role]), observe, createWriteStream(candidate, { flags: 'wx', mode: 0o600 }), { signal })
      if (hash.digest('hex') !== asset.parts[role].sha256) throw new Error('Captured source changed during view preparation')
      await chmod(candidate, 0o444)
    }
    captureMatches(asset, await readCapture(temporary, { signal })); signal?.throwIfAborted()
    if (asset.ump && !original) {
      const packets = []
      for await (const packet of jsonLines(join(temporary, capturePartNames.midi), { signal })) packets.push(packet)
      const edited = materializeUmp(packets, asset.ump, asset.parts.midi.sha256), candidate = join(temporary, 'edited-midi.jsonl')
      await writeFile(candidate, edited.map(packet => JSON.stringify(packet)).join('\n') + '\n', { flag: 'wx', mode: 0o444, signal })
      signal?.throwIfAborted()
      await rename(candidate, join(temporary, capturePartNames.midi))
    }
    return { directory: temporary }
  } catch (error) { await rm(temporary, { recursive: true, force: true }); throw error }
}

export async function readUmpCapture(project, assetID, options) {
  const snapshot = await prepareArrangementCapture(project, assetID, { ...options, original: true })
  try {
    const packets = []
    for await (const packet of jsonLines(join(snapshot.directory, capturePartNames.midi), { signal: options?.signal })) packets.push(packet)
    return { asset: structuredClone(project.assets.find(asset => asset.id === assetID)), packets }
  } finally { await rm(snapshot.directory, { recursive: true, force: true }) }
}
export async function importUmpVariant(project, assetID, ump, options) {
  const { asset, packets } = await readUmpCapture(project, assetID, options)
  materializeUmp(packets, ump, asset.parts.midi.sha256)
  const variant = { ...asset, id: arrangementID(project.assets, 'asset'), name: `${asset.name} UMP variant` }
  if (ump === undefined) delete variant.ump
  else variant.ump = structuredClone(ump)
  delete variant.selectedTake
  options?.signal?.throwIfAborted()
  return { project: editArrangement(project, { kind: 'asset-add', asset: variant }), asset: variant.id }
}
export async function exportUmpCapture(project, assetID, target, options) {
  const snapshot = await prepareArrangementCapture(project, assetID, options)
  let created = false, sealed = false
  try {
    const asset = project.assets.find(asset => asset.id === assetID)
    const derived = await digestFile(join(snapshot.directory, capturePartNames.midi), options)
    const original = await readFile(join(options.sourceRoot, asset.parts.midi.file), { signal: options.signal })
    if (createHash('sha256').update(original).digest('hex') !== asset.parts.midi.sha256) throw new Error('Original UMP changed during export')
    await writeFile(join(snapshot.directory, 'original-midi.ump.jsonl'), original, { flag: 'wx', mode: 0o444, signal: options.signal })
    await writeFile(join(snapshot.directory, 'ump-source.json'), JSON.stringify({ schemaVersion: 1, kind: 'capture-ump-variant',
      original: asset.parts, clock: asset.manifest.clock, ump: asset.ump ?? null, derivedMidiSha256: derived }) + '\n', { flag: 'wx', mode: 0o444, signal: options.signal })
    options.signal?.throwIfAborted()
    await mkdir(target, { mode: 0o700 }); created = true
    for (const name of [...Object.values(capturePartNames), 'original-midi.ump.jsonl', 'ump-source.json']) await link(join(snapshot.directory, name), join(target, name))
    const folder = await open(target, 'r'); try { await folder.sync() } finally { await folder.close() }
    options.signal?.throwIfAborted(); sealed = true
    return { directory: target, derivedMidiSha256: derived }
  } finally {
    if (created && !sealed) await rm(target, { recursive: true, force: true })
    await rm(snapshot.directory, { recursive: true, force: true })
  }
}

export async function verifyArrangementAssets(project, root, options = {}) {
  validateArrangement(project)
  const paths = new Map()
  for (const asset of project.assets) {
    verifyPhraseSnapshot(asset)
    if (asset.kind === 'wave') paths.set(asset.id, await inspectWaveAsset(resolve(root), asset, options))
    else if (asset.kind === 'capture') paths.set(asset.id, await inspectCaptureAsset(resolve(root), asset, options))
    else if (asset.kind === 'practice') paths.set(asset.id, await inspectPracticeAsset(resolve(root), asset, options))
  }
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
    } else if (asset.kind === 'capture') {
      for (const [role, file] of Object.entries(paths.get(asset.id))) {
        const copied = role === 'audio' ? await copyWaveAsset(file, targetRoot, { signal }) : await copyDataPart(file, targetRoot, { signal })
        if (copied.sha256 !== asset.parts[role].sha256) throw new Error('Captured source changed during save-as')
      }
      await inspectCaptureAsset(targetRoot, asset, { signal })
    } else if (asset.kind === 'practice') {
      for (const [role, file] of Object.entries(paths.get(asset.id))) {
        const copied = await copyDataPart(file, targetRoot, { signal, kind: 'practice' })
        if (copied.sha256 !== asset.parts[role].sha256) throw new Error('Practice source changed during save-as')
      }
      await inspectPracticeAsset(targetRoot, asset, { signal })
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
