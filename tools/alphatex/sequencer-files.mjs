import { readFile, writeFile, rename, unlink, mkdir } from 'node:fs/promises'
import { dirname, resolve } from 'node:path'
import { createHash, randomUUID } from 'node:crypto'
import JZZ from 'jzz'
import midiFiles from 'jzz-midi-smf'
import { validateProject, sequenceEvents, PPQ } from './sequencer-project.mjs'
midiFiles(JZZ)
const hash = data => createHash('sha256').update(data).digest('hex')

export async function loadProject(path) {
  const data = await readFile(path)
  return { project: validateProject(JSON.parse(data)), revision: hash(data), path: resolve(path) }
}
// Saves refuse a document changed by another editor. The lock coordinates our
// writers; a new document is published with wx so unrelated files survive.
export async function saveProject(path, project, revision = null) {
  validateProject(project)
  await mkdir(dirname(resolve(path)), { recursive: true, mode: 0o700 })
  const lock = `${path}.lock`, temporary = `${path}.${randomUUID()}.tmp`
  await writeFile(lock, '', { flag: 'wx', mode: 0o600 })
  const data = JSON.stringify(project, null, 2) + '\n'
  try {
    if (revision === null) await writeFile(path, data, { flag: 'wx', mode: 0o600 })
    else {
      if (hash(await readFile(path)) !== revision) throw new Error('Project changed on disk; use save-as to retain your edits')
      await writeFile(temporary, data, { flag: 'wx', mode: 0o600 })
      await rename(temporary, path)
    }
    return hash(data)
  } finally {
    await unlink(temporary).catch(error => { if (error.code !== 'ENOENT') throw error })
    await unlink(lock)
  }
}
export function projectMidi(project, options) {
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
        : event.kind === 'on' ? JZZ.MIDI.noteOn(event.channel, event.pitch, event.velocity)
          : JZZ.MIDI.noteOff(event.channel, event.pitch)
      output.add(event.tick, message)
    }
    output.add(ticks, JZZ.MIDI.smfEndOfTrack()); file.push(output)
  }
  return file.toUint8Array()
}
