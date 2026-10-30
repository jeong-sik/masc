import { test } from 'node:test'
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { EventEmitter } from 'node:events'
import { PassThrough } from 'node:stream'
import { fileURLToPath } from 'node:url'
import { openVstSession } from '../vst-session.mjs'

const fixture = fileURLToPath(new URL('./fixtures/vst-serve.mjs', import.meta.url))
const replyBytes = 16 * 1024 * 1024
function controlledSession() {
  const children = []
  const owner = openVstSession({ spawnProcess() {
    const child = Object.assign(new EventEmitter(), {
      stdin: new PassThrough(), stdout: new PassThrough(), stderr: new PassThrough(),
      kills: [], kill(signal) { this.kills.push(signal) },
    })
    children.push(child)
    return child
  } })
  return { owner, children }
}
const completion = job => job.promise.then(value => ({ value }), error => ({ error }))
const reply = (id, result) => JSON.stringify({ id, ok: true, result }) + '\n'
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

test('closing while a failed host is still dying keeps its failure and waits for it to end', async () => {
  const children = []
  const owner = openVstSession({ spawnProcess() {
    const child = Object.assign(new EventEmitter(), { stdin: new PassThrough(), stdout: new PassThrough(), stderr: new PassThrough(),
      kill() {} })
    children.push(child); return child
  } })
  const job = owner.run({ operation: 'echo' })
  const rejected = assert.rejects(job.promise, /invalid reply/)
  children[0].stdout.write('not json\n')
  await new Promise(resolve => setImmediate(resolve))
  let closed = false
  const closing = owner.close().then(() => { closed = true })
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(closed, false)
  children[0].emit('close', null, 'SIGKILL')
  await rejected
  await closing
})

test('a failed host cannot turn a late completion into success or affect its successor', async () => {
  const { owner, children } = controlledSession()
  const first = completion(owner.run({ operation: 'echo' }))
  children[0].stdout.write('not json\n')
  const second = completion(owner.run({ operation: 'echo' }))
  children[0].stdout.write(reply(1, { late: true }))
  children[0].emit('close', null, 'SIGKILL')
  children[1].stdout.write(reply(2, { successor: true }))
  children[1].emit('close', 0, null)
  await owner.close()
  assert.match((await first).error?.message ?? '', /invalid reply/)
  assert.deepEqual((await second).value, { successor: true })
})

test('malformed envelopes and unknown job identities retire the host and reject all its jobs', async () => {
  for (const response of [null, [], {}, 42,
    { id: '1', ok: true, result: {} }, { id: 3, ok: true, result: {} },
    { id: 1, ok: true, result: [] }, { id: 1, ok: true, result: null },
    { id: 1, ok: 1, result: {} }, { id: 1, ok: false },
    { id: 1, ok: false, error: {} }, { id: 1, ok: false, cancelled: false },
    { id: 1, ok: false, cancelled: true, error: 'ambiguous' }]) {
    const { owner, children } = controlledSession()
    const first = completion(owner.run({ operation: 'echo' }))
    const second = completion(owner.run({ operation: 'echo' }))
    children[0].stdout.write(JSON.stringify(response) + '\n')
    children[0].emit('close', 0, null)
    await owner.close()
    assert.deepEqual(children[0].kills, ['SIGKILL'], JSON.stringify(response))
    assert.match((await first).error?.message ?? '', /invalid reply/)
    assert.match((await second).error?.message ?? '', /invalid reply/)
  }
})

test('a cancelled job may reply once, but a duplicate completion retires the host', async () => {
  const { owner, children } = controlledSession()
  const cancelled = owner.run({ operation: 'hold' }), first = completion(cancelled)
  cancelled.cancel()
  children[0].stdout.write(JSON.stringify({ id: 1, ok: false, cancelled: true }) + '\n')
  const second = completion(owner.run({ operation: 'echo' }))
  assert.equal(children.length, 1)
  children[0].stdout.write(reply(1, { duplicate: true }))
  children[0].stdout.write(reply(2, { late: true }))
  children[0].emit('close', null, 'SIGKILL')
  await owner.close()
  assert.equal((await first).error.code, 'ABORT_ERR')
  assert.deepEqual(children[0].kills, ['SIGKILL'])
  assert.match((await second).error?.message ?? '', /invalid reply/)
})

test('the response byte bound includes complete lines and incomplete fragments', async () => {
  const payload = reply(1, { data: 'x'.repeat(replyBytes) })
  for (const chunks of [[payload], [payload.slice(0, replyBytes), payload.slice(replyBytes)], ['x'.repeat(replyBytes + 1)]]) {
    const { owner, children } = controlledSession()
    const result = completion(owner.run({ operation: 'snapshot' }))
    for (const chunk of chunks) children[0].stdout.write(chunk)
    children[0].emit('close', null, 'SIGKILL')
    await owner.close()
    assert.match((await result).error?.message ?? '', /protocol memory bound/)
  }
})

test('a complete response exactly at the byte bound is accepted', async () => {
  const { owner, children } = controlledSession()
  const result = completion(owner.run({ operation: 'snapshot' }))
  const data = 'x'.repeat(replyBytes - Buffer.byteLength(reply(1, { data: '' })))
  const line = reply(1, { data })
  assert.equal(Buffer.byteLength(line), replyBytes)
  children[0].stdout.write(line)
  children[0].emit('close', 0, null)
  await owner.close()
  assert.equal((await result).value?.data.length, data.length)
})

test('several bounded replies in one chunk are not treated as one oversized response', async () => {
  const { owner, children } = controlledSession()
  const first = completion(owner.run({ operation: 'snapshot' }))
  const second = completion(owner.run({ operation: 'snapshot' }))
  const data = 'x'.repeat(replyBytes / 2)
  children[0].stdout.write(reply(1, { data }) + reply(2, { data }))
  children[0].emit('close', 0, null)
  await owner.close()
  assert.equal((await first).value?.data.length, data.length)
  assert.equal((await second).value?.data.length, data.length)
})

test('UTF-8 characters split across chunks retain their original value', async () => {
  const { owner, children } = controlledSession()
  const result = completion(owner.run({ operation: 'echo' }))
  const line = Buffer.from(reply(1, { data: '한🎹' })), start = line.indexOf(Buffer.from('한'))
  for (const part of [line.subarray(0, start + 1), line.subarray(start + 1, start + 5), line.subarray(start + 5)]) children[0].stdout.write(part)
  children[0].emit('close', 0, null)
  await owner.close()
  assert.deepEqual((await result).value, { data: '한🎹' })
})

test('a real child response is bounded by UTF-8 bytes, not decoded string length', async () => {
  const script = "process.stdin.once('data',()=>process.stdout.write(JSON.stringify({id:1,ok:true,result:{data:'한'.repeat(6*1024*1024)}})+'\\n'));process.stdin.on('end',()=>process.exit(0))"
  const owner = openVstSession({ command: process.execPath, args: ['-e', script, '--'] })
  try {
    const result = await completion(owner.run({ operation: 'snapshot' }))
    assert.match(result.error?.message ?? '', /protocol memory bound/)
  } finally { await owner.close() }
})

test('a real malformed child response retains its stderr in the failed job', async () => {
  const script = "process.stdin.once('data',()=>process.stderr.write('native loader context\\n',()=>process.stdout.write('not json\\n')));process.stdin.resume()"
  const owner = openVstSession({ command: process.execPath, args: ['-e', script, '--'] })
  try {
    const { error } = await completion(owner.run({ operation: 'snapshot' }))
    assert.match(error.message, /invalid reply/)
    assert.match(error.message, /native loader context/)
  } finally { await owner.close() }
})

test('failure diagnostics preserve the original error, code, cause and bounded stderr tail', async () => {
  const { owner, children } = controlledSession()
  const result = completion(owner.run({ operation: 'snapshot' }))
  const cause = new Error('original native cause')
  const failure = Object.assign(new Error('native host failed', { cause }), { code: 'ENOENT' })
  children[0].stderr.write('discarded prefix' + 'x'.repeat(64 * 1024))
  children[0].emit('error', failure)
  children[0].stderr.write('late diagnostic')
  children[0].stdout.write(reply(1, { late: true }))
  children[0].emit('close', null, 'SIGKILL')
  await owner.close()
  const { error } = await result
  assert.equal(error, failure)
  assert.equal(error.code, 'ENOENT')
  assert.equal(error.cause, cause)
  assert.equal(error.message, 'native host failed\n' + 'x'.repeat(64 * 1024 - 'late diagnostic'.length) + 'late diagnostic')
})

test('stderr does not change a successful completion', async () => {
  const { owner, children } = controlledSession()
  const result = completion(owner.run({ operation: 'echo' }))
  children[0].stderr.write('native warning\n')
  children[0].stdout.write(reply(1, { unchanged: true }))
  children[0].emit('close', 0, null)
  await owner.close()
  assert.deepEqual(await result, { value: { unchanged: true } })
})
