import { mkdtemp, writeFile, rm } from 'node:fs/promises'
import { join, dirname, resolve } from 'node:path'
import { tmpdir } from 'node:os'
import { randomUUID } from 'node:crypto'
import { Worker } from 'node:worker_threads'
import { emitKeypressEvents } from 'node:readline'
import { arrangementEditor, arrangementAction, arrangementCommand, arrangementImported, selectedRegion } from './arrangement-editor.mjs'
import { loadArrangement, verifyArrangementAssets, saveArrangement } from './arrangement-files.mjs'
import { saveProject } from './sequencer-files.mjs'
import { safeText } from './terminal.mjs'
import { openPlayback } from './playback.mjs'

const help = [
  ':import-wave /path/take.wav     :import-midi /path/song.mid',
  ':place asset-1 0               full source at quarter-note beat 0',
  ':place asset-2 4 2             MIDI format-2 pattern 2 at beat 4',
  ':region asset-1 0 1200 4800 2   asset, beat, native offset/extent, repeats',
  ':region asset-2 4 0 2002 1 2    optional final pattern starts at 1',
  ':trim 2400 4800                whole WAV frames or original MIDI ticks',
  ':move 8    :repeat 4    :duplicate 16    :remove',
  ':lane-add wave Bass    :lane-add midi Keys    :lane 2',
  ':region-lane 2    :lane-name Bass    :region-name Verse    :lane-remove',
  ':asset asset-1    :select region-1    :cursor 4    :grid 0.25',
  ':tempo 120    :meter 3 4    :title Experiment    :mute    :solo',
  ':save    :save-as /path/song.json    :undo    :redo',
  'Arrows: cursor/regions; Shift+Left/Right: move region; Tab: lane; a: asset',
  'Enter: place selected asset; d: duplicate at cursor; x/Delete: remove',
  'u/y: undo/redo; m/o: mute/solo; s: save; q/Esc: save and return',
  'Regions run at original speed. Project tempo moves positions without warping.',
  'Space: WAV play/pause/resume; :stop; :seek BEAT; :output DEVICE_UID',
  'MIDI region state chase, whole-arrangement looping and overdub remain under development.',
]

export async function viewArrangement({ path, loaded, initialDocument, root = resolve('music-projects'), embedded = false, signal, output, midiOutput } = {}) {
  if (!process.stdin.isTTY || !process.stdout.isTTY) throw new Error('Arrangement editor requires a terminal')
  if ((path || loaded) && initialDocument) throw new Error('Open a saved arrangement or a new one, one at a time')
  if (signal?.aborted) return
  if (loaded) await verifyArrangementAssets(loaded.project, dirname(loaded.path), { signal })
  else loaded = path ? await loadArrangement(path, { signal }) : null
  if (signal?.aborted) return
  let editor = arrangementEditor(initialDocument ?? loaded?.project), saved = loaded?.project
  path = loaded?.path ?? join(root, `arrangement-${randomUUID()}.json`)
  path = resolve(path)
  if (!loaded) await verifyArrangementAssets(editor.project, dirname(path), { signal })
  if (signal?.aborted) return
  let sourceRoot = dirname(path), revision = loaded?.revision ?? null
  let accepting = true, closed = false, task = Promise.resolve(), prompt = null, status = 'Import a WAV or MIDI source with :help', showHelp = false
  let pendingDraw = null, sequence = 0, workerFailure = null, recovery = null, terminatingWorker = false
  const failedSavePaths = new Set()
  const directory = await mkdtemp(join(tmpdir(), 'masc-arrangement-play-'))
  let worker
  try { worker = new Worker(new URL('./arrangement-worker.mjs', import.meta.url)) }
  catch (error) { await rm(directory, { recursive: true, force: true }); throw error }
  const jobs = new Map(), players = new Map(), preparations = new Set(), wasRaw = process.stdin.isRaw
  let transport = { kind: 'stopped' }, generation = 0, preparing = null, selectedOutput = output, selectedMidi = midiOutput
  let complete
  const done = new Promise(resolve => { complete = resolve })
  function finish() {
    if (!accepting) return
    accepting = false
    stop()
    for (const handle of players.keys()) handle.terminate()
    if (!workerFailure) worker.postMessage({ kind: 'cancel' })
    complete()
  }
  function request(value, issued) {
    if (workerFailure) return Promise.reject(workerFailure)
    const id = ++sequence
    return new Promise((resolve, reject) => {
      jobs.set(id, { resolve, reject })
      issued?.(id)
      try { worker.postMessage({ ...value, id }) }
      catch (error) { jobs.delete(id); reject(error) }
    })
  }
  function fail(error) {
    stop()
    workerFailure = error
    for (const job of jobs.values()) job.reject(error)
    jobs.clear(); status = error.message; draw()
  }
  worker.on('message', message => {
    const job = jobs.get(message.id)
    if (!job) return
    jobs.delete(message.id)
    if (message.ok) job.resolve(message.result)
    else { const error = new Error(message.error); error.name = message.cancelled ? 'AbortError' : 'Error'; job.reject(error) }
  })
  worker.on('error', fail)
  worker.on('exit', code => { if (!terminatingWorker) fail(new Error(`Arrangement worker exited ${code}`)) })
  function stop() {
    generation++
    if (preparing !== null && !workerFailure) worker.postMessage({ kind: 'cancel', request: preparing })
    preparing = null
    transport.handle?.stop()
    transport = { kind: 'stopped' }
    draw()
  }
  function adopt(next) {
    if (next.project !== editor.project) stop()
    editor = next
  }
  function play() {
    if (!accepting) return
    if (transport.kind === 'playing') { transport.handle.pause(); return }
    if (transport.kind === 'paused') { transport.handle.resume(); return }
    if (transport.kind === 'preparing' || transport.kind === 'starting') { stop(); return }
    if (selectedMidi !== undefined) throw new Error('Arrangement MIDI playback is not connected; select an audio output with :output UID')
    const expected = ++generation, project = editor.project, output = selectedOutput
    transport = { kind: 'preparing' }; status = 'Preparing WAV sources…'
    const prepared = request({ kind: 'prepare-wave', project, sourceRoot, directory }, id => { preparing = id })
    const preparation = (async () => {
      let result
      try {
        result = await prepared
        if (generation === expected) preparing = null
        await Promise.allSettled([...players.values()])
        if (!accepting || generation !== expected) return
        transport = { kind: 'starting' }
        const handle = openPlayback({ path: result.path, format: result.format, output,
          onEvent(event) {
            if (!accepting || generation !== expected) return
            if (event.kind === 'error') { status = event.message; return }
            transport = { ...transport, kind: event.kind, event }
            draw()
          } })
        transport = { ...transport, handle }
        const completion = handle.completion.then(event => {
          if (generation === expected) { transport = { kind: 'stopped', event }; status = 'Playback stopped'; draw() }
        }, error => {
          if (generation === expected) { transport = { kind: 'stopped' }; status = error.message; draw() }
        }).finally(() => { players.delete(handle) })
        players.set(handle, completion)
        await completion
      } catch (error) {
        if (generation === expected) { preparing = null; transport = { kind: 'stopped' }; status = error.message; draw() }
      } finally {
        if (result) await rm(dirname(result.path), { recursive: true, force: true })
      }
    })()
    preparations.add(preparation)
    preparation.catch(error => { if (accepting) { status = error.message; draw() } }).finally(() => preparations.delete(preparation))
    draw()
  }
  async function save(target = path) {
    target = resolve(target)
    const project = editor.project, nextRoot = dirname(target)
    const retained = new Map()
    if (nextRoot !== sourceRoot) for (const document of [project, ...editor.undo, ...editor.redo]) {
      for (const asset of document.assets) if (asset.kind === 'wave') retained.set(asset.file, asset)
    }
    const retainedAssets = [...retained.values()].map((asset, index) => ({ ...asset, id: `retained-${index}` }))
    let nextRevision
    try { nextRevision = await request({ kind: 'save', path: target, project, revision: target === path ? revision : null, sourceRoot, retainedAssets }) }
    catch (error) { failedSavePaths.add(target); throw error }
    failedSavePaths.delete(target)
    path = target; sourceRoot = nextRoot; revision = nextRevision; saved = project; status = `Saved ${path}`
  }
  async function effect(value) {
    switch (value.kind) {
      case 'help': showHelp = !showHelp; break
      case 'play': play(); break
      case 'stop': stop(); break
      case 'seek': {
        if (!['playing', 'paused'].includes(transport.kind)) throw new Error('Playback is not ready')
        transport.handle.seek(value.tick / editor.project.ppq * 60 / editor.project.tempo)
        break
      }
      case 'output': stop(); selectedOutput = value.path; selectedMidi = undefined; status = 'Audio output selected'; break
      case 'save': await save(); break
      case 'save-as': if (accepting) await save(value.path); break
      case 'import-wave': case 'import-midi': {
        if (!accepting) return
        status = 'Importing source…'; draw()
        const result = await request({ ...value, project: editor.project, projectPath: path })
        if (accepting) { adopt(arrangementImported(editor, result)); status = `Imported ${result.asset}; Enter places it at the cursor` }
        break
      }
      default: throw new Error('Unknown arrangement effect')
    }
  }
  function enqueue(action) {
    task = task.then(action).catch(error => { status = error.name === 'AbortError' ? 'Import or verification cancelled' : error.message }).finally(draw)
  }
  function keypress(text, key = {}) {
    if (!accepting || closed) return
    if (key.ctrl && key.name === 'c') { finish(); return }
    if (prompt !== null) {
      if (key.name === 'escape') prompt = null
      else if (key.name === 'backspace') prompt = [...prompt].slice(0, -1).join('')
      else if (key.name === 'return') {
        const line = prompt; prompt = null
        enqueue(async () => { const result = arrangementCommand(editor, line); adopt(result.editor); if (result.effect) await effect(result.effect); else status = 'Edited' })
      } else if (text && !key.ctrl && !key.meta) prompt += safeText(text)
      draw(); return
    }
    if (['escape', 'q'].includes(key.name)) { finish(); return }
    if (text === ':') { prompt = ''; draw(); return }
    if (text === '?') { showHelp = !showHelp; draw(); return }
    enqueue(async () => {
      let action
      switch (key.name) {
        case 's': await save(); return
        case 'a': action = { kind: 'asset' }; break
        case 'tab': action = { kind: 'lane' }; break
        case 'return': action = { kind: 'place' }; break
        case 'delete': case 'backspace': case 'x': action = { kind: 'remove' }; break
        case 'd': action = { kind: 'duplicate' }; break
        case 'u': action = { kind: 'undo' }; break
        case 'y': action = { kind: 'redo' }; break
        case 'm': action = { kind: 'mute' }; break
        case 'o': action = { kind: 'solo' }; break
        case 'left': case 'right': action = { kind: key.shift ? 'move' : 'cursor', ticks: editor.step * (key.name === 'left' ? -1 : 1) }; break
        case 'up': case 'down': action = { kind: 'region', direction: key.name === 'down' ? 1 : -1 }; break
        case 'space': play(); return
        default: return
      }
      adopt(arrangementAction(editor, action)); status = 'Edited'
    })
  }
  function fit(text) {
    let used = 0, result = ''
    for (const char of safeText(text)) {
      const code = char.codePointAt(0), width = code >= 0x1100 && (code <= 0x115f || code >= 0x2e80) ? 2 : 1
      if (used + width >= (process.stdout.columns || 80)) break
      result += char; used += width
    }
    return result
  }
  function draw() {
    if (!closed && !pendingDraw) pendingDraw = setImmediate(() => { pendingDraw = null; drawNow() })
  }
  function drawNow() {
    if (closed) return
    const project = editor.project, clip = selectedRegion(editor), asset = project.assets.find(asset => asset.id === editor.asset)
    const rows = process.stdout.rows || 24, width = Math.max(1, (process.stdout.columns || 80) - 24)
    const lines = [`Arrangement · ${project.title}${project !== saved ? ' *' : ''} · ${project.tempo} BPM · ${project.meter.join('/')}`,
      `Cursor ${editor.tick / project.ppq} beats · grid ${editor.step / project.ppq} · ${status}`,
      `WAV ${transport.kind} · ${(transport.event?.currentTime ?? 0).toFixed(2)} s · ${transport.event?.device.name ?? selectedOutput ?? 'default output'}`]
    if (showHelp) lines.push(...help)
    else {
      const left = Math.floor(editor.tick / editor.step / width) * width * editor.step
      const selected = project.lanes.findIndex(lane => lane.id === editor.lane), capacity = Math.max(1, rows - 10)
      const start = Math.max(0, selected - capacity + 1)
      lines.push(`Window starts at ${left / project.ppq} quarter-note beats; each cell ${editor.step / project.ppq} beats`)
      for (const [index, lane] of project.lanes.slice(start, start + capacity).entries()) {
        const cells = Array(width).fill('·')
        for (const region of editor.schedule.filter(clip => clip.lane === lane.id)) {
          const endTick = region.endSeconds * project.tempo / 60 * project.ppq
          const from = Math.max(0, Math.floor((region.position - left) / editor.step)), to = Math.min(width, Math.max(from + 1, Math.ceil((endTick - left) / editor.step)))
          if (endTick < left || region.position >= left + width * editor.step) continue
          for (let cell = from; cell < to; cell++) cells[cell] = region.id === editor.region ? '#' : lane.kind === 'wave' ? 'W' : 'M'
        }
        lines.push(`${lane.id === editor.lane ? '>' : ' '} ${index + start + 1} ${lane.name.slice(0, 12).padEnd(12)} ${lane.muted ? 'm' : '-'}${lane.solo ? 's' : '-'} ${cells.join('')}`)
      }
      if (!project.lanes.length) lines.push('Import a source, then Enter or :place to add its first lane and region.')
      lines.push(clip ? `${clip.id} · ${clip.name} · beat ${clip.position / project.ppq} · source ${clip.offset}+${clip.extent} · repeat ${clip.repeat}${clip.pattern === undefined ? '' : ` · pattern ${clip.pattern + 1}`}` : 'Up/Down selects a region on the current lane.')
      lines.push(asset ? `${asset.id} · ${asset.name} · ${asset.kind === 'wave' ? `${asset.metadata.frames} frames / ${asset.metadata.sampleRate} Hz / ${asset.metadata.channels} channels` : 'original MIDI ticks; format-2 patterns require explicit selection'}` : 'No imported asset. :import-wave FILE or :import-midi FILE')
      lines.push(`Library ${project.assets.length} sources · ${project.clips.length} regions · a cycles sources · ? help`, path)
    }
    let output = '\x1b[H'
    for (let row = 1; row <= rows; row++) output += `\x1b[${row};1H\x1b[2K`
    lines.slice(0, Math.max(0, rows - 2)).forEach((line, index) => { output += `\x1b[${index + 1};1H${fit(line)}` })
    output += `\x1b[${Math.max(1, rows - 1)};1H${fit(prompt === null ? 'arrows:cursor/regions  Shift+←→:move  Tab:lane  a:asset  Enter:place  u/y:undo/redo' : `:${prompt}`)}`
    output += `\x1b[${rows};1H${fit('s:save  d:duplicate  x:remove  m/o:mute/solo  :commands  ?:help  q:save/back')}`
    process.stdout.write(output)
  }
  const onEnd = () => finish(), onSignal = () => finish(), onAbort = () => finish(), onResize = () => draw()
  const ticker = setInterval(() => {
    if (transport.kind === 'playing') { try { transport.handle.status() } catch (error) { stop(); status = error.message; draw() } }
  }, 100)
  async function retainRecovery() {
    const directory = await mkdtemp(join(tmpdir(), 'masc-arrangement-recovery-'))
    recovery = join(directory, 'project.json')
    try { await saveArrangement(recovery, editor.project, null, { sourceRoot }) }
    catch (error) {
      // Preserve the edited document even when a missing/corrupt external source
      // prevents a portable recovery. Record that distinction beside the draft.
      recovery = join(directory, 'draft.json')
      await saveProject(recovery, editor.project)
      await writeFile(join(directory, 'sources.json'), JSON.stringify({ sourceRoot, assetsCopied: false, error: error.message }, null, 2), { flag: 'wx', mode: 0o600 })
    }
  }
  try {
    emitKeypressEvents(process.stdin)
    process.stdin.setRawMode(true); process.stdin.resume()
    process.stdin.on('keypress', keypress); process.stdin.on('end', onEnd)
    process.stdout.on('resize', onResize); signal?.addEventListener('abort', onAbort, { once: true })
    for (const name of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(name, onSignal)
    if (!embedded) process.stdout.write('\x1b[?1049h\x1b[?25l\x1b[2J')
    draw(); if (signal?.aborted) finish(); await done
  } finally {
    accepting = false; closed = true
    clearInterval(ticker)
    stop()
    if (pendingDraw) clearImmediate(pendingDraw)
    process.stdin.off('keypress', keypress); process.stdin.off('end', onEnd)
    process.stdout.off('resize', onResize); signal?.removeEventListener('abort', onAbort)
    for (const name of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.off(name, onSignal)
    try {
      await task
      await Promise.allSettled([...preparations])
      await Promise.allSettled([...players.values()])
      if (editor.project !== saved) {
        if (failedSavePaths.has(path)) await retainRecovery()
        else { try { await save() } catch { await retainRecovery() } }
      }
    } finally {
      try { terminatingWorker = true; await worker.terminate(); await rm(directory, { recursive: true, force: true }) }
      finally {
        if (!embedded) { process.stdout.write('\x1b[?25h\x1b[?1049l'); process.stdin.setRawMode(wasRaw ?? false); process.stdin.pause() }
        if (recovery) process.stderr.write(`Arrangement edits retained at ${recovery}\n`)
      }
    }
  }
}
