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
    let parts = [], bufferedBytes = 0, stderr = Buffer.alloc(0), failure = null, ended
    // Sent jobs without a reply yet, cancelled ones included: the host is busy.
    const owned = { child, outstanding: new Set(), ended: new Promise(resolve => { ended = resolve }) }
    hosts.add(owned)
    // A failed host takes no new job; the next run starts another.
    const fail = error => {
      if (failure) return
      failure = error
      parts = []; bufferedBytes = 0
      if (host === owned) host = null
      child.kill('SIGKILL')
    }
    function complete(line) {
      let reply
      const invalid = () => fail(new Error(`${label} host sent an invalid reply`))
      try { reply = JSON.parse(line) } catch { invalid(); return }
      if (!reply || typeof reply !== 'object' || Array.isArray(reply)
        || !Number.isSafeInteger(reply.id) || !owned.outstanding.has(reply.id)) { invalid(); return }
      const fields = Object.keys(reply)
      const exactly = (...names) => fields.length === names.length && names.every(name => Object.hasOwn(reply, name))
      const success = reply.ok === true && exactly('id', 'ok', 'result')
        && reply.result !== null && typeof reply.result === 'object' && !Array.isArray(reply.result)
      const cancelled = reply.ok === false && exactly('id', 'ok', 'cancelled') && reply.cancelled === true
      const rejected = reply.ok === false && exactly('id', 'ok', 'error') && typeof reply.error === 'string'
      if (!success && !cancelled && !rejected) { invalid(); return }
      owned.outstanding.delete(reply.id)
      const job = pending.get(reply.id)
      // Only a known cancelled job's single valid reply may be dropped.
      if (!job) return
      pending.delete(reply.id)
      if (success) job.resolve(reply.result)
      else if (cancelled) job.reject(cancelledError(label))
      else job.reject(new Error(reply.error))
    }
    child.stdout.on('data', chunk => {
      if (failure) return
      // Keep the pipe's bytes until a complete line arrives, including when a
      // UTF-8 character crosses chunks. The bound includes its newline.
      let offset = 0
      while (offset < chunk.length) {
        const end = chunk.indexOf(10, offset)
        const part = chunk.subarray(offset, end < 0 ? chunk.length : end + 1)
        if (bufferedBytes + part.length > replyBytes) {
          fail(new Error(`${label} reply exceeds its protocol memory bound`)); return
        }
        parts.push(part); bufferedBytes += part.length
        if (end < 0) return
        const line = Buffer.concat(parts, bufferedBytes).toString('utf8')
        parts = []; bufferedBytes = 0
        complete(line)
        if (failure) return
        offset = end + 1
      }
    })
    child.stderr.on('data', bytes => { stderr = Buffer.concat([stderr, bytes]).subarray(-diagnosticBytes) })
    // EPIPE is settled by the process's error/close receipt below.
    child.stdin.on('error', () => {})
    child.once('error', fail)
    child.once('close', (code, signal) => {
      if (host === owned) host = null
      hosts.delete(owned)
      // Enrich the retained failure only at close, after stderr drains. Keep
      // its identity, code and cause rather than replacing the terminal error.
      if (failure && stderr.length) failure.message += '\n' + stderr.toString('utf8')
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
