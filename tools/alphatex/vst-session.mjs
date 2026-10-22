import { spawn } from 'node:child_process'
import { vstHostPath } from './vst-host.mjs'

// Protocol memory bounds shared with nativeJob: one reply line, and the tail
// of native diagnostics reported when the host ends.
const replyBytes = 16 * 1024 * 1024
const diagnosticBytes = 64 * 1024

const cancelledError = label => {
  const error = new Error(`${label} job cancelled`)
  error.code = 'ABORT_ERR'
  return error
}

// One `host --serve` process for a viewer session. The host keeps the
// instrument its latest snapshot or render loaded, so playing the same sound
// again does not load the plug-in again. run() has nativeJob's
// { promise, cancel } contract; the host runs jobs one at a time. A host that
// ends rejects the jobs it owned, and the next job starts a new one.
export function openVstSession({ command = vstHostPath, args = [], spawnProcess = spawn, label = 'VST' } = {}) {
  let host = null, nextId = 0, closed = false
  // Every started host until it closes, including one already being killed.
  const pending = new Map(), hosts = new Set()
  function start() {
    const child = spawnProcess(command, [...args, '--serve'], { stdio: ['pipe', 'pipe', 'pipe'] })
    let text = '', stderr = Buffer.alloc(0), failure = null, ended
    // Sent jobs without a reply yet, cancelled ones included: the host is busy.
    const owned = { child, outstanding: new Set(), ended: new Promise(resolve => { ended = resolve }) }
    hosts.add(owned)
    // A failed host takes no new job; the next run starts another.
    const fail = error => { failure ??= error; if (host === owned) host = null; child.kill('SIGKILL') }
    child.stdout.setEncoding('utf8')
    child.stdout.on('data', chunk => {
      text += chunk
      let end
      while ((end = text.indexOf('\n')) >= 0) {
        const line = text.slice(0, end)
        text = text.slice(end + 1)
        let reply
        try { reply = JSON.parse(line) } catch { fail(new Error(`${label} host sent an invalid reply`)); return }
        owned.outstanding.delete(reply?.id)
        const job = pending.get(reply?.id)
        // A cancelled job was already rejected; its late reply is dropped.
        if (!job || job.owner !== owned) continue
        pending.delete(reply.id)
        if (reply.ok === true && reply.result && typeof reply.result === 'object') job.resolve(reply.result)
        else if (reply.ok === false && reply.cancelled === true) job.reject(cancelledError(label))
        else if (reply.ok === false && typeof reply.error === 'string') job.reject(new Error(reply.error))
        else job.reject(new Error(`Invalid ${label} host completion`))
      }
      if (text.length > replyBytes) fail(new Error(`${label} reply exceeds its protocol memory bound`))
    })
    child.stderr.on('data', bytes => { stderr = Buffer.concat([stderr, bytes]).subarray(-diagnosticBytes) })
    // EPIPE is settled by the process's error/close receipt below.
    child.stdin.on('error', () => {})
    child.once('error', error => { failure ??= error })
    child.once('close', (code, signal) => {
      if (host === owned) host = null
      hosts.delete(owned)
      const error = failure ?? new Error(`${label} host ended (${signal ?? code}): ${stderr.toString('utf8')}`)
      for (const [id, job] of pending) {
        if (job.owner === owned) { pending.delete(id); job.reject(error) }
      }
      ended()
    })
    return owned
  }
  function send(owned, value) {
    if (owned.child.stdin.writable) owned.child.stdin.write(JSON.stringify(value) + '\n')
  }
  return {
    run(request) {
      const id = ++nextId
      let settle
      const promise = new Promise((resolve, reject) => { settle = { resolve, reject } })
      if (closed) { settle.reject(new Error(`${label} session is closed`)); return { promise, cancel() {} } }
      host ??= start()
      pending.set(id, { ...settle, owner: host })
      host.outstanding.add(id)
      send(host, { id, job: request })
      return { promise, cancel() {
        const job = pending.get(id)
        if (!job) return
        pending.delete(id)
        send(job.owner, { cancel: id })
        job.reject(cancelledError(label))
      } }
    },
    // A host still running a job when the viewer closes, even a cancelled one
    // that cannot stop between blocks, is killed as a one-shot job is on
    // cancel; an idle host is closed through its input.
    async close() {
      closed = true
      const owned = host
      // Jobs of a host that is already failing keep the failure it ends with.
      for (const [id, job] of pending) {
        if (job.owner === owned) { pending.delete(id); job.reject(cancelledError(label)) }
      }
      if (owned?.outstanding.size) owned.child.kill('SIGKILL')
      else owned?.child.stdin.end()
      await Promise.all([...hosts].map(value => value.ended))
    },
  }
}
