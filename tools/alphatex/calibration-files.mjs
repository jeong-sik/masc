import { readFile, lstat, mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { createHash } from 'node:crypto'
import { isDeepStrictEqual } from 'node:util'
import { calibrationSelection, calibrationReference, analyzeCalibration } from './audio-calibration.mjs'
import { validateCalibrationProfile } from './calibration-profile.mjs'

const hash = bytes => createHash('sha256').update(bytes).digest('hex')
// Recompute from retained samples and clocks in the IO worker. An edited numeric
// candidate alone cannot authorize a measured placement. Embedded hashes are
// portable evidence identities, not paths or an assertion of physical hardware.
export async function inspectCalibration(directory, { signal } = {}) {
  const names = { measurement: 'measurement.json', reference: 'reference.wav', playback: 'playback.json',
    manifest: 'capture/session.json', wave: 'capture/audio.wav', blocks: 'capture/audio-blocks.jsonl', midi: 'capture/midi.ump.jsonl' }
  const bytes = {}
  for (const [role, name] of Object.entries(names)) {
    const path = join(directory, name)
    if (!(await lstat(path)).isFile()) throw new Error('Calibration evidence must be regular files')
    bytes[role] = await readFile(path, { signal })
  }
  const candidate = JSON.parse(bytes.measurement), playback = JSON.parse(bytes.playback), manifest = JSON.parse(bytes.manifest)
  if (candidate?.schemaVersion !== 1 || candidate.kind !== 'audio-calibration-candidate' || candidate.status !== 'unapplied'
      || manifest.monitoring?.state !== 'off' || manifest.midiPacketCount !== '0' || !Array.isArray(manifest.midiSources) || manifest.midiSources.length !== 0 || !isDeepStrictEqual(candidate.playback, playback)) throw new Error('Invalid or changed calibration experiment')
  const selection = calibrationSelection({ output: candidate.output?.id, inputChannel: candidate.inputChannel, outputChannel: candidate.outputChannel, maxLagMs: candidate.maxLagMs })
  const reference = calibrationReference(manifest.sampleRate, playback.device.outputs, selection)
  if (!bytes.reference.equals(reference.wave)) throw new Error('Calibration reference does not match the selected experiment')
  const snapshot = await mkdtemp(join(tmpdir(), 'masc-calibration-inspect-'))
  try {
    await mkdir(join(snapshot, 'capture'))
    for (const [role, name] of Object.entries(names)) await writeFile(join(snapshot, name), bytes[role], { flag: 'wx', mode: 0o600, signal })
    const recomputed = await analyzeCalibration({ directory: snapshot, reference, playback, selection, signal })
    if (!isDeepStrictEqual(candidate, recomputed)) throw new Error('Calibration candidate disagrees with retained samples and clocks')
  } finally { await rm(snapshot, { recursive: true, force: true }) }
  signal?.throwIfAborted()
  return validateCalibrationProfile({ schemaVersion: 1, kind: 'audio-calibration-profile', maxLagMs: candidate.maxLagMs,
    measurement: bytes.measurement.toString('utf8'),
    experiment: Object.fromEntries(Object.entries(bytes).map(([role, value]) => [role, hash(value)])),
    input: { id: manifest.input.id, channel: selection.inputChannel, sampleRate: manifest.sampleRate, monitoring: 'off' },
    output: { id: playback.device.id, channel: selection.outputChannel, sampleRate: playback.clock.sampleRate, bufferFrames: playback.clock.bufferFrames },
    clock: { anchor: playback.clock.anchor, numer: playback.clock.numer, denom: playback.clock.denom },
    pulses: candidate.matches.map((match, index) => ({ pulseFrame: reference.pulseFrames[index], frame: match.frame,
      blockHostTime: match.blockHostTime, blockFrameOffset: match.blockFrameOffset, localFrame: match.localFrame, correlation: match.correlation })) })
}
