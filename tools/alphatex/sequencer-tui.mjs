import { mkdtemp, rm, writeFile, copyFile } from 'node:fs/promises'
import { constants } from 'node:fs'
import { join, resolve } from 'node:path'
import { tmpdir } from 'node:os'
import { randomUUID } from 'node:crypto'
import { emitKeypressEvents } from 'node:readline'
import { spawn } from 'node:child_process'
import { Worker } from 'node:worker_threads'
import { Note } from 'tonal'
import { newEditor, editorCommand, editorAction, selectedNote } from './sequencer-editor.mjs'
import { harmonyAt, PPQ } from './sequencer-project.mjs'
import { loadProject, saveProject, projectMidi } from './sequencer-files.mjs'
import { safeText } from './terminal.mjs'

const help = [
  'Arrow keys: time/pitch; Shift+arrows: move note; Enter/x: insert/remove note',
  'Tab: track; n: new track; m: mute; o: solo; u/y: undo/redo',
  '[/]: halve/double note length; +/-: velocity; g: grid; l: loop; Space: play/stop',
  's: save; r: recording; q/Esc: save and return; : opens command input',
  'All positions and lengths below use quarter-note beats starting at 0.',
  ':note C4 0 1 96              pitch, beat, duration, optional velocity',
  ':chord Cmaj7 0 4 drop2 4 0  symbol, beat, duration, mode, octave, inversion',
  ':progression 0 4 rootless Dm7 G7 Cmaj7',
  ':tempo 120    :length 32    :meter 3 4    :loop 4 12',
  ':transpose -12    :quantize 0.25    :duplicate 8   (selected track)',
  ':track-add Bass    :track 2    :program 33    :rename Bass',
  ':cursor 4 C3    :title My phrase    :undo    :redo    :mute    :solo',
  ':save-as /path/song.json    :export /path/song.mid    :wave /path/song.wav',
  'Close, drop2 and rootless voicings use Tonal. Chord labels are candidates.',
  'Preview uses a SoundFont. Repeated WAV preview restarts the player each pass.',
]

export async function viewSequencer({ path, root = resolve('music-projects'), embedded = false, signal,
  soundfontPath, sessionRoot, input, midi } = {}) {
  if (!process.stdin.isTTY || !process.stdout.isTTY) throw new Error('Sequencer requires a terminal')
  const loaded = path ? await loadProject(path) : null
  if (signal?.aborted) return
  let editor = newEditor(loaded?.project), revision = loaded?.revision ?? null
  path = loaded?.path ?? join(root, `phrase-${randomUUID()}.json`)
  let saved = loaded?.project, status = 'Enter a note or :help', prompt = null, showHelp = false
  let loop = false, closed = false, suspended = false, task = Promise.resolve(), sessionTask = null
  const sessionAbort = new AbortController()
  const directory = await mkdtemp(join(tmpdir(), 'masc-sequencer-'))
  const worker = new Worker(new URL('./sequencer-worker.mjs', import.meta.url))
  const jobs = new Map(), players = new Map()
  let jobNumber = 0, generation = 0, transport = { kind: 'stopped' }, workerFailure = null
  const wasRaw = process.stdin.isRaw
  let finish
  const done = new Promise(resolve => { finish = resolve })
  const dirty = () => editor.project !== saved
  function fit(text) {
    let used = 0, result = ''
    for (const char of safeText(text)) {
      const code = char.codePointAt(0), width = code >= 0x1100 && (code <= 0x115f || code >= 0x2e80) ? 2 : 1
      if (used + width >= (process.stdout.columns || 80)) break
      result += char; used += width
    }
    return result
  }
  function playTick() {
    if (transport.kind !== 'playing') return editor.tick
    const start = loop ? editor.project.loop.start : 0
    return Math.min(editor.project.length - 1, start + (performance.now() - transport.since) / 60000 * editor.project.tempo * PPQ)
  }
  function draw() {
    if (closed || suspended) return
    const rows = process.stdout.rows || 24, cols = Math.max(1, (process.stdout.columns || 80) - 8)
    const project = editor.project, track = project.tracks[editor.track], current = selectedNote(editor)
    const at = harmonyAt(project, editor.tick)
    const lines = [
      `${project.title}${dirty() ? ' *' : ''} · ${project.tempo} BPM · ${project.meter.join('/')} · ${project.length / PPQ} beats · ${transport.kind}${loop ? ' · LOOP' : ''}`,
      `Track ${editor.track + 1}/${project.tracks.length}: ${track.name} · ch ${track.channel + 1} · program ${track.program}${track.muted ? ' · MUTED' : ''}${track.solo ? ' · SOLO' : ''} · ${track.notes.length} notes`,
      `Cursor ${editor.tick / PPQ} · ${Note.fromMidi(editor.pitch)} · grid ${editor.step / PPQ} · length ${(current?.duration ?? editor.duration) / PPQ} · velocity ${current?.velocity ?? editor.velocity}`,
      `Chord candidates: ${at.candidates.join(' / ') || '—'} · ${at.notes.join(' ')} · ${status}`,
    ]
    if (showHelp) lines.push(...help)
    else {
      const first = Math.floor(editor.tick / (editor.step * cols)) * editor.step * cols
      const barTicks = project.meter[0] * PPQ * 4 / project.meter[1]
      const ruler = Array.from({ length: cols }, (_, x) => {
        const tick = first + x * editor.step
        return tick >= project.length ? ' ' : tick % barTicks === 0 ? '|' : tick % PPQ === 0 ? '+' : '·'
      })
      lines.push(`       ${ruler.join('')}`, `       beats ${first / PPQ} → ${Math.min(project.length, first + cols * editor.step) / PPQ}`)
      const height = Math.max(1, rows - 10), high = Math.min(127, Math.max(height - 1, editor.pitch + Math.floor(height / 2)))
      for (let y = 0; y < height; y++) {
        const pitch = high - y
        if (pitch < 0) break
        const cells = Array.from({ length: cols }, (_, x) => first + x * editor.step >= project.length ? ' ' : pitch % 12 === 0 ? '─' : '·')
        for (const note of track.notes) {
          if (note.pitch !== pitch) continue
          const left = Math.max(0, Math.floor((note.start - first) / editor.step))
          const right = Math.min(cols - 1, Math.ceil((note.start + note.duration - first) / editor.step) - 1)
          for (let x = left; x <= right; x++) cells[x] = first + x * editor.step <= note.start ? '█' : '━'
        }
        const cursor = Math.floor((editor.tick - first) / editor.step)
        if (pitch === editor.pitch) cells[cursor] = current ? '◆' : '◇'
        lines.push(`${Note.fromMidi(pitch).padStart(5)}  ${cells.join('')}`)
      }
      lines.push(`Playhead ${(playTick() / PPQ).toFixed(2)} · loop ${project.loop.start / PPQ}–${project.loop.end / PPQ} · ${path}`)
    }
    let output = '\x1b[H'
    for (let row = 1; row <= rows; row++) output += `\x1b[${row};1H\x1b[2K`
    lines.slice(0, rows - 2).forEach((line, row) => { output += `\x1b[${row + 1};1H${fit(line)}` })
    output += `\x1b[${rows - 1};1H${fit(prompt === null ? 'Space:play  Enter:note  arrows:cursor  Tab:track  u/y:undo/redo  :commands  ?:help' : `:${prompt}`)}`
    output += `\x1b[${rows};1H${fit('s:save  l:loop  r:recording  q:save/back  n:new track  m:mute  o:solo')}`
    process.stdout.write(output)
  }
  function stop() {
    generation++
    if (transport.cancel) Atomics.store(transport.cancel, 0, 1)
    transport.child?.kill('SIGTERM')
    transport = { kind: 'stopped' }
  }
  function render(snapshot, options = {}) {
    if (workerFailure) throw new Error(workerFailure)
    const id = ++jobNumber, cancel = new Int32Array(new SharedArrayBuffer(4)), path = join(directory, `${id}.wav`)
    const promise = new Promise((resolve, reject) => { jobs.set(id, { resolve, reject, cancel }) })
    worker.postMessage({ id, path, project: snapshot, cancel: cancel.buffer, options: { ...options, soundfontPath } })
    return { promise, cancel }
  }
  function startPlayer(wave, id) {
    if (closed || id !== generation) return
    const child = spawn(process.platform === 'darwin' ? 'afplay' : 'ffplay',
      process.platform === 'darwin' ? [wave.path] : ['-nodisp', '-autoexit', '-loglevel', 'error', wave.path],
      { stdio: ['ignore', 'ignore', 'pipe'] })
    let detail = ''
    child.stderr.setEncoding('utf8').on('data', text => { detail += text })
    child.once('error', error => { if (id === generation) { status = error.message; transport = { kind: 'stopped' }; draw() } })
    players.set(child, new Promise(resolve => child.once('close', code => {
      players.delete(child)
      if (!closed && id === generation) {
        if (code === 0 && loop) startPlayer(wave, id)
        else { transport = { kind: 'stopped' }; status = code === 0 ? 'Playback finished' : detail || `Player exited ${code}`; draw() }
      }
      resolve()
    })))
    transport = { kind: 'playing', child, since: performance.now() }
    status = 'SoundFont preview'; draw()
  }
  function play() {
    if (transport.kind !== 'stopped') { stop(); draw(); return }
    const id = ++generation, result = render(editor.project, { loop })
    transport = { kind: 'rendering', cancel: result.cancel }
    result.promise.then(wave => startPlayer(wave, id), error => {
      if (!closed && id === generation) { transport = { kind: 'stopped' }; status = error.message; draw() }
    })
    draw()
  }
  async function save(target = path) {
    const project = editor.project
    const nextRevision = await saveProject(target, project, target === path ? revision : null)
    path = resolve(target); revision = nextRevision; saved = project; status = `Saved ${path}`
  }
  async function record() {
    stop(); suspended = true; process.stdin.off('keypress', keypress)
    try {
      const { viewSession } = await import('./music-session.mjs')
      if (!closed) await viewSession({ root: sessionRoot, input, midi, embedded: true, signal: sessionAbort.signal })
    } finally {
      suspended = false
      if (!closed) { process.stdin.on('keypress', keypress); draw() }
    }
  }
  async function effect(value) {
    switch (value.kind) {
      case 'save': await save(); break
      case 'save-as': await save(value.path); break
      case 'export': await writeFile(value.path, projectMidi(editor.project), { flag: 'wx', mode: 0o600 }); status = `Exported ${value.path}`; break
      case 'wave': {
        const job = render(editor.project)
        const wave = await job.promise
        if (!closed) { await copyFile(wave.path, value.path, constants.COPYFILE_EXCL); status = `Exported ${value.path}` }
        break
      }
      case 'play': play(); break
      case 'stop': stop(); break
      case 'help': showHelp = !showHelp; break
      case 'record': if (!sessionTask) sessionTask = record().catch(error => { status = error.message }).finally(() => { sessionTask = null }); break
    }
  }
  async function keypress(text, key = {}) {
    if (closed || suspended) return
    if (key.ctrl && key.name === 'c') { finish(); return }
    if (prompt !== null) {
      if (key.name === 'escape') prompt = null
      else if (key.name === 'backspace') prompt = [...prompt].slice(0, -1).join('')
      else if (key.name === 'return') {
        const line = prompt; prompt = null
        task = task.then(async () => {
          if (closed) return
          const result = editorCommand(editor, line)
          if (result.editor.project !== editor.project) stop()
          editor = result.editor
          if (result.effect) await effect(result.effect)
          else status = 'Edited'
        }).catch(error => { status = error.message }).finally(draw)
      } else if (text && !key.ctrl && !key.meta) prompt += safeText(text)
      draw(); return
    }
    if (['q', 'escape'].includes(key.name)) { finish(); return }
    if (text === ':') { prompt = ''; draw(); return }
    if (text === '?') { showHelp = !showHelp; draw(); return }
    if (key.name === 'n') { prompt = 'track-add '; draw(); return }
    task = task.then(async () => {
      if (closed) return
      const original = editor.project
      switch (key.name) {
        case 'space': play(); break
        case 's': await save(); break
        case 'r': await effect({ kind: 'record' }); break
        case 'l': stop(); loop = !loop; break
        case 'tab': editor = editorAction(editor, { kind: 'track' }); break
        case 'return': case 'x': editor = editorAction(editor, { kind: 'toggle-note' }); break
        case 'delete': case 'backspace': editor = editorAction(editor, { kind: 'remove' }); break
        case 'u': editor = editorAction(editor, { kind: 'undo' }); break
        case 'y': editor = editorAction(editor, { kind: 'redo' }); break
        case 'm': editor = editorAction(editor, { kind: 'mute' }); break
        case 'o': editor = editorAction(editor, { kind: 'solo' }); break
        case 'g': editor = editorAction(editor, { kind: 'grid' }); break
        case 'left': case 'right': editor = editorAction(editor, { kind: key.shift ? 'move-note' : 'move', ticks: editor.step * (key.name === 'left' ? -1 : 1) }); break
        case 'up': case 'down': editor = editorAction(editor, { kind: key.shift ? 'move-note' : 'move', pitches: key.name === 'up' ? 1 : -1 }); break
        default:
          if (text === '[' || text === ']') editor = editorAction(editor, { kind: 'duration', value: (selectedNote(editor)?.duration ?? editor.duration) * (text === '[' ? 0.5 : 2) })
          else if (['+', '=', '-'].includes(text)) editor = editorAction(editor, { kind: 'velocity', value: (selectedNote(editor)?.velocity ?? editor.velocity) + (text === '-' ? -1 : 1) })
      }
      if (original !== editor.project) { stop(); status = 'Edited' }
    }).catch(error => { status = error.message }).finally(draw)
  }
  worker.on('message', message => {
    const job = jobs.get(message.id)
    if (!job) return
    jobs.delete(message.id)
    if (message.ok) job.resolve(message.result)
    else job.reject(new Error(message.error))
  })
  function failWorker(error) {
    workerFailure = error.message
    for (const job of jobs.values()) job.reject(error)
    jobs.clear()
    status = error.message; draw()
  }
  worker.on('error', failWorker)
  worker.on('exit', code => { if (!closed) failWorker(new Error(`Audio worker exited ${code}`)) })
  const onEnd = () => finish(), onSignal = () => finish(), onAbort = () => finish(), onResize = () => draw()
  emitKeypressEvents(process.stdin)
  process.stdin.setRawMode(true); process.stdin.resume()
  process.stdin.on('keypress', keypress); process.stdin.on('end', onEnd)
  process.stdout.on('resize', onResize)
  signal?.addEventListener('abort', onAbort, { once: true })
  for (const name of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(name, onSignal)
  const timer = setInterval(() => { if (transport.kind === 'playing') draw() }, 100)
  if (!embedded) process.stdout.write('\x1b[?1049h\x1b[?25l\x1b[2J')
  let recovery = null
  try { draw(); if (signal?.aborted) finish(); await done }
  finally {
    closed = true; stop(); clearInterval(timer); sessionAbort.abort()
    process.stdin.off('keypress', keypress); process.stdin.off('end', onEnd)
    process.stdout.off('resize', onResize); signal?.removeEventListener('abort', onAbort)
    for (const name of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.off(name, onSignal)
    for (const child of players.keys()) child.kill('SIGKILL')
    for (const job of jobs.values()) { Atomics.store(job.cancel, 0, 1); job.reject(new Error('Sequencer closed')) }
    jobs.clear()
    try {
      await Promise.allSettled([task, sessionTask, worker.terminate(), ...players.values()])
      if (dirty()) {
        try { await save() }
        catch {
          const recoveryDirectory = await mkdtemp(join(tmpdir(), 'masc-phrase-recovery-'))
          recovery = join(recoveryDirectory, 'project.json')
          await saveProject(recovery, editor.project)
        }
      }
    } finally {
      await rm(directory, { recursive: true, force: true })
      if (!embedded) {
        process.stdout.write('\x1b[?25h\x1b[?1049l')
        process.stdin.setRawMode(wasRaw ?? false); process.stdin.pause()
      }
      if (recovery) process.stderr.write(`Phrase edits retained at ${recovery}\n`)
    }
  }
}
