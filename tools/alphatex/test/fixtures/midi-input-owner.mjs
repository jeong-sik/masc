import { createInterface } from 'node:readline'
const [mode, flag, source] = process.argv.slice(2)
if (flag !== '--source') process.exit(3)
const emit = value => process.stdout.write(JSON.stringify(value) + '\n')
const ready = { kind: 'midi-input', schemaVersion: 1, protocol: 2, source: { id: source, name: 'Owned source' }, clock: { kind: 'mach-host-time', numer: 125, denom: 3 } }
const stepPackets = [[0x43953c00, 0x90000000, 0x43954000, 0xffff0000], [0x43853c00, 0x10000000], [0x43854000, 0x20000000]]
const practiceMode = ['practice-clocked', 'practice-attributed'].includes(mode)
const practicePackets = [[0x43b54a00, 0xabcdef01], ...stepPackets.map(words => [...words])]
if (mode === 'practice-attributed') practicePackets[1][0] |= 3
const stepMode = ['step-chord', 'step-held'].includes(mode)
const packet = ordinal => ({ kind: 'midi', source, protocol: 2, ordinal: String(ordinal), hostTime: String(9007199254740993n + BigInt(practiceMode ? [3,240000,480000,720000][ordinal] : ordinal)), timestampOrigin: 'packet', words: practiceMode ? practicePackets[ordinal] : stepMode ? stepPackets[ordinal] : [0x43953c03, 0x90012345] })
let next = 0, acknowledged = 0, waiting = false, stopping = false
const finish = () => { emit({ kind: 'stopped', source, success: true, admittedPackets: String(next), acknowledgedPackets: String(acknowledged), discardedPackets: '0', pendingWords: 0, error: null }); process.exit(0) }
const pump = () => {
  if (waiting) return
  const total = practiceMode ? practicePackets.length : mode === 'step-held' ? 1 : mode === 'step-chord' ? stepPackets.length : 2
  if (mode === 'empty' || next === total) { if (stopping) finish(); return }
  waiting = true; emit(packet(next++))
}
if (mode === 'missing-ready') { process.exit(0) }
if (mode === 'native-error') { emit({ kind: 'error', message: 'selected source not found' }); process.exit(1) }
if (mode === 'wrong-source') { emit({ ...ready, source: { ...ready.source, id: '11' } }) }
else emit(ready)
if (mode === 'duplicate-ready') emit(ready)
else if (mode === 'truncated') emit({ ...packet(0), words: [0x43953c00] })
else if (mode === 'word-range') emit({ ...packet(0), words: [0x100000000] })
else if (mode === 'clock-number') emit({ ...packet(0), hostTime: 100 })
else if (mode === 'out-of-order') emit(packet(1))
else if (mode === 'pipelined') { emit(packet(0)); emit(packet(1)) }
else if (mode === 'false-final') emit({ kind: 'stopped', source, success: false, error: 'input backlog exhausted' })
else if (mode === 'bad-final') emit({ kind: 'stopped', source, success: true, admittedPackets: '1', acknowledgedPackets: '0', discardedPackets: '0', pendingWords: 0 })
else pump()
createInterface({ input: process.stdin }).on('line', line => {
  const command = JSON.parse(line)
  if (command.kind === 'stop') stopping = true
  else if (command.kind === 'ack' && waiting && command.ordinal === String(acknowledged)) { acknowledged++; waiting = false }
  else { process.exit(4) }
  pump()
})
