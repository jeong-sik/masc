import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { isDeepStrictEqual } from 'node:util'
import { importArrangementCapture, importArrangementWave } from './arrangement-files.mjs'
import { newArrangement } from './arrangement.mjs'
import { captureClock, jsonLines, unpackMidi } from './session-data.mjs'
import { validateCaptureManifest } from './captured-source.mjs'
import { readWaveMetadata } from './wave-file.mjs'
import { captureRange } from './capture-time.mjs'

function destination(value) {
  const number = Number(value)
  if (typeof value !== 'string' || !Number.isInteger(number) || number < -2147483648 || number > 2147483647 || String(number) !== value) throw new Error('Choose an exact MIDI destination ID')
  return value
}
// Difference first, then quotient/remainder: original UInt64 host ticks never
// pass through a floating-point clock origin. Negative pre-roll shifts both
// source kinds together by selecting an explicit earliest playback origin.
function seconds(host, origin, clock) {
  const delta = BigInt(host) - origin, denom = BigInt(clock.denom)
  return (Number(delta / denom) * clock.numer + Number(delta % denom) * clock.numer / clock.denom) / 1e9
}
export async function prepareCapturedPlayback(input, { directory, midiOutput, sourceBindings = [], expectedManifest, signal } = {}) {
  signal?.throwIfAborted()
  if (!Array.isArray(sourceBindings) || new Set(sourceBindings.map(binding => binding?.source)).size !== sourceBindings.length) throw new Error('Invalid captured source bindings')
  if (midiOutput !== undefined) destination(midiOutput)
  for (const binding of sourceBindings) if (typeof binding?.source !== 'string' || !binding.source || !destination(binding.destination)) throw new Error('Invalid captured source binding')
  const temporary = await mkdtemp(join(directory, 'capture-play-'))
  try {
    const imported = await importArrangementCapture(newArrangement(), input, { projectPath: join(temporary, 'project.json'), signal })
    const asset = imported.project.assets[0], manifest = asset.manifest, packets = [], used = new Set()
    if (expectedManifest !== undefined && !isDeepStrictEqual(manifest, expectedManifest)) throw new Error('Captured take changed; reopen it before playback')
    const origin = BigInt(captureRange(asset).origin)
    for await (const row of jsonLines(join(temporary, asset.parts.midi.file), { signal })) {
      unpackMidi(row)
      if (typeof row.hostTime !== 'string' || !/^(0|[1-9][0-9]*)$/.test(row.hostTime) || BigInt(row.hostTime) > 0xffffffffffffffffn || !row.words.length) throw new Error('Invalid captured packet host time or empty UMP')
      used.add(row.source); packets.push(row)
    }
    if (!packets.length) throw new Error('Capture has no MIDI packets; select WAV playback')
    if (sourceBindings.some(binding => !used.has(binding.source))) throw new Error('Binding names an unused captured MIDI source')
    const bindings = [...used].map(source => ({ source, destination: destination(sourceBindings.find(binding => binding.source === source)?.destination ?? midiOutput) }))
    const metadata = await readWaveMetadata(join(temporary, asset.parts.audio.file), {}, { signal })
    const frames = Number(metadata.frames)
    if (!Number.isSafeInteger(frames)) throw new Error('WAV frame count exceeds exact project frame precision')
    const audioStart = manifest.clock.firstAudioHostTime === null ? 0 : seconds(manifest.clock.firstAudioHostTime, origin, manifest.clock)
    const audioEnd = audioStart + frames / metadata.sampleRate
    const duration = packets.reduce((end, packet) => Math.max(end, seconds(packet.hostTime, origin, manifest.clock)), audioEnd)
    if (!Number.isFinite(duration) || duration <= 0) throw new Error('Captured source has no representable playback duration')
    const audio = { id: 'capture-audio', path: join(temporary, asset.parts.audio.file), sha256: asset.parts.audio.sha256, ...metadata, frames }
    const midi = { schemaVersion: 4, duration, clock: { origin: String(origin), numer: manifest.clock.numer, denom: manifest.clock.denom }, bindings, packets }
    const plan = { schemaVersion: 3, kind: 'capture-session', duration, assets: frames ? [audio] : [],
      regions: frames ? [{ id: 'capture-audio', asset: audio.id, startSeconds: audioStart, offsetFrames: 0, frameCount: frames, repeat: 1 }] : [], ump: midi }
    const path = join(temporary, 'plan.json');signal?.throwIfAborted()
    await writeFile(path, JSON.stringify(plan), { flag: 'wx', mode: 0o600, signal });signal?.throwIfAborted()
    const ports = [...new Set(bindings.map(binding => binding.destination))].map((destination, port) => ({ port, destination }))
    return { path, duration, format: 'capture-session', midiOutput: ports[0].destination, bindings: ports,
      timelineOffsetSeconds: captureClock(manifest.clock)(String(origin)) }
  } catch (error) { await rm(temporary, { recursive: true, force: true });throw error }
}

// WAV-only audition uses the selected native output and owns an immutable WAV
// snapshot. Choosing this route is explicit; it does not stand in for UMP replay.
export async function prepareCapturedWave(input, { directory, expectedManifest, signal } = {}) {
  signal?.throwIfAborted()
  const temporary = await mkdtemp(join(directory, 'capture-wave-'))
  try {
    const manifest = validateCaptureManifest(JSON.parse(await readFile(join(input, 'session.json'), { encoding: 'utf8', signal })))
    if (expectedManifest !== undefined && !isDeepStrictEqual(manifest, expectedManifest)) throw new Error('Captured take changed; reopen it before playback')
    if (manifest.clock.firstAudioHostTime === null) throw new Error('Captured WAV has no audio origin')
    const { project } = await importArrangementWave(newArrangement(), join(input, 'audio.wav'), { projectPath: join(temporary, 'project.json'), signal })
    const path = join(temporary, project.assets[0].file)
    await readWaveMetadata(path, { sampleRate: manifest.sampleRate, channels: manifest.channels, frames: BigInt(manifest.audioFrames) }, { signal })
    return { path, format: 'wave', timelineOffsetSeconds: captureClock(manifest.clock)(manifest.clock.firstAudioHostTime) }
  } catch (error) { await rm(temporary, { recursive: true, force: true });throw error }
}
