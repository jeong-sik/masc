import { spawn } from 'node:child_process'
import { mkdir, readFile, rename, writeFile, unlink, copyFile, mkdtemp, rm } from 'node:fs/promises'
import { constants } from 'node:fs'
import { pathToFileURL } from 'node:url'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { randomUUID, createHash } from 'node:crypto'
import { validateVstSelection as selection } from './project-sound.mjs'

// A protocol memory bound, not a phrase/job time limit. Native diagnostics
// are on a separate stream and only their tail is retained for a failed job.
const replyBytes = 16 * 1024 * 1024
const diagnosticBytes = 64 * 1024

export function nativeJob(request, { command = 'masc-vst-host', args = [] } = {}) {
  const child = spawn(command, args, { stdio: ['pipe', 'pipe', 'pipe'] })
  let cancelled = false
  let overflow = false
  let stdout = Buffer.alloc(0)
  let stderr = Buffer.alloc(0)
  const promise = new Promise((resolve, reject) => {
    child.stdout.on('data', bytes => {
      if (stdout.length + bytes.length > replyBytes) { overflow = true; child.kill('SIGKILL') }
      else stdout = Buffer.concat([stdout, bytes])
    })
    child.stderr.on('data', bytes => { stderr = Buffer.concat([stderr, bytes]).subarray(-diagnosticBytes) })
    // EPIPE is settled by the process's error/close receipt below. It must not
    // become an unhandled exception if a native loader crashes before reading.
    child.stdin.on('error', () => {})
    child.once('error', reject)
    child.once('close', (code, signal) => {
      if (cancelled) { const error = new Error('VST job cancelled'); error.code = 'ABORT_ERR'; reject(error); return }
      if (overflow) { reject(new Error('VST reply exceeds its protocol memory bound')); return }
      let reply
      try { reply = JSON.parse(stdout.toString('utf8')) }
      catch { reject(new Error(`VST host ended without a valid reply (${signal ?? code}): ${stderr.toString('utf8')}`)); return }
      if (reply?.ok === false && typeof reply.error === 'string') { reject(new Error(reply.error)); return }
      if (code !== 0 || reply?.ok !== true || !reply.result || typeof reply.result !== 'object') {
        reject(new Error(`Invalid VST host completion (${signal ?? code})`)); return
      }
      resolve(reply.result)
    })
  })
  child.stdin.end(JSON.stringify(request))
  return { promise, cancel() { cancelled = true; child.kill('SIGKILL') } }
}

export function defaultStateDirectory() {
  return process.platform === 'darwin'
    ? join(homedir(), 'Library', 'Application Support', 'masc', 'vst')
    : join(process.env.XDG_STATE_HOME || join(homedir(), '.local', 'state'), 'masc', 'vst')
}

export async function atomicJson(path, value) {
  const temporary = `${path}.${randomUUID()}.tmp`
  try {
    await writeFile(temporary, JSON.stringify(value, null, 2) + '\n', { mode: 0o600, flag: 'wx' })
    await rename(temporary, path)
  } finally {
    await unlink(temporary).catch(error => { if (error.code !== 'ENOENT') throw error })
  }
}

export async function loadSelection(directory) {
  try { return selection(JSON.parse(await readFile(join(directory, 'selection.json'), 'utf8'))) }
  catch (error) { if (error.code === 'ENOENT') return null; throw error }
}

export async function saveSelection(directory, value) {
  await mkdir(directory, { recursive: true, mode: 0o700 })
  await atomicJson(join(directory, 'selection.json'), selection(value))
}

export function presetDirectory(directory, pluginPath, pluginName) {
  const id = createHash('sha256').update(JSON.stringify([pluginPath, pluginName])).digest('hex')
  return join(directory, 'presets', id)
}

export async function retainRender(directory, result, midiPath) {
  const root = join(directory, 'renders')
  await mkdir(root, { recursive: true, mode: 0o700 })
  const folder = await mkdtemp(join(root, 'render-'))
  try {
    const output_path = join(folder, 'audio.wav')
    const midi_path = join(folder, 'phrase.mid')
    await copyFile(result.output_path, output_path, constants.COPYFILE_EXCL)
    await copyFile(midiPath, midi_path, constants.COPYFILE_EXCL)
    const retained = { ...result, output_path, midi_path }
    await atomicJson(join(folder, 'render.json'), retained)
    return { result: retained, discard: () => rm(folder, { recursive: true, force: true }) }
  } catch (error) {
    await rm(folder, { recursive: true, force: true })
    throw error
  }
}

export function snapshotWriter(directory) {
  const incarnation = randomUUID()
  let sequence = 0
  let writing = Promise.resolve()
  return fields => {
    const cursor = String(++sequence)
    const snapshot = { source_id: 'vst-phrase', incarnation, cursor,
      complete: true, detail: 'Latest local phrase state; not a complete playback history or a Lane action receipt',
      observations: [{ id: `${incarnation}:${cursor}`, kind: 'vst_phrase',
        observed_at: Date.now() / 1000, actor: null,
        evidence: fields.render ? [
          { uri: pathToFileURL(fields.render.output_path).href, sha256: fields.render.wav_sha256 },
          { uri: pathToFileURL(fields.render.midi_path).href, sha256: fields.render.midi_sha256 },
        ] : [], fields }] }
    // Preserve order when selection/playback events arrive in one event-loop
    // turn. A failed write is reported to its owner; later writes may recover.
    writing = writing.catch(() => {}).then(async () => {
      await mkdir(directory, { recursive: true, mode: 0o700 })
      await atomicJson(join(directory, 'snapshot.json'), snapshot)
    })
    return writing
  }
}
