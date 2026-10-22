import { test } from 'node:test'
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { EventEmitter } from 'node:events'
import { PassThrough } from 'node:stream'
import { fileURLToPath } from 'node:url'
import { openVstSession } from '../vst-session.mjs'

const fixture = fileURLToPath(new URL('./fixtures/vst-serve.mjs', import.meta.url))
function session() {
  const children = []
  const owner = openVstSession({ command: process.execPath, args: [fixture], spawnProcess(...args) {
    const child = spawn(...args); children.push(child); return child
  } })
  return { owner, children }
}

test('jobs of one session share one host process and resolve by id', async () => {
  const { owner, children } = session()
  try {
    const first = owner.run({ operation: 'echo', value: 1 }), second = owner.run({ operation: 'echo', value: 2 })
    const [a, b] = await Promise.all([first.promise, second.promise])
    assert.deepEqual([a.value, b.value], [1, 2])
    assert.equal(a.pid, b.pid)
    assert.equal(children.length, 1)
    await assert.rejects(owner.run({ operation: 'fail' }).promise, /^Error: SilentRender: selected VST produced silence$/)
    assert.equal((await owner.run({ operation: 'echo', value: 3 }).promise).pid, a.pid)
  } finally { await owner.close() }
})

test('cancel rejects at once, tells the host, and keeps the host for the next job', async () => {
  const { owner, children } = session()
  try {
    const held = owner.run({ operation: 'hold' })
    held.cancel()
    await assert.rejects(held.promise, error => error.code === 'ABORT_ERR')
    assert.equal((await owner.run({ operation: 'echo', value: 'after' }).promise).value, 'after')
    assert.equal(children.length, 1)
  } finally { await owner.close() }
})

test('a host that ends rejects its jobs and the next job starts another host', async () => {
  const { owner, children } = session()
  try {
    const held = owner.run({ operation: 'hold' })
    await assert.rejects(owner.run({ operation: 'crash' }).promise, /VST host ended \(139\): native loader died/)
    await assert.rejects(held.promise, /VST host ended \(139\)/)
    const next = await owner.run({ operation: 'echo', value: 'again' }).promise
    assert.equal(children.length, 2)
    assert.equal(next.pid, children[1].pid)
  } finally { await owner.close() }
})

test('close ends an idle host through its input and kills one that still runs a job', async () => {
  const idle = session()
  await idle.owner.run({ operation: 'echo', value: 1 }).promise
  await idle.owner.close()
  assert.equal(idle.children[0].exitCode, 0)
  await assert.rejects(idle.owner.run({ operation: 'echo' }).promise, /session is closed/)

  const busy = session()
  const held = busy.owner.run({ operation: 'hold' })
  const rejected = assert.rejects(held.promise, error => error.code === 'ABORT_ERR')
  await busy.owner.close()
  await rejected
  assert.equal(busy.children[0].signalCode, 'SIGKILL')

  const loading = session()
  const stubborn = loading.owner.run({ operation: 'stubborn' })
  stubborn.cancel()
  await assert.rejects(stubborn.promise, error => error.code === 'ABORT_ERR')
  await loading.owner.close()
  assert.equal(loading.children[0].signalCode, 'SIGKILL')
})

test('a host that sent an invalid reply takes no new job while it is being killed', async () => {
  const children = []
  const owner = openVstSession({ spawnProcess() {
    const child = Object.assign(new EventEmitter(), { stdin: new PassThrough(), stdout: new PassThrough(), stderr: new PassThrough(),
      killed: null, kill(signal) { this.killed = signal } })
    children.push(child); return child
  } })
  const first = owner.run({ operation: 'echo' })
  const rejected = assert.rejects(first.promise, /invalid reply/)
  children[0].stdout.write('not json\n')
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(children[0].killed, 'SIGKILL')
  const second = owner.run({ operation: 'echo' })
  assert.equal(children.length, 2)
  children[0].emit('close', null, 'SIGKILL')
  await rejected
  children[1].emit('close', 0, null)
  await assert.rejects(second.promise, /VST host ended \(0\)/)
  await owner.close()
})
