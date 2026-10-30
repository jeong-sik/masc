import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, writeFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { devices, monitorInput } from '../capture.mjs'

test('discovery cancellation rejects AbortError and spawn failure rejects its actual cause', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'masc-discovery-cancel-'))
  const executable = join(directory, 'discovery')
  try {
    await writeFile(executable, `#!/usr/bin/env node
process.stdout.write(JSON.stringify({kind: 'devices', audio: [], midi: []}))
`, { mode: 0o700 })
    const controller = new AbortController()
    const discovery = devices({ executable, signal: controller.signal })
    // Register rejection handling before cancellation to avoid unhandled rejections.
    const rejected = assert.rejects(discovery, { name: 'AbortError' })
    controller.abort()
    await rejected
    await assert.rejects(devices({ executable, signal: controller.signal }), { name: 'AbortError' })
    await assert.rejects(devices({ executable: join(directory, 'missing') }), { code: 'ENOENT' })
    assert.deepEqual(await devices({ executable }), { kind: 'devices', audio: [], midi: [] })
  } finally { await rm(directory, { recursive: true, force: true }) }
})


test('actual input monitor wrapper pins both UIDs, waits for native close and refuses mismatched acknowledgements', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'masc-monitor-protocol-')), executable = join(directory, 'monitor')
  try {
    await writeFile(executable, `#!/usr/bin/env node
const args=process.argv.slice(2), emit=value=>process.stdout.write(JSON.stringify(value)+'\\n')
const input=args[args.indexOf('--input')+1], output=args[args.indexOf('--monitor-output')+1]
if(args[0]!=='monitor'||args.includes('--directory')||args.includes('--midi'))process.exit(2)
emit({kind:'monitoring',monitoring:{state:'active',input:{id:input},output:{id:output==='wrong'?'different':output},sampleRate:48000,channels:2,latency:{kind:'device-reported',inputSeconds:.001,outputSeconds:.002}}})
process.stdin.resume();process.stdin.on('end',()=>{emit({kind:'stopped',session:{state:'monitored'}});process.stdout.end();})
`, { mode: 0o700 })
    let acknowledge
    const started = new Promise(resolve => { acknowledge = resolve })
    const handle = monitorInput({ input: 'selected input', monitorOutput: 'selected output', executable, onEvent: event => { if (event.kind === 'monitoring') acknowledge(event) } })
    let closed = false; handle.completion.then(() => { closed = true })
    const info = await started
    assert.equal(info.monitoring.output.id, 'selected output'); assert.equal(closed, false)
    handle.stop(); handle.stop(); await handle.completion; assert.equal(closed, true)
    const wrong = monitorInput({ input: 'selected input', monitorOutput: 'wrong', executable })
    await assert.rejects(wrong.completion, /Invalid selected input monitoring acknowledgement/)
    await assert.rejects(monitorInput({ input: 'x', monitorOutput: 'y', executable: join(directory, 'absent') }).completion, { code: 'ENOENT' })
  } finally { await rm(directory, { recursive: true, force: true }) }
})
