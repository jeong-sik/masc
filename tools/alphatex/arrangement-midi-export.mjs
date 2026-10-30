import JZZ from 'jzz'
import { scheduler } from 'node:timers/promises'
import { createHash } from 'node:crypto'
import { mkdtemp, readFile, writeFile, open, link, rm } from 'node:fs/promises'
import { dirname, join, resolve } from 'node:path'
import { arrangementPlaybackSchedule, sourceNanosecondsAtTick } from './arrangement.mjs'
import { prepareArrangementMidiParts } from './arrangement-vst.mjs'
import { midiSourcePattern, encodeMidiFile } from './midi-source.mjs'
import { binary, rational } from './exact-time.mjs'

// SMF's PPQ field has 15 usable bits; use its finest quarter-note grid.
const division = 0x7fff, maximumDelta = 0x0fffffff
const bytesString = bytes => Buffer.from(bytes).toString('latin1')
const time = seconds => {
  if (seconds === 0) return [0n, 1n]
  const [n, d] = binary(seconds)
  return [n * 1_000_000_000n, d]
}
const sum = ([a, b], [c, d]) => [a * d + c * b, b * d]

export function arrangementMidiProject(project) {
  const { playbackLoop, practice, ...linear } = project
  const schedule = arrangementPlaybackSchedule(linear)
  const assets = new Map(project.assets.map(asset => [asset.id, asset]))
  for (const clip of schedule) {
    const asset = assets.get(clip.asset)
    if (asset.kind === 'capture' && clip.component !== 'audio' && BigInt(asset.manifest.midiPacketCount) > 0n) {
      throw new Error('Captured UMP needs a MIDI Clip export, not conversion to a MIDI 1 file; split the take and mute its MIDI component to export other MIDI regions')
    }
  }
  return linear
}

// Native projection owns prefix chase, expression, source order and finite-copy
// cleanup. The SMF encoder owns only the common clock and independent port map.
export async function arrangementMidiFile(project, selected, { signal, onProgress } = {}) {
  signal?.throwIfAborted()
  if (selected.parts.length > 128) throw new Error('MIDI export needs more independent region ports than the supported SMF port range 0–127; export fewer regions together')
  const microseconds = Math.round(60e6 / project.tempo)
  if (!Number.isInteger(microseconds) || microseconds < 1 || microseconds > 0xffffff) throw new Error('Arrangement tempo cannot be represented by an SMF tempo event')
  let maxError = 0, events = 0, endTick = 0
  const tickAt = ([n, d]) => {
    const scaled = n * BigInt(division), denominator = d * BigInt(microseconds) * 1000n
    const tick = (scaled * 2n + denominator) / (denominator * 2n)
    if (tick > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error('Arrangement exceeds the MIDI encoder’s exact tick range')
    const error = tick * denominator - scaled
    maxError = Math.max(maxError, Number(error < 0n ? -error : error) / Number(d * BigInt(division)))
    endTick = Math.max(endTick, Number(tick))
    return Number(tick)
  }
  const checkpoint = async () => { await scheduler.yield(); signal?.throwIfAborted() }
  const row = (tick, message) => ({ tick, message })
  const file = [[row(0, JZZ.MIDI.smfSeqName(project.title)), row(0, JZZ.MIDI.smfTempo(microseconds)),
    row(0, JZZ.MIDI.smfTimeSignature(...project.meter))]]
  const schedule = arrangementPlaybackSchedule(project)
  const assets = new Map(project.assets.map(asset => [asset.id, asset]))
  for (const clip of schedule) tickAt(time(clip.endSeconds))
  const ports = []
  for (const [port, part] of selected.parts.entries()) {
    signal?.throwIfAborted()
    const bytes = await readFile(part.path, { signal })
    if (createHash('sha256').update(bytes).digest('hex') !== part.sha256) throw new Error('MIDI export projection changed after preparation')
    const lines = bytes.toString('utf8').trimEnd().split('\n')
    const header = JSON.parse(lines.shift()), wire = []
    for (const line of lines) { await checkpoint(); wire.push(JSON.parse(line)) }
    if (header.schemaVersion !== 1 || header.kind !== 'vst-midi-part' || header.duration !== part.duration || wire.length !== part.eventCount) throw new Error('Invalid MIDI export projection stream')
    const region = selected.plan.regions.find(region => region.id === part.region)
    const clip = schedule.find(clip => clip.id === part.region), asset = assets.get(clip.asset)
    const lane = project.lanes.find(lane => lane.id === clip.lane)
    const rows = [row(0, JZZ.MIDI.smfSeqName(`${lane.name} · ${clip.name} · source port ${part.port}`)),
      row(0, JZZ.MIDI.smf(0x21, bytesString([port])))]
    const sound = asset.source.sound
    if (sound?.kind === 'vst') rows.push(row(0, JZZ.MIDI.smfInstrName(sound.selection.name)))
    ports.push({ track: file.length, region: part.region, source: part.source, sourcePort: part.port, exportPort: port })
    let previous = 0
    for (const [index, event] of wire.entries()) {
      await checkpoint()
      if (!Number.isFinite(event.seconds) || event.seconds < previous || event.seconds > part.duration
          || !Array.isArray(event.bytes) || !event.bytes.length || event.bytes.some(byte => !Number.isInteger(byte) || byte < 0 || byte > 255)) throw new Error('Invalid MIDI export wire event')
      previous = event.seconds
      // System common/realtime messages travel as SMF F7 escape packets.
      // They cannot be encoded as standalone SMF channel events.
      const data = event.bytes[0] > 0xf0 ? [0xf7, ...event.bytes] : event.bytes
      rows.push({ tick: tickAt(sum(time(part.startSeconds), time(event.seconds))), message: JZZ.MIDI(data) })
      events++
      if (index === 0) onProgress?.({ kind: 'midi-track', track: port + 1, total: selected.parts.length, events: wire.length })
    }
    const performance = midiSourcePattern(asset.source, { pattern: clip.pattern })
    // Text/lyrics/cues keep their original bytes. Clock/global metadata and
    // every other original event remain losslessly in the MASC source chunk.
    const firstPort = selected.parts.find(value => value.region === part.region).port
    const availablePorts = new Set(selected.parts.filter(value => value.region === part.region).map(value => value.port))
    const text = performance.events.filter(event => event.kind === 'meta' && event.type >= 1 && event.type <= 9
      && (availablePorts.has(event.port) ? event.port : firstPort) === part.port
      && event.tick >= clip.offset && (event.tick < clip.offset + clip.extent
        || event.tick === clip.offset + clip.extent && event.tick === performance.ticks))
    for (let copy = 0; text.length && copy < region.repeatCount; copy++) {
      for (const event of text) {
        await checkpoint()
        const [sn, sd] = rational(region.startNanoseconds), [pn, pd] = rational(region.periodNanoseconds)
        const [an, ad] = sourceNanosecondsAtTick(performance, event.tick), [on, od] = sourceNanosecondsAtTick(performance, clip.offset)
        const en = an * od - on * ad, ed = ad * od
        rows.push({ tick: tickAt(sum([sn * pd + BigInt(copy) * pn * sd, sd * pd], [en, ed])),
          message: JZZ.MIDI.smf(event.type, bytesString(event.data)) })
      }
    }
    file.push(rows)
    onProgress?.({ kind: 'midi-track-complete', track: port + 1, total: selected.parts.length })
  }
  const excludedAudioRegions = schedule.filter(clip => assets.get(clip.asset).kind !== 'midi').map(clip => clip.id)
  const receipt = { kind: 'midi-export', tracks: selected.parts.length, events, division, microseconds,
    maxTimingErrorNanoseconds: maxError, ports, excludedAudioRegions, instrumentAudioIncluded: false }
  // SMF allows unknown chunks. The complete authored document retains original
  // SMF/RMID bytes, all metadata, source edits and owned instrument snapshots;
  // other sequencers can ignore this chunk and play the normal SMF tracks.
  const provenance = Buffer.from(JSON.stringify({ schemaVersion: 1, kind: 'masc-arrangement-midi', project, receipt }))
  if (provenance.length > 0xffffffff) throw new Error('MIDI source provenance exceeds the SMF chunk size')
  const tracks = []
  const raw = ({ tick, message }) => message.dd === undefined
    ? { tick, kind: message[0] >= 0xf0 ? 'sysex' : 'channel',
        ...(message[0] >= 0xf0 ? { status: message[0], data: Array.from(message).slice(1) } : { bytes: Array.from(message) }) }
    : { tick, kind: 'meta', type: message.ff, data: Array.from(Buffer.from(message.dd, 'latin1')) }
  // Stable sorting retains equal-tick wire order. Encode directly rather than
  // repeatedly inserting into a track (which would rescan its prefix).
  for (const rows of file) {
    await checkpoint()
    rows.push(row(endTick, JZZ.MIDI.smfEndOfTrack()))
    rows.sort((a, b) => a.tick - b.tick)
    let previous = 0
    const track = []
    for (const event of rows) {
      await checkpoint()
      while (event.tick - previous > maximumDelta) {
        await checkpoint()
        previous += maximumDelta; track.push(raw(row(previous, JZZ.MIDI.smfText(''))))
      }
      track.push(raw(event)); previous = event.tick
    }
    tracks.push(track)
  }
  onProgress?.({ kind: 'midi-serialize' })
  const bytes = await encodeMidiFile({ division, tracks, extraChunks: [{ type: 'MASC', data: provenance }] }, { checkpoint })
  onProgress?.({ kind: 'midi-serialized' })
  return { bytes, receipt }
}

export async function exportArrangementMidi(project, target, { directory, signal, executable,
  prepare = prepareArrangementMidiParts, onProgress } = {}) {
  signal?.throwIfAborted()
  const linear = arrangementMidiProject(project), path = resolve(target)
  const temporary = await mkdtemp(join(directory, 'midi-export-'))
  let publication
  try {
    onProgress?.({ kind: 'midi-projection' })
    const selected = await prepare(linear, { directory: temporary, signal, executable })
    onProgress?.({ kind: 'midi-encode' })
    const { bytes, receipt } = await arrangementMidiFile(linear, selected, { signal, onProgress })
    signal?.throwIfAborted()
    publication = await mkdtemp(join(dirname(path), '.masc-midi-export-'))
    const staged = join(publication, 'arrangement.mid')
    await writeFile(staged, bytes, { flag: 'wx', mode: 0o600, signal })
    const file = await open(staged, 'r')
    try { await file.sync() } finally { await file.close() }
    signal?.throwIfAborted()
    await link(staged, path)
    return { ...receipt, path }
  } finally {
    if (publication) await rm(publication, { recursive: true, force: true })
    await rm(temporary, { recursive: true, force: true })
  }
}
