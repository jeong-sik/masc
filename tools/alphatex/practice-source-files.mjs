import { createReadStream } from 'node:fs'
import { readFile, lstat } from 'node:fs/promises'
import { createHash } from 'node:crypto'
import { StringDecoder } from 'node:string_decoder'
import { join } from 'node:path'
import { isDeepStrictEqual } from 'node:util'
import { practicePartNames, practiceUnsigned, validatePracticeMetadata, validatePracticeSource } from './practice-source.mjs'
import { soundIdentity, soundIdentityMatches } from './project-sound.mjs'
import { validateProject } from './sequencer-project.mjs'
import { phraseBacking } from './phrase-backing.mjs'
import { nominalMidiFrame } from './render-midi-clock.mjs'
import { unpackMidi } from './session-data.mjs'

export const practicePaths = (root, asset) => Object.fromEntries(Object.entries(asset.parts).map(([role, part]) => [role, join(root, part.file)]))
const hash = bytes => createHash('sha256').update(bytes).digest('hex')

function retirement(receipt, arm, context) {
  const count = practiceUnsigned(receipt.packets), input = receipt.inputFinal, monitor = receipt.monitorFinal, pcm = monitor?.pcm, final = pcm?.final
  if (input?.kind !== 'stopped' || input.success !== true || input.source !== arm.input?.source?.id || input.error !== null
      || input.admittedPackets !== String(count) || input.acknowledgedPackets !== String(count) || input.discardedPackets !== '0' || input.pendingWords !== 0
      || monitor?.schemaVersion !== 1 || monitor.kind !== 'step-monitor' || monitor.channel !== context.backing.channel
      || !soundIdentityMatches(context.project.sound, monitor.sound)
      || pcm?.nativeClosed !== true || pcm.settled !== true || pcm.playing !== true || pcm.nativeError !== null || pcm.receiptError !== null || pcm.failure !== null
      || !isDeepStrictEqual(pcm.clock, arm.renderClock) || !isDeepStrictEqual(pcm.device, arm.renderClock?.device) || pcm.format?.sampleRate !== arm.renderClock?.sampleRate
      || final?.kind !== 'stopped' || final.success !== true || final.fault !== 'none' || final.faultFrames !== '0' || final.underrunFrames !== '0'
      || monitor.worker && (monitor.worker.closed !== true || monitor.worker.terminalReceived !== true || monitor.worker.failure !== null)) throw new Error('Practice receipt did not confirm input/audio retirement')
  const rendered = practiceUnsigned(final.renderedFrames)
  if (practiceUnsigned(final.admittedFrames) !== rendered + practiceUnsigned(final.discardedFrames) || pcm.sentFrames !== final.admittedFrames) throw new Error('Practice renderer frame totals disagree')
  return String(rendered)
}

// Hash the very bytes that are decoded. Event logs remain streamed and retain
// original packet order, UMP words, UInt64 ticks and exact signed frame values.
export async function readPracticeFiles(files, { signal } = {}) {
  const values = {}, identities = {}
  for (const role of ['receipt', 'context', 'arm']) {
    const bytes = await readFile(files[role], { signal })
    identities[role] = hash(bytes); values[role] = JSON.parse(bytes.toString('utf8'))
  }
  const { receipt, context, arm } = values
  if (receipt?.schemaVersion !== 1 || receipt.kind !== 'practice-take' || receipt.status !== 'complete' || receipt.error !== null
      || context?.schemaVersion !== 1 || context.kind !== 'practice-take-context'
      || arm?.schemaVersion !== 1 || arm.kind !== 'practice-take-arm') throw new Error('Choose a complete raw practice take')
  validateProject(context.project)
  soundIdentity(context.project.sound)
  if (!isDeepStrictEqual(context.backing, phraseBacking(context.project, context.track, false))
      && !isDeepStrictEqual(context.backing, phraseBacking(context.project, context.track, true))) throw new Error('Practice backing context changed')
  const renderedFrames = retirement(receipt, arm, context)
  // Validate even a zero-packet source before visiting its events.
  nominalMidiFrame(arm.renderClock.anchor.hostTime, arm.input?.clock, arm.renderClock)
  const digest = createHash('sha256'), decoder = new StringDecoder('utf8')
  let buffered = '', count = 0n, first = null, last = null
  const observe = line => {
    if (!line) throw new Error('Empty practice event record')
    const row = JSON.parse(line), packet = row?.packet
    unpackMidi(packet)
    const host = practiceUnsigned(packet.hostTime)
    if (!packet.words.length || packet.source !== arm.input.source.id || packet.ordinal !== String(count)
        || !isDeepStrictEqual(row.nominalFrame, nominalMidiFrame(packet.hostTime, arm.input.clock, arm.renderClock))) throw new Error('Practice event source, sequence or nominal frame changed')
    first = first === null || host < first ? host : first; last = last === null || host > last ? host : last
    count++
  }
  for await (const bytes of createReadStream(files.events, { signal })) {
    digest.update(bytes); buffered += decoder.write(bytes)
    let end
    while ((end = buffered.indexOf('\n')) !== -1) { observe(buffered.slice(0, end)); buffered = buffered.slice(end + 1) }
  }
  buffered += decoder.end(); if (buffered) observe(buffered)
  identities.events = digest.digest('hex')
  if (receipt.packets !== String(count)) throw new Error('Practice receipt packet total changed')
  if (!receipt.files || Object.keys(receipt.files).length !== 3) throw new Error('Invalid practice receipt parts')
  for (const role of ['context', 'arm', 'events']) if (receipt.files[role]?.file !== practicePartNames[role] || receipt.files[role].sha256 !== identities[role]) throw new Error('Practice content disagrees with receipt hash')
  const metadata = validatePracticeMetadata({ input: arm.input, renderClock: arm.renderClock, renderedFrames, packets: String(count),
    midiTime: { first: first === null ? null : String(first), last: last === null ? null : String(last) } })
  signal?.throwIfAborted()
  return { metadata, identities }
}
export async function inspectPracticeAsset(root, asset, options = {}) {
  validatePracticeSource(asset)
  if (!(await lstat(join(root, 'assets'))).isDirectory()) throw new Error('Project assets must be a directory, not a symlink')
  const files = practicePaths(root, asset)
  for (const file of Object.values(files)) {
    const stat = await lstat(file)
    if (!stat.isFile() || stat.mode & 0o077) throw new Error('Practice source must remain a private regular asset')
  }
  const read = await readPracticeFiles(files, options)
  if (!isDeepStrictEqual(read.metadata, asset.metadata) || Object.keys(practicePartNames).some(role => read.identities[role] !== asset.parts[role].sha256)) throw new Error('Practice source content or clock provenance changed')
  return files
}
