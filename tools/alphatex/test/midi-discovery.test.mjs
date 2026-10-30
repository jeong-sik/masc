import test from 'node:test'
import assert from 'node:assert/strict'
import { createServer } from 'node:net'
import { mkdtemp, writeFile, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { midiDestinations } from '../playback.mjs'

test('cancelled MIDI discovery owns its child until the helper closes', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'masc-midi-discovery-'))
  const server = createServer(), socketPath = join(directory, 'control.sock')
  let socket, pending
  try {
    await new Promise((resolve, reject) => { server.once('error', reject); server.listen(socketPath, resolve) })
    const connected = new Promise(resolve => server.once('connection', value => { socket = value; socket.once('data', resolve) }))
    const executable = join(directory, 'discovery')
    await writeFile(executable, `#!${process.execPath}
import { connect } from 'node:net'
const socket = connect(${JSON.stringify(socketPath)}, () => socket.write('ready'))
process.on('SIGTERM', () => socket.write('cancelled'))
socket.on('data', () => { console.log(JSON.stringify({ kind: 'destinations', destinations: [] })); socket.end() })
`, { mode: 0o700 })
    const controller = new AbortController()
    let settled = false
    pending = midiDestinations({ executable, signal: controller.signal }).finally(() => { settled = true })
    pending.catch(() => {})
    await connected
    const cancelled = new Promise(resolve => socket.once('data', resolve))
    controller.abort(); await cancelled
    assert.equal(settled, false)
    socket.end('release')
    await assert.rejects(pending, { name: 'AbortError' })
    await assert.rejects(midiDestinations({ executable, signal: controller.signal }), { name: 'AbortError' })
    await assert.rejects(midiDestinations({ executable: join(directory, 'missing') }), { code: 'ENOENT' })
  } finally {
    socket?.destroy()
    await pending?.catch(() => {})
    await new Promise(resolve => server.close(resolve))
    await rm(directory, { recursive: true, force: true })
  }
})
