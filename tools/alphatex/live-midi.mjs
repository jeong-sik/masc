import { spawn } from 'node:child_process'
import { createInterface } from 'node:readline'
import { mkdtemp, writeFile, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { fileURLToPath } from 'node:url'

export const liveMidiPath = fileURLToPath(new URL('./music-midi-live', import.meta.url))
function uid(value) {
  const number = Number(value)
  if (typeof value !== 'string' || !Number.isInteger(number) || number < -2147483648 || number > 2147483647 || String(number) !== value) throw new Error('Choose an exact MIDI source/destination UID')
  return value
}
export function liveMidiScope(value) {
  if (value?.kind === 'endpoint' && value.channels === undefined) return { kind: 'endpoint' }
  if (value?.kind !== 'channels' || !Array.isArray(value.channels) || !value.channels.length) throw new Error('Choose endpoint or MIDI group/channel scope')
  const channels = value.channels.map(({ group, channel }) => {
    if (![group, channel].every(n => Number.isInteger(n) && n >= 0 && n < 16)) throw new Error('Invalid MIDI group/channel scope')
    return { group, channel }
  }).sort((a, b) => a.group - b.group || a.channel - b.channel)
  if (new Set(channels.map(row => `${row.group}/${row.channel}`)).size !== channels.length) throw new Error('Duplicate MIDI group/channel')
  return { kind: 'channels', channels }
}
function claims(values) {
  if (!Array.isArray(values)) throw new Error('Missing backing MIDI ownership')
  return values.map(value => ({ destination: uid(value?.destination), scope: liveMidiScope(value?.scope) }))
}
export function liveMidiPlan(routes, reserved) {
  if (!Array.isArray(routes) || !routes.length) throw new Error('Select a live MIDI route')
  return { schemaVersion: 1, routes: routes.map(route => ({ source: uid(route?.source), destination: uid(route?.destination), scope: liveMidiScope(route?.scope) })), reserved: claims(reserved) }
}
// One read-only native parse uses the actual transport's compiled prefix scopes.
export async function backingMidiClaims({ path, format, signal, executable = liveMidiPath, spawnProcess = spawn }) {
  signal?.throwIfAborted()
  const child = spawnProcess(executable, ['reservations', '--file', path, '--format', format], { stdio: ['ignore', 'pipe', 'pipe'] })
  let output = '', detail = '', failure = null
  child.stdout.setEncoding('utf8').on('data', text => { output += text })
  child.stderr.setEncoding('utf8').on('data', text => { detail += text })
  const streamFailure = error => { failure ??= error; child.kill('SIGTERM') }
  child.stdout.once('error', streamFailure); child.stderr.once('error', streamFailure)
  const abort = () => child.kill('SIGTERM')
  signal?.addEventListener('abort', abort, { once: true })
  if (signal?.aborted) abort()
  try {
    await new Promise((resolve, reject) => {
      child.once('error', error => { failure ??= error })
      child.once('close', (code, exitSignal) => {
        if (signal?.aborted) reject(signal.reason)
        else if (failure) reject(failure)
        else if (code !== 0) reject(new Error(detail || `Backing ownership inspection failed: ${code ?? exitSignal}`))
        else resolve()
      })
    })
  } finally { signal?.removeEventListener('abort', abort) }
  const result = JSON.parse(output)
  if (result.kind !== 'reservations' || result.schemaVersion !== 1 || result.format !== format) throw new Error('Invalid backing MIDI ownership acknowledgement')
  return claims(result.reserved)
}
// Preparation and process closure belong to the caller's operation. Aborting
// preparation never opens a successor child; closure precedes private plan removal.
export async function openLiveMidi({ routes, reserved, signal, onEvent = () => {}, executable = liveMidiPath, spawnProcess = spawn, directory = tmpdir() }) {
  const plan = liveMidiPlan(routes, reserved)
  signal?.throwIfAborted()
  const temporary = await mkdtemp(join(directory, 'live-midi-'))
  try {
    const path = join(temporary, 'plan.json')
    await writeFile(path, JSON.stringify(plan), { flag: 'wx', mode: 0o600, signal })
    signal?.throwIfAborted()
    const child = spawnProcess(executable, ['--plan', path], { stdio: ['pipe', 'pipe', 'pipe'] })
    let failure = null, final = null, started = false, closed = false, stopping = false, detail = ''
    let resolveReady, rejectReady, resolveDone, rejectDone
    const ready = new Promise((resolve, reject) => { resolveReady = resolve; rejectReady = reject })
    const done = new Promise((resolve, reject) => { resolveDone = resolve; rejectDone = reject })
    ready.catch(() => {}); done.catch(() => {})
    function stop() {
      if (closed || stopping) return
      stopping = true
      if (!child.stdin.destroyed) child.stdin.end('{"kind":"stop"}\n')
    }
    function fail(error) { failure ??= error; rejectReady(error); if (!closed) child.kill('SIGTERM') }
    const abort = () => { stopping = true; rejectReady(signal.reason); child.kill('SIGTERM') }
    signal?.addEventListener('abort', abort, { once: true })
    const lines = createInterface({ input: child.stdout, crlfDelay: Infinity })
    lines.on('line', line => {
      if (failure || closed) return
      try {
        const event = JSON.parse(line)
        if (event.kind === 'error') {
          if (typeof event.message !== 'string' || !event.message) throw new Error('Malformed live MIDI error')
          fail(new Error(event.message)); onEvent(event); return
        }
        if (!['monitoring', 'stopped'].includes(event.kind) || final || event.deliveryProtocol !== 2
          || !Array.isArray(event.bindings) || event.bindings.length !== plan.routes.length
          || event.bindings.some((binding, index) => binding.port !== index || binding.source !== plan.routes[index].source
            || binding.device?.kind !== 'midi' || binding.device.protocol !== 2 || binding.device.id !== plan.routes[index].destination
            || typeof binding.device.name !== 'string' || JSON.stringify(liveMidiScope(binding.scope)) !== JSON.stringify(plan.routes[index].scope))
          || !Number.isInteger(event.pendingWords) || event.pendingWords < 0 || event.pendingWords > 65_536
          || ![event.forwardedMessages, event.filteredMessages].every(value => typeof value === 'string' && /^(0|[1-9][0-9]*)$/.test(value) && BigInt(value) <= 0xffffffffffffffffn)) throw new Error('Invalid selected live MIDI acknowledgement')
        if (event.kind === 'stopped') {
          if (event.success !== true || event.pendingWords !== 0) throw new Error('Live MIDI did not drain successfully')
          final = event
        } else { started = true }
        onEvent(event)
        if (event.kind === 'monitoring') resolveReady(event)
      } catch (error) { fail(error) }
    })
    lines.once('error', fail); child.stdout.once('error', fail); child.stderr.once('error', fail); child.once('error', fail)
    child.stdin.on('error', error => { if (error.code !== 'EPIPE' || !stopping) fail(error) })
    child.stderr.setEncoding('utf8').on('data', text => { detail += text })
    child.once('close', (code, exitSignal) => {
      closed = true; signal?.removeEventListener('abort', abort); lines.close()
      if (failure || code !== 0 || !final) {
        const error = failure ?? new Error(detail || `Live MIDI closed without finalization: ${code ?? exitSignal}`)
        rejectReady(error); rejectDone(error)
      } else {
        if (!started) rejectReady(new Error('Live MIDI stopped before admission'))
        resolveDone(final)
      }
    })
    if (signal?.aborted) abort()
    const completion = done.finally(() => rm(temporary, { recursive: true, force: true }))
    completion.catch(() => {})
    return { ready, completion, stop }
  } catch (error) { await rm(temporary, { recursive: true, force: true }); throw error }
}
