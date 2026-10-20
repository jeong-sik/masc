import { readFile, writeFile } from 'node:fs/promises'
import { createReadStream } from 'node:fs'
import { createInterface } from 'node:readline'
import { createHash, randomUUID } from 'node:crypto'
import { join } from 'node:path'
import { prepareArrangementPractice } from './arrangement-files.mjs'
import { practiceRange, practiceRegionTime } from './practice-source.mjs'
import { monitorPacket } from './step-monitor-session.mjs'
import { sourceAudioFrames } from './source-audio-clock.mjs'

export function practiceAudioClock(asset, offset = '0', extent = practiceRange(asset).extent) {
  const { sourceClock: clock } = practiceRegionTime(asset, { offset, extent })
  return { start: String(BigInt(offset) * BigInt(clock.numer)),
    end: String((BigInt(offset) + BigInt(extent)) * BigInt(clock.numer)), denominator: String(BigInt(clock.denom) * 1_000_000_000n) }
}

// Worker-only source stage. No plug-in is opened here. The raw take remains
// private and immutable; this is the same declared MIDI1 synthesis projection
// as monitored practice, scheduled at exact ceiling sample indices.
export async function preparePracticeVst(project, asset, { sourceRoot, directory, signal } = {}) {
  const snapshot = await prepareArrangementPractice(project, asset.id, { sourceRoot, directory, signal })
  const bytes = await readFile(join(snapshot.directory, 'context.json'), { signal })
  if (createHash('sha256').update(bytes).digest('hex') !== asset.parts.context.sha256) throw new Error('Practice VST context changed')
  const context = JSON.parse(bytes.toString('utf8')), packets = [], digest = createHash('sha256')
  const input = createReadStream(join(snapshot.directory, 'events.jsonl'), { signal })
  input.on('data', chunk => digest.update(chunk))
  const lines = createInterface({ input, crlfDelay: Infinity })
  let failure = null
  input.once('error', error => { failure = error; lines.close() })
  try { for await (const line of lines) packets.push(JSON.parse(line).packet) }
  finally { lines.close(); input.destroy() }
  if (failure) throw failure
  signal?.throwIfAborted()
  if (digest.digest('hex') !== asset.parts.events.sha256) throw new Error('Practice VST events changed')
  packets.sort((a, b) => BigInt(a.hostTime) < BigInt(b.hostTime) ? -1 : BigInt(a.hostTime) > BigInt(b.hostTime) ? 1 : 0)
  const range = practiceRange(asset), rate = asset.metadata.renderClock.sampleRate
  const n = BigInt(asset.metadata.renderClock.clock.numer) * BigInt(rate), d = BigInt(asset.metadata.renderClock.clock.denom) * 1_000_000_000n
  const fullClock = practiceAudioClock(asset), full = sourceAudioFrames(fullClock, rate), events = []
  let held = new Map(), frames = BigInt(full.frameCount)
  for (const packet of packets) {
    signal?.throwIfAborted()
    const tick = (BigInt(packet.hostTime) - BigInt(range.origin)) * n, frame = tick / d + (tick % d ? 1n : 0n)
    const projected = monitorPacket(packet, context.backing.channel, held); held = projected.held
    for (const message of projected.messages) events.push({ frame: String(frame), bytes: message.bytes })
    // The final event may ceil to the original source's after-sample boundary.
    // Render its guard sample, while every region retains the original cut.
    if (projected.messages.length && frame >= frames) frames = frame + 1n
  }
  if (!events.some(event => (event.bytes[0] & 0xf0) === 0x90 && event.bytes[2] > 0)) throw new Error('Practice VST projection has no sounding notes')
  const id = randomUUID(), timelinePath = join(directory, id + '.json'), outputPath = join(directory, id + '.wav')
  const timeline = Buffer.from(JSON.stringify({ schemaVersion: 1, kind: 'practice-vst', sampleRate: rate, frames: String(frames), events }))
  await writeFile(timelinePath, timeline, { flag: 'wx', mode: 0o400, signal }); signal?.throwIfAborted()
  return { id, kind: 'practice', sound: context.project.sound, timelinePath, outputPath,
    timelineHash: createHash('sha256').update(timeline).digest('hex'), sampleRate: rate, frames: String(frames), fullClock }
}
