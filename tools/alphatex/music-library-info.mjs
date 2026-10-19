import { basename } from 'node:path'
import { Worker } from 'node:worker_threads'
import { loadProject } from './sequencer-files.mjs'
import { midiSourceInfo, midiSourcePattern } from './midi-source.mjs'
import { arrangementClipTime } from './arrangement.mjs'
import { readCapture } from './session-data.mjs'

// Read only the selected item. Project values describe the validated document,
// not an assertion that every external asset or output device can play it.
export async function readMusicInfo(entry, { signal } = {}) {
  if (entry.kind === 'session') {
    const timeline = await readCapture(entry.path, { signal })
    return { kind: 'session', title: basename(entry.path), state: timeline.manifest.state,
      failure: timeline.manifest.failure ?? null, durationSeconds: timeline.duration,
      sampleRate: timeline.sampleRate, channels: timeline.channels,
      frames: String(timeline.frames), midiPackets: String(timeline.packets),
      midiTracks: timeline.midi.size }
  }
  if (entry.kind !== 'project') throw new Error('Select a saved project or recorded take')
  const { project, revision } = await loadProject(entry.path, { signal })
  signal?.throwIfAborted()
  if (project.kind === 'midi-source') {
    const info = midiSourceInfo(project)
    const patterns = Array.from({ length: info.patterns }, (_, pattern) => {
      const performance = midiSourcePattern(project, { pattern })
      return { index: pattern, durationSeconds: performance.seconds, notes: performance.notes.length }
    })
    return { kind: 'midi-source', title: project.name, revision, format: info.format,
      timing: info.timing, tracks: info.tracks.length, patterns }
  }
  if (project.kind === 'arrangement') {
    return { kind: 'arrangement', title: project.title, revision, tempo: project.tempo, meter: project.meter,
      durationSeconds: project.clips.reduce((end, clip) => Math.max(end, arrangementClipTime(project, clip).endSeconds), 0),
      lanes: project.lanes.length, clips: project.clips.length,
      assets: project.assets.map(asset => ({ kind: asset.kind, name: asset.name })) }
  }
  return { kind: 'phrase', title: project.title, revision, tempo: project.tempo, meter: project.meter,
    quarterNotes: project.length / project.ppq, durationSeconds: project.length / project.ppq * 60 / project.tempo,
    tracks: project.tracks.map(track => ({ name: track.name, notes: track.notes.length,
      channel: track.channel, program: track.program, muted: track.muted, solo: track.solo })) }
}

export function inspectMusicEntry(entry) {
  const worker = new Worker(new URL('./music-library-worker.mjs', import.meta.url), { workerData: entry })
  let cancelled = false, settled = false, terminate = null
  const completion = new Promise(resolve => { worker.once('exit', resolve) })
  const promise = new Promise((resolve, reject) => {
    const fail = error => { settled = true; reject(error) }
    worker.once('error', fail)
    worker.once('message', message => {
      if (cancelled) return
      settled = true
      if (message.ok === true) resolve(message.info)
      else reject(new Error(message.error))
    })
    worker.once('exit', code => {
      if (settled) return
      const error = new Error(cancelled ? 'Music inspection cancelled' : `Music inspection ended without a result (${code})`)
      if (cancelled) error.code = 'ABORT_ERR'
      fail(error)
    })
  })
  return { promise, completion, cancel() {
    cancelled = true
    terminate ??= worker.terminate()
    return terminate
  } }
}
