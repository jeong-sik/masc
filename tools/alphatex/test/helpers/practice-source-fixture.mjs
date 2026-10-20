import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises'
import { createHash } from 'node:crypto'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { newProject } from '../../sequencer-project.mjs'
import { phraseBacking } from '../../phrase-backing.mjs'
import { nominalMidiFrame } from '../../render-midi-clock.mjs'
import { practicePartNames } from '../../practice-source.mjs'
const hash = bytes => createHash('sha256').update(bytes).digest('hex')
export async function practiceSourceFixture(run) {
  const root = await mkdtemp(join(tmpdir(), 'masc-practice-source-')), input = join(root, 'Original take')
  try {
    await mkdir(input, { mode: 0o700 })
    const preset = Buffer.from('private fixture preset'), project = { ...newProject(), sound: {
      kind: 'vst', selection: { plugin_path: '/fixture.vst3', plugin_name: null, preset_path: null, name: 'Fixture' },
      instrument: { identifier: 'fixture-id', version: '1' }, preset: { data: preset.toString('base64'), sha256: hash(preset) } } }
    const context = { schemaVersion: 1, kind: 'practice-take-context', project, track: 'track-1', backing: phraseBacking(project, 'track-1', true) }
    const renderClock = { schemaVersion: 1, kind: 'clock', device: { id: 'owned', name: 'Output' }, sampleRate: 48000,
      clock: { kind: 'mach-host-time', numer: 125, denom: 3 }, anchor: { frame: '0', hostTime: '18446744073709000000' } }
    const arm = { schemaVersion: 1, kind: 'practice-take-arm', renderClock,
      input: { schemaVersion: 1, kind: 'midi-input', protocol: 2, source: { id: '10', name: 'Keys' }, clock: renderClock.clock } }
    const rows = [[2400n, [0x43953c03, 0x90012345]], [-1n, [0x43b54a00, 0xabcdef01]], [24000n, [0x43853c00, 0x12340000]]].map(([delta, words], i) => {
      const packet = { kind: 'midi', protocol: 2, source: '10', ordinal: String(i), hostTime: String(BigInt(renderClock.anchor.hostTime) + delta), timestampOrigin: 'packet', words }
      return { packet, nominalFrame: nominalMidiFrame(packet.hostTime, arm.input.clock, renderClock) }
    })
    const receipt = { schemaVersion: 1, kind: 'practice-take', status: 'complete', error: null, packets: '3', files: {},
      inputFinal: { kind: 'stopped', source: '10', success: true, error: null, admittedPackets: '3', acknowledgedPackets: '3', discardedPackets: '0', pendingWords: 0 },
      monitorFinal: { schemaVersion: 1, kind: 'step-monitor', channel: context.backing.channel,
        sound: { identifier: 'fixture-id', version: '1', presetSHA256: project.sound.preset.sha256 },
        pcm: { clock: renderClock, device: renderClock.device, format: { sampleRate: 48000 }, nativeClosed: true, settled: true, playing: true,
          nativeError: null, receiptError: null, failure: null, sentFrames: '5824',
          final: { kind: 'stopped', success: true, admittedFrames: '5824', renderedFrames: '4800', discardedFrames: '1024', underrunFrames: '0', fault: 'none', faultFrames: '0' } },
        worker: { closed: true, terminalReceived: true, failure: null } } }
    const files = Object.fromEntries(Object.entries(practicePartNames).map(([role, name]) => [role, join(input, name)]))
    const publish = async () => {
      const bytes = { context: JSON.stringify(context), arm: JSON.stringify(arm), events: rows.map(row => JSON.stringify(row)).join('\n') + '\n' }
      for (const role of ['context', 'arm', 'events']) {
        await writeFile(files[role], bytes[role], { mode: 0o600 }); receipt.files[role] = { file: practicePartNames[role], sha256: hash(bytes[role]) }
      }
      await writeFile(files.receipt, JSON.stringify(receipt), { mode: 0o600 })
    }
    await publish()
    await run({ root, input, files, context, arm, rows, receipt, publish })
  } finally { await rm(root, { recursive: true, force: true }) }
}

