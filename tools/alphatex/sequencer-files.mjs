import { readFile, writeFile, open, rename, link, unlink, mkdir, mkdtemp } from 'node:fs/promises'
import { basename, dirname, join, resolve } from 'node:path'
import { createHash } from 'node:crypto'
import JZZ from 'jzz'
import midiFiles from 'jzz-midi-smf'
import { validateProject, sequenceEvents, PPQ } from './sequencer-project.mjs'
import { validateArrangement } from './arrangement.mjs'
import { validateMidiSource, exportMidiSource } from './midi-source.mjs'
midiFiles(JZZ)
const hash = data => createHash('sha256').update(data).digest('hex')
const validateDocument = document => {
  if (document?.kind === 'arrangement') return validateArrangement(document)
  if (document?.kind === 'midi-source') return validateMidiSource(document)
  if (document?.kind !== undefined) throw new Error('Unsupported musical document')
  return validateProject(document)
}

export async function loadProject(path, { signal } = {}) {
  const data = await readFile(path, { signal })
  return { project: validateDocument(JSON.parse(data)), revision: hash(data), path: resolve(path) }
}
async function syncDirectory(path) {
  const directory = await open(path, 'r')
  try { await directory.sync() } finally { await directory.close() }
}
// The lock coordinates our writers, not other editors. Claim the current inode
// into retained history before checking it, then publish only into an empty path.
// Never unlink history: an external writer may still hold and change that inode.
export async function saveProject(path, project, revision = null) {
  validateDocument(project)
  path = resolve(path)
  const parent = dirname(path), lock = `${path}.lock`
  await mkdir(parent, { recursive: true, mode: 0o700 })
  await writeFile(lock, '', { flag: 'wx', mode: 0o600 })
  const data = JSON.stringify(project, null, 2) + '\n'
  let candidate, previous, candidateCreated = false, claimed = false, failure = null
  const retainedError = error => {
    const retained = candidateCreated ? ` Local candidate retained at ${candidate}.${claimed ? ` Claimed inode retained at ${previous}.` : ''}` : ''
    const result = new Error(`${error.message}${retained}`, { cause: error })
    result.code = error.code
    return result
  }
  try {
    const history = await mkdtemp(join(parent, `.${basename(path)}.save-`))
    candidate = join(history, 'local.json'); previous = join(history, 'previous.json')
    const file = await open(candidate, 'wx', 0o600)
    candidateCreated = true
    try { await file.writeFile(data); await file.sync() } finally { await file.close() }
    // Publication must use a different inode. A write through the live pathname
    // must not mutate the retained local candidate, even immediately after link.
    const publication = join(history, 'published.json'), output = await open(publication, 'wx', 0o600)
    try { await output.writeFile(data); await output.sync() } finally { await output.close() }
    await syncDirectory(history); await syncDirectory(parent)
    if (revision !== null) {
      await rename(path, previous); claimed = true
      await syncDirectory(history); await syncDirectory(parent)
      if (hash(await readFile(previous)) !== revision) throw new Error('Project changed on disk; use save-as to retain your edits')
    }
    // link is exclusive: an external editor recreating path during the claim
    // wins that pathname, while both its file and our candidate remain intact.
    await link(publication, path)
    await syncDirectory(parent)
  } catch (error) {
    if (claimed) {
      try { await link(previous, path); await syncDirectory(parent) }
      catch (restore) {
        if (restore.code !== 'EEXIST') error = new Error(`${error.message}; could not restore ${path}: ${restore.message}`, { cause: error })
      }
    }
    failure = retainedError(error)
  } finally {
    try { await unlink(lock) } catch (error) { failure ??= retainedError(error) }
  }
  if (failure) throw failure
  return hash(data)
}
export function projectMidi(project, options) {
  if (project?.kind === 'arrangement') throw new Error('Arrangement MIDI export requires explicit clip-state reconstruction')
  if (project?.kind === 'midi-source') {
    if (options?.loop) throw new Error('MIDI source clip export requires explicit arrangement boundaries')
    return exportMidiSource(project)
  }
  const { events, ticks } = sequenceEvents(project, options)
  const file = new JZZ.MIDI.SMF(1, PPQ)
  const conductor = new JZZ.MIDI.SMF.MTrk()
  conductor.add(0, JZZ.MIDI.smfBPM(project.tempo)).add(0, JZZ.MIDI.smfTimeSignature(...project.meter))
    .add(ticks, JZZ.MIDI.smfEndOfTrack())
  file.push(conductor)
  for (const track of project.tracks) {
    const output = new JZZ.MIDI.SMF.MTrk()
    output.add(0, JZZ.MIDI.smfSeqName(track.name))
    for (const event of events.filter(event => event.track === track.id)) {
      const message = event.kind === 'program' ? JZZ.MIDI.program(event.channel, event.program)
        : event.kind === 'control' ? JZZ.MIDI.control(event.channel, event.controller, event.value)
          : event.kind === 'on' ? JZZ.MIDI.noteOn(event.channel, event.pitch, event.velocity)
            : JZZ.MIDI.noteOff(event.channel, event.pitch)
      output.add(event.tick, message)
    }
    output.add(ticks, JZZ.MIDI.smfEndOfTrack()); file.push(output)
  }
  return file.toUint8Array()
}
