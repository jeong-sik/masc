import { viewSession } from './music-session.mjs'
import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises'
import { join, dirname, resolve } from 'node:path'
import { tmpdir } from 'node:os'
import { randomUUID } from 'node:crypto'
import { Worker } from 'node:worker_threads'
import { emitKeypressEvents } from 'node:readline'
import { arrangementRoute, selectArrangementRoute, arrangementPlaybackRequest } from './arrangement-playback.mjs'
import { arrangementEditor, arrangementAction, arrangementCommand, arrangementImported, selectedRegion } from './arrangement-editor.mjs'
import { loadArrangement, verifyArrangementAssets, saveArrangement } from './arrangement-files.mjs'
import { saveProject } from './sequencer-files.mjs'
import { safeText } from './terminal.mjs'
import { openPlayback } from './playback.mjs'
import { devices, record } from './capture.mjs'
import { recordingEpoch } from './arrangement-recording.mjs'

const help = [
  ':import-wave /path/take.wav     :import-midi /path/song.mid',
  ':import-take /path/session      :open-take [ASSET] (WAV + raw UMP)',
  ':place asset-1 0               full source at quarter-note beat 0',
  ':place asset-2 4 2             MIDI format-2 pattern 2 at beat 4',
  ':region asset-1 0 1200 4800 2   asset, beat, native offset/extent, repeats',
  ':region asset-2 4 0 2002 1 2    optional final pattern starts at 1',
  ':capture-region asset-3 4 0.5 2 3  beat, source start/duration seconds, repeats',
  ':trim-time 0.5 2              captured region source start/duration seconds',
  ':trim 2400 4800                WAV frames, MIDI ticks or captured host ticks',
  ':move 8    :repeat 4    :duplicate 16    :remove',
  ':lane-add wave Bass    :lane-add midi Keys    :lane 2',
  ':region-lane 2    :lane-name Bass    :region-name Verse    :lane-remove',
  ':asset asset-1    :select region-1    :cursor 4    :grid 0.25',
  ':tempo 120    :meter 3 4    :title Experiment    :mute    :solo',
  ':save    :save-as /path/song.json    :undo    :redo',
  'Arrows: cursor/regions; Shift+Left/Right: move region; Tab: lane; a: asset',
  'Enter: place selected asset; d: duplicate at cursor; x/Delete: remove',
  'Captured asset: Enter opens source; :place adds its region.',
  'u/y: undo/redo; m/o: mute/solo; s: save; q/Esc: save and return',
  'Regions run at original speed. Project tempo moves positions without warping.',
  'Space: play/pause/resume; :stop; :seek BEAT; :output AUDIO_UID',
  ':midi-output MIDI_UID    :midi-port asset-1 PORT MIDI_UID',
  ':midi-source asset-2 SOURCE_ID MIDI_UID overrides one captured input.',
  ':mixed-output AUDIO_UID enables audio plus the selected MIDI routes.',
  ':play-audio explicitly auditions WAV, including captured regions and silent gaps.',
  ':inputs lists audio/MIDI inputs; :input AUDIO_UID; :midi-input all|none|UID',
  ':record starts simultaneous WAV + raw MIDI against playing backing; :record-stop',
  'Transport/edits finalize recording first. Whole looping and monitoring remain unfinished.',
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
  let accepting = true, closed = false, suspended = false, takeAbort = null, takeTask = null, task = Promise.resolve(), prompt = null, status = 'Import a WAV or MIDI source with :help', showHelp = false
  let pendingDraw = null, sequence = 0, workerFailure = null, recovery = null, terminatingWorker = false
  const failedSavePaths = new Set()
  const directory = await mkdtemp(join(tmpdir(), 'masc-arrangement-play-'))
  let worker
  try { worker = new Worker(new URL('./arrangement-worker.mjs', import.meta.url)) }
  catch (error) { await rm(directory, { recursive: true, force: true }); throw error }
  const jobs = new Map(), players = new Map(), preparations = new Set(), wasRaw = process.stdin.isRaw
  let transport = { kind: 'stopped' }, generation = 0, preparing = null, route = arrangementRoute({ output, midiOutput })
  let recording = null, input = null, midiInput = 'all', transportPending = false, inputDevices = null, discoveryTicket = 0
  const discovery = new AbortController()
  let complete
  const done = new Promise(resolve => { complete = resolve })
  function finish() {
    if (!accepting) return
    accepting = false
    takeAbort?.abort()
    discovery.abort()
    // Recording owns finalization and source import through child close. Keep
    // the backing epoch continuous until that boundary, even on view exit.
    const release = () => {
      stop()
      for (const handle of players.keys()) handle.terminate()
      if (!workerFailure) worker.postMessage({ kind: 'cancel' })
      complete()
    }
    if (recording) settleRecording().finally(release)
    else release()
  }
  async function settleRecording() {
    const owned = recording
    if (!owned) return
    owned.phase = 'finalizing'; owned.controller.abort(); owned.handle?.stop(); draw()
    await owned.completion
  }
  function startRecording() {
    if (recording) throw new Error('A recording is already opening or finalizing')
    if (!input) throw new Error('Select :input AUDIO_UID first; :inputs lists devices')
    if (transport.kind !== 'playing' || transportPending) throw new Error('Start arrangement playback before recording')
    const project = editor.project, projectPath = path, selectedInput = input, selectedMidi = midiInput, backing = transport.handle
    const owned = { controller: new AbortController(), phase: 'opening', directory: join(dirname(path), 'recordings', randomUUID()), handle: null, epoch: null, failure: null, generation }
    recording = owned
    const expected = generation
    owned.completion = (async () => {
      try {
        await mkdir(dirname(owned.directory), { recursive: true, mode: 0o700 })
        if (owned.controller.signal.aborted || !accepting || generation !== expected) return
        // This correlated barrier follows earlier native pause/seek commands.
        // An old unsolicited status cannot supply the admission epoch.
        const epoch = recordingEpoch(await backing.recordingEpoch({ signal: owned.controller.signal }))
        if (owned.controller.signal.aborted || !accepting || generation !== expected || transport.handle !== backing || editor.project !== project || path !== projectPath) return
        owned.epoch = epoch
        owned.handle = record({ input: selectedInput, midi: selectedMidi, directory: owned.directory, onEvent(event) {
          if (event.kind === 'recording') owned.phase = owned.controller.signal.aborted ? 'finalizing' : 'recording'
          if (event.kind === 'error') status = event.message
          draw()
        } })
        await owned.handle.completion
        owned.phase = 'attaching'; draw()
        // Import is separate from recording success. A failed/late import must
        // preserve the complete finalized source and its recovery coordinates.
        await writeFile(join(owned.directory, 'arrangement-recording.json'), JSON.stringify({ projectPath, epoch }, null, 2), { flag: 'wx', mode: 0o600 })
        if (owned.failure) throw owned.failure
        if (editor.project !== project || path !== projectPath) throw new Error('Project changed before recording attachment')
        const result = await request({ kind: 'attach-recording', project, projectPath, path: owned.directory, epoch })
        if (owned.failure) throw owned.failure
        if (editor.project !== project || path !== projectPath) throw new Error('Project changed during recording attachment')
        await writeFile(join(owned.directory, 'alignment.json'), JSON.stringify(result.alignment, null, 2), { flag: 'wx', mode: 0o600 })
        if (owned.failure) throw owned.failure
        if (recording !== owned || editor.project !== project || path !== projectPath) throw new Error('Recording attachment authority changed')
        recording = null
        editor = arrangementImported(editor, result)
        status = 'Recorded WAV and raw MIDI attached; original take retained'
      } catch (error) {
        if (!owned.handle && owned.controller.signal.aborted && !owned.failure) status = 'Recording cancelled before opening inputs'
        else {
          status = `${error.message}; take retained at ${owned.directory}`
          process.stderr.write(`Recording recovery: ${owned.directory} (${error.message})\n`)
        }
      } finally { if (recording === owned) recording = null; draw() }
    })()
    draw()
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
    if (recording) recording.failure = error
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
    recording?.controller.abort(); recording?.handle?.stop()
    generation++; transportPending = false
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
  function play(audioOnly = false) {
    if (!accepting) return
    if (transport.kind === 'playing') { transportPending = true; transport.handle.pause(); return }
    if (transport.kind === 'paused') { transportPending = true; transport.handle.resume(); return }
    if (transport.kind === 'preparing' || transport.kind === 'starting') { stop(); return }
    const selection = audioOnly ? { kind: 'prepare-audio', output: route.output } : arrangementPlaybackRequest(editor.project, route)
    const expected = ++generation, project = editor.project, output = selection.output
    transport = { kind: 'preparing' }; status = 'Preparing arrangement sources…'
    const prepared = request({ ...selection, project, sourceRoot, directory }, id => { preparing = id })
    const preparation = (async () => {
      let result
      try {
        result = await prepared
        if (generation === expected) preparing = null
        await Promise.allSettled([...players.values()])
        if (!accepting || generation !== expected) return
        transport = { kind: 'starting' }
        const handle = openPlayback({ path: result.path, format: result.format, output, midiOutput: result.midiOutput, midiBindings: result.bindings,
          onEvent(event) {
            if (generation !== expected) return
            const captured = recording?.generation === expected ? recording : null
            if (event.kind === 'error') {
              if (captured) captured.failure = new Error(event.message)
              captured?.controller.abort(); captured?.handle?.stop(); status = event.message; return
            }
            if (event.kind === 'stopped' && captured) {
              if (captured.epoch) captured.epoch.duration = Math.min(captured.epoch.duration, event.currentTime)
              captured.controller.abort(); captured.handle?.stop()
            }
            if (!accepting) return
            transportPending = false
            transport = { ...transport, kind: event.kind, event }
            draw()
          } })
        transport = { ...transport, handle }
        const completion = handle.completion.then(event => {
          if (recording?.generation === expected) { recording.controller.abort(); recording.handle?.stop() }
          if (generation === expected) { transport = { kind: 'stopped', event }; status = 'Playback stopped'; draw() }
        }, error => {
          if (recording?.generation === expected) { recording.failure = error; recording.controller.abort(); recording.handle?.stop() }
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
  function openTake(asset) {
    if (!accepting || takeTask) return
    stop()
    const expected = ++generation
    transport = { kind: 'preparing' }; status = 'Preparing captured source…'
    const prepared = request({ kind: 'prepare-take', project: editor.project, asset, sourceRoot, directory }, id => { preparing = id })
    const preparation = (async () => {
      let result, controller
      try {
        result = await prepared
        if (generation === expected) preparing = null
        await Promise.allSettled([...players.values()])
        if (!accepting || generation !== expected) return
        transport = { kind: 'stopped' }
        controller = new AbortController(); takeAbort = controller; takeTask = preparation
        suspended = true; process.stdin.off('keypress', keypress)
        await viewSession({ directory: result.directory, root: join(sourceRoot, 'recordings'),
          exportRoot: join(sourceRoot, 'exports'), output: route.output, midiOutput: route.midiOutput, embedded: true, signal: controller.signal })
      } catch (error) {
        if (generation === expected) { preparing = null; transport = { kind: 'stopped' }; status = error.message }
      } finally {
        if (controller && takeAbort === controller) {
          takeAbort = null; suspended = false
          if (accepting && !closed) process.stdin.on('keypress', keypress)
        }
        try { if (result) await rm(result.directory, { recursive: true, force: true }) }
        finally {
          if (takeTask === preparation) takeTask = null
          draw()
        }
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
      for (const asset of document.assets) if (asset.kind === 'wave' || asset.kind === 'capture') retained.set(asset.file ?? JSON.stringify(asset.parts), asset)
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
      case 'inputs': {
        const ticket = ++discoveryTicket
        if (inputDevices !== null) { inputDevices = null; break }
        inputDevices = []; status = 'Discovering input devices; :inputs returns to arrangement'
        const pending = devices({ signal: discovery.signal }).then(found => {
          if (!accepting || discovery.signal.aborted || ticket !== discoveryTicket) return
          inputDevices = [...found.audio.filter(device => device.inputs > 0).map(device => `Audio ${device.id}: ${device.name}`),
            ...found.midi.map(device => `MIDI ${device.id}: ${device.name}`)]
          status = 'Select :input AUDIO_UID and :midi-input all|none|MIDI_UID; :inputs returns'
          draw()
        }, error => { if (!discovery.signal.aborted) { status = error.message; draw() } })
        preparations.add(pending); pending.finally(() => preparations.delete(pending)); break
      }
      case 'input': input = value.input; status = 'Audio input selected'; break
      case 'midi-input': midiInput = value.input; status = 'MIDI input selected'; break
      case 'record': startRecording(); break
      case 'record-stop': await settleRecording(); break
      case 'open-take': openTake(value.asset); break
      case 'help': inputDevices = null; discoveryTicket++; showHelp = !showHelp; break
      case 'play': play(); break
      case 'play-audio':
        if (['playing', 'paused', 'preparing', 'starting'].includes(transport.kind)) throw new Error('Stop current playback before choosing audio-only audition')
        play(true); break
      case 'stop': stop(); break
      case 'seek': {
        if (!['playing', 'paused'].includes(transport.kind)) throw new Error('Playback is not ready')
        transportPending = true
        transport.handle.seek(value.tick / editor.project.ppq * 60 / editor.project.tempo)
        break
      }
      case 'midi-output': case 'midi-port': case 'midi-source': case 'output': case 'mixed-output':
        stop(); route = selectArrangementRoute(route, value); status = 'Playback outputs selected'; break
      case 'save': await save(); break
      case 'save-as': if (accepting) await save(value.path); break
      case 'import-wave': case 'import-midi': case 'import-take': {
        if (!accepting) return
        status = 'Importing source…'; draw()
        const result = await request({ ...value, project: editor.project, projectPath: path })
        if (accepting) { adopt(arrangementImported(editor, result)); status = value.kind === 'import-take' ? `Imported ${result.asset}; Enter opens WAV and MIDI` : `Imported ${result.asset}; Enter places it at the cursor` }
        break
      }
      default: throw new Error('Unknown arrangement effect')
    }
  }
  function enqueue(action) {
    task = task.then(async () => {
      // Already admitted parent actions wait for the child to return terminal
      // ownership. Preparation remains cancellable before the child opens.
      if (takeTask) await Promise.allSettled([takeTask])
      await action()
    }).catch(error => { status = error.name === 'AbortError' ? 'Import or verification cancelled' : error.message }).finally(draw)
  }
  function keypress(text, key = {}) {
    if (!accepting || closed || suspended) return
    if (key.ctrl && key.name === 'c') { finish(); return }
    if (prompt !== null) {
      if (key.name === 'escape') prompt = null
      else if (key.name === 'backspace') prompt = [...prompt].slice(0, -1).join('')
      else if (key.name === 'return') {
        const line = prompt; prompt = null
        enqueue(async () => {
          let result = arrangementCommand(editor, line)
          if (result.editor.project !== editor.project || result.effect && !['record', 'record-stop', 'inputs', 'input', 'midi-input', 'help'].includes(result.effect.kind)) {
            await settleRecording(); result = arrangementCommand(editor, line)
          }
          adopt(result.editor); if (result.effect) await effect(result.effect); else status = 'Edited'
        })
      } else if (text && !key.ctrl && !key.meta) prompt += safeText(text)
      draw(); return
    }
    if (['escape', 'q'].includes(key.name)) { finish(); return }
    if (text === ':') { prompt = ''; draw(); return }
    if (text === '?') { showHelp = !showHelp; draw(); return }
    enqueue(async () => {
      let action
      switch (key.name) {
        case 's': await settleRecording(); await save(); return
        case 'a': action = { kind: 'asset' }; break
        case 'tab': action = { kind: 'lane' }; break
        case 'return':
          if (!key.shift && editor.project.assets.find(asset => asset.id === editor.asset)?.kind === 'capture') { await settleRecording(); openTake(editor.asset); return }
          action = { kind: 'place' }; break
        case 'delete': case 'backspace': case 'x': action = { kind: 'remove' }; break
        case 'd': action = { kind: 'duplicate' }; break
        case 'u': action = { kind: 'undo' }; break
        case 'y': action = { kind: 'redo' }; break
        case 'm': action = { kind: 'mute' }; break
        case 'o': action = { kind: 'solo' }; break
        case 'left': case 'right': action = { kind: key.shift ? 'move' : 'cursor', ticks: editor.step * (key.name === 'left' ? -1 : 1) }; break
        case 'up': case 'down': action = { kind: 'region', direction: key.name === 'down' ? 1 : -1 }; break
        case 'space': await settleRecording(); play(); return
        default: return
      }
      if (arrangementAction(editor, action).project !== editor.project) await settleRecording()
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
    if (!closed && !suspended && !pendingDraw) pendingDraw = setImmediate(() => { pendingDraw = null; drawNow() })
  }
  function drawNow() {
    if (closed || suspended) return
    const project = editor.project, clip = selectedRegion(editor), asset = project.assets.find(asset => asset.id === editor.asset)
    const rows = process.stdout.rows || 24, width = Math.max(1, (process.stdout.columns || 80) - 24)
    const lines = [`Arrangement · ${project.title}${project !== saved ? ' *' : ''} · ${project.tempo} BPM · ${project.meter.join('/')}`,
      `Cursor ${editor.tick / project.ppq} beats · grid ${editor.step / project.ppq} · ${status}`,
      `Playback ${transport.kind} · ${(transport.event?.currentTime ?? 0).toFixed(2)} s · ${transport.event?.device.name ?? route.output ?? route.midiOutput ?? 'default output'}`,
      `Recording ${recording?.phase ?? 'idle'} · input ${input ?? 'choose :input'} · MIDI ${midiInput}`]
    if (inputDevices !== null) lines.push(...inputDevices)
    else if (showHelp) lines.push(...help)
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
          for (let cell = from; cell < to; cell++) cells[cell] = region.id === editor.region ? '#' : lane.kind === 'capture' ? 'C' : lane.kind === 'wave' ? 'W' : 'M'
        }
        lines.push(`${lane.id === editor.lane ? '>' : ' '} ${index + start + 1} ${lane.name.slice(0, 12).padEnd(12)} ${lane.muted ? 'm' : '-'}${lane.solo ? 's' : '-'} ${cells.join('')}`)
      }
      if (!project.lanes.length) lines.push('Import a source, then Enter or :place to add its first lane and region.')
      lines.push(clip ? `${clip.id} · ${clip.name} · beat ${clip.position / project.ppq} · source ${clip.offset}+${clip.extent} ${project.assets.find(asset => asset.id === clip.asset).kind === 'capture' ? 'host ticks' : ''} · repeat ${clip.repeat}${clip.pattern === undefined ? '' : ` · pattern ${clip.pattern + 1}`}` : 'Up/Down selects a region on the current lane.')
      lines.push(asset ? `${asset.id} · ${asset.name} · ${asset.kind === 'wave' ? `${asset.metadata.frames} frames / ${asset.metadata.sampleRate} Hz / ${asset.metadata.channels} channels` : asset.kind === 'capture' ? `${asset.manifest.audioFrames} frames + ${asset.manifest.midiPacketCount} UMP packets; Enter opens the take` : 'original MIDI ticks; format-2 patterns require explicit selection'}` : 'No imported asset. :import-wave FILE or :import-midi FILE')
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
    if (transport.kind === 'playing') { try { transport.handle.status() } catch (error) { if (recording) recording.failure = error; stop(); status = error.message; draw() } }
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
