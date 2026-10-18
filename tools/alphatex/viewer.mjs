#!/usr/bin/env node
import { readFileSync, mkdtempSync, rmSync, writeFileSync, chmodSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { parseArgs } from 'node:util'
import { Worker } from 'node:worker_threads'
import { spawn } from 'node:child_process'
import { emitKeypressEvents } from 'node:readline'
import { safeText, transmit, viewport, place, retire } from './terminal.mjs'
import { errorDetail } from './diagnostics.mjs'
import { InstrumentPicker, selectionLabel, pickerFooter } from './instruments.mjs'
import { nativeJob, defaultStateDirectory, snapshotWriter, retainRender } from './vst.mjs'

const { values, positionals } = parseArgs({
  allowPositionals: true,
  options: {
    bundle: { type: 'string' },
    index: { type: 'string', default: '1' },
    'cell-width': { type: 'string' },
    'cell-height': { type: 'string' },
    soundfont: { type: 'string' },
    check: { type: 'boolean' },
    render: { type: 'string' },
    audio: { type: 'string' },
    record: { type: 'boolean' },
    devices: { type: 'boolean' },
    session: { type: 'string' },
    'session-root': { type: 'string' },
    input: { type: 'string' },
    output: { type: 'string' },
    'midi-output': { type: 'string' },
    midi: { type: 'string' },
    'state-dir': { type: 'string' },
    sequence: { type: 'boolean' },
    project: { type: 'string' },
    'project-root': { type: 'string' },
    help: { type: 'boolean' },
  },
})

if (values.help) {
  console.log('masc-alphatex [file.atex] [--bundle snapshot.json] [--index N]\n'
    + '  TUI score viewer: arrows/j/k scroll, +/- zoom, t tracks, Space choose/play/pause, p sequencer, r recording, s stop, q exit.\n'
    + '  i chooses instrument/preset, e opens its native sound browser, l toggles repeat.\n'
    + '  --state-dir stores native selection, saved presets, renders and Lane snapshot.\n'
    + '  --sequence opens a new phrase editor; --project song.json reopens one; --project-root sets its folder.\n'
    + '  --output UID selects sequencer audio output; :output UID changes it in the editor.\n'
    + '  --midi-output ID sends sequencer notes to that MIDI destination; :audio returns to audio.\n'
    + '  --record opens audio/MIDI input selection; r begins recording, s saves WAV and UMP.\n'
    + '  --session directory opens a saved waveform/MIDI timeline; --session-root sets the take folder.\n'
    + '  --devices lists CoreAudio devices and CoreMIDI inputs/outputs on macOS.\n'
    + '  --check validates; --render output.png and --audio output.wav export using alphaTab 1.8.4.')
  process.exit(0)
}

try {
  if (values.sequence || values.project) {
    const { viewSequencer } = await import('./sequencer-tui.mjs')
    await viewSequencer({ path: values.project, root: values['project-root'], soundfontPath: values.soundfont,
      sessionRoot: values['session-root'], input: values.input, midi: values.midi, output: values.output, midiOutput: values['midi-output'] })
  } else if (values.devices) {
    const { devices } = await import('./capture.mjs')
    const { midiDestinations } = await import('./playback.mjs')
    const [inputs, outputs] = await Promise.allSettled([devices(), midiDestinations()])
    if (inputs.status === 'rejected') throw inputs.reason
    console.log(JSON.stringify({ ...inputs.value, ...(outputs.status === 'fulfilled'
      ? { midiOutputs: outputs.value } : { midiOutputError: outputs.reason.message }) }))
  } else if (values.record || values.session) {
    const { viewSession } = await import('./music-session.mjs')
    await viewSession({ directory: values.session, root: values['session-root'], input: values.input, midi: values.midi })
  } else {
  const sources = values.bundle
    ? JSON.parse(readFileSync(values.bundle, 'utf8')).sources
    : [readFileSync(positionals[0] ?? 0, 'utf8')]
  if (!Array.isArray(sources) || sources.length === 0 || sources.some(source => typeof source !== 'string')) {
    throw new Error('the score snapshot must contain a nonempty array of alphaTex sources')
  }
  const index = Number(values.index) - 1
  if (!Number.isInteger(index) || index < 0 || index >= sources.length) throw new Error('score index is outside the snapshot')
  if (values.check || values.render || values.audio) {
    const { readScore, renderScore, engineVersion } = await import('./engine.mjs')
    const { score } = readScore(sources[index])
    if (values.render) writeFileSync(values.render, renderScore(sources[index]).pages[0].png, { flag: 'wx', mode: 0o600 })
    if (values.audio) {
      const { exportWave } = await import('./audio.mjs')
      exportWave(sources[index], values.audio, { soundfontPath: values.soundfont })
    }
    console.log(JSON.stringify({ engine: 'alphaTab', version: engineVersion, title: score.title, tracks: score.tracks.length, bars: score.masterBars.length }))
  } else {
    await viewScores(sources, index)
  }
  }
} catch (error) {
  console.error(`alphaTex: ${errorDetail(error).split('\n').map(safeText).join('\n')}`)
  process.exitCode = 1
}

async function viewScores(sources, initialIndex) {
  if (!process.stdin.isTTY || !process.stdout.isTTY) throw new Error('score view requires a terminal')
  const cellWidth = Number(values['cell-width'])
  const cellHeight = Number(values['cell-height'])
  if (!(Number.isInteger(cellWidth) && cellWidth > 0 && Number.isInteger(cellHeight) && cellHeight > 0)) {
    throw new Error('terminal cell geometry is unavailable; open this score from masc-tui after its graphics probe')
  }
  const directory = mkdtempSync(join(tmpdir(), 'masc-score-'))
  chmodSync(directory, 0o700)
  const renderWorker = new Worker(new URL('./worker.mjs', import.meta.url))
  const audioWorker = new Worker(new URL('./worker.mjs', import.meta.url))
  const tmux = Boolean(process.env.TMUX)
  let index = initialIndex
  let scale = 1
  let selectedTrack = -1
  let scroll = 0
  let page = 0
  let document = null
  let renderGeneration = 0
  let renderBusy = false
  let pendingRender = null
  let audioGeneration = 0
  let view = null
  let status = 'Loading score…'
  let closed = false
  let audioState = 'stopped'
  let player = null
  const children = new Map()
  let renderFailure = null
  let audioFailure = null
  let playingSince = 0
  let cancellation = null
  let diagnostics = ''
  let textView = false
  let elapsed = 0
  let duration = 0
  let suspended = false
  let sessionTask = null
  const sessionAbort = new AbortController()
  let instrument = null
  let repeating = false
  let nativeRender = null
  let currentRender = null
  const nativeRenders = new Set()
  const stateDirectory = values['state-dir'] ?? defaultStateDirectory()
  const record = snapshotWriter(stateDirectory)
  const retained = fields => record(fields).catch(error => {
    if (!closed) { status = `Lane state could not be saved: ${error.message}`; redraw() }
  })
  const picker = new InstrumentPicker({ directory: stateDirectory, notify: () => redraw({ imageChanged: !picker.view }),
    failed: error => { status = `VST: ${error.message}`; redraw() },
    selected: selection => { instrument = selection; synthesize() },
    soundfont: () => { instrument = null; synthesize() },
    active: () => instrument })
  const write = bytes => { if (!closed && !suspended) process.stdout.write(bytes) }
  const tracks = () => selectedTrack < 0 ? undefined : [selectedTrack]
  let finish
  const done = new Promise(resolve => { finish = resolve })

  // Keep each heading inside one physical row, including CJK labels.
  function fit(text) {
    const columns = Math.max(1, process.stdout.columns - 1)
    let result = '', used = 0
    for (const char of safeText(text)) {
      const code = char.codePointAt(0)
      const width = code >= 0x1100 && (code <= 0x115f || code >= 0x2e80) ? 2 : 1
      if (used + width > columns) break
      result += char
      used += width
    }
    return result
  }
  function wrapped(text) {
    const columns = Math.max(1, process.stdout.columns - 1)
    return text.split('\n').flatMap(line => {
      const result = []
      let remaining = safeText(line)
      do {
        const part = fit(remaining)
        if (!part && remaining) { result.push(remaining[0]); remaining = remaining.slice(1) }
        else { result.push(part); remaining = remaining.slice(part.length) }
      } while (remaining.length > 0 && columns > 0)
      return result
    })
  }
  function redraw({ imageChanged = false } = {}) {
    if (closed || suspended) return
    const rows = process.stdout.rows || 24
    const columns = process.stdout.columns || 80
    // Clear text lines individually. CSI 2J can free Kitty image storage.
    let output = '\x1b[H'
    for (let row = 1; row <= rows; row++) output += `\x1b[${row};1H\x1b[2K`
    output += `\x1b[1;1H${fit(`alphaTex · ${document?.title || 'Score'} · score ${index + 1}/${sources.length} · system ${(document?.page ?? 0) + 1}/${document?.pageCount ?? 1} · ${Math.round(scale * 100)}%`)}`
    const track = selectedTrack < 0 ? 'all tracks' : document?.tracks.find(t => t.index === selectedTrack)?.name
    const time = audioState === 'playing' ? elapsed + Date.now() - playingSince : elapsed
    output += `\x1b[2;1H${fit(`${track ?? ''} · ${selectionLabel(instrument)} · ${audioState}${repeating ? ' · repeat' : ''} ${Math.floor(time / 1000)} / ${Math.floor(duration / 1000)}s · ${status}`)}`
    if (picker.view) {
      output += retire(tmux)
      const menu = picker.view
      output += `\x1b[4;2H${fit(menu.title)}`
      if (menu.kind === 'preset_path') output += `\x1b[6;2H${fit(menu.query)}▌`
      else if (menu.items) {
        const items = picker.items()
        const available = Math.max(1, rows - 9)
        const top = Math.max(0, menu.cursor - available + 1)
        items.slice(top, top + available).forEach((item, offset) => {
          const cursor = top + offset === menu.cursor ? '›' : ' '
          const active = picker.isActive(item) ? '●' : ' '
          output += `\x1b[${offset + 6};2H${fit(`${cursor}${active} ${item.name}`)}`
        })
        output += `\x1b[${rows - 2};2H${fit(`Search: ${menu.query}${menu.searching ? '▌' : ''}`)}`
      }
    } else if (textView) {
      output += retire(tmux)
      const lines = wrapped([diagnostics, 'alphaTex source:', sources[index]].join('\n'))
      const available = Math.max(1, rows - 4)
      scroll = Math.max(0, Math.min(scroll, Math.max(0, lines.length - available)))
      view = { availableRows: available, fullRows: lines.length }
      lines.slice(scroll, scroll + available).forEach((line, i) => {
        output += `\x1b[${i + 3};1H${fit(line)}`
      })
    } else if (document) {
      const image = document.pages[0]
      view = viewport(image, { columns, rows, cellWidth, cellHeight, scroll })
      scroll = view.scroll
      if (imageChanged) output += retire(tmux) + transmit(image.png, tmux)
      output += `\x1b[3;2H${place(view, tmux)}`
    }
    output += `\x1b[${rows};1H${fit(picker.view
      ? pickerFooter(picker.view)
      : '↑↓/j k:scroll  [ ]:system  +/-:zoom  t:tracks  ←→:score  v:source  Space:choose/play/pause  i:instrument  l:repeat  p:sequencer  r:recording  s:stop  q:back')}`
    write(output)
  }
  function render() {
    if (renderFailure) { status = `Renderer unavailable: ${renderFailure}`; redraw(); return }
    status = 'Rendering…'
    const id = ++renderGeneration
    const width = Math.max(1, (process.stdout.columns - 2) * cellWidth)
    const job = { id, kind: 'render', source: sources[index], options: { width, scale, tracks: tracks(), page } }
    if (renderBusy) pendingRender = job
    else { renderBusy = true; renderWorker.postMessage(job) }
    redraw()
  }
  function stop() {
    ++audioGeneration
    if (cancellation) Atomics.store(cancellation, 0, 1)
    cancellation = null
    nativeRender?.cancel()
    nativeRender = null
    if (player) {
      // A stopped child must be continued before SIGTERM can be handled.
      if (audioState === 'paused') player.kill('SIGCONT')
      player.kill('SIGTERM')
      player = null
    }
    audioState = 'stopped'
    elapsed = 0
    duration = 0
    retained({ state: 'stop_requested', selection: instrument, render: currentRender })
  }
  function startPlayer(path, id, candidate = 0, lastError = '') {
    if (id !== audioGeneration || closed) return
    const choices = [
      ['afplay', [path]],
      ['ffplay', ['-nodisp', '-autoexit', '-loglevel', 'error', path]],
      ['aplay', ['-q', path]],
      ['play', ['-q', path]],
    ]
    if (candidate === choices.length) {
      audioState = 'stopped'
      status = `Audio unavailable: ${lastError}`
      retained({ state: 'failed', selection: instrument, render: currentRender, error: status })
      redraw()
      return
    }
    const [command, args] = choices[candidate]
    const child = spawn(command, args, { stdio: ['ignore', 'ignore', 'pipe'] })
    children.set(child, new Promise(resolve => child.once('close', () => { children.delete(child); resolve() })))
    player = child
    let detail = ''
    child.stderr.on('data', bytes => { detail = safeText(bytes.toString()).slice(-1024) })
    child.once('spawn', () => {
      if (closed || id !== audioGeneration) { child.kill('SIGTERM'); return }
      audioState = 'playing'
      playingSince = Date.now()
      status = `Playing with ${command}`
      retained({ state: 'player_started', selection: instrument, render: currentRender })
      redraw()
    })
    child.once('error', error => {
      if (player === child) player = null
      startPlayer(path, id, candidate + 1, error.message)
    })
    child.once('exit', (code, signal) => {
      if (id !== audioGeneration || closed) return
      if (player === child) player = null
      if (code !== 0 && signal === null) startPlayer(path, id, candidate + 1, detail || `${command} exited ${code}`)
      else if (code === 0 && repeating) {
        elapsed = 0
        startPlayer(path, id)
      } else {
        audioState = 'stopped'
        elapsed = 0
        status = code === 0 ? 'Playback finished' : `Player ended: ${signal}`
        retained({ state: code === 0 ? 'player_finished' : 'player_ended', selection: instrument,
          render: currentRender, exit_code: code, signal })
        redraw()
      }
    })
  }
  function togglePlayback() {
    if (audioFailure) { status = `Audio unavailable: ${audioFailure}`; redraw(); return }
    if (audioState === 'playing' && player) {
      player.kill('SIGSTOP')
      elapsed += Date.now() - playingSince
      audioState = 'paused'
      retained({ state: 'pause_requested', selection: instrument, render: currentRender })
    } else if (audioState === 'paused' && player) {
      player.kill('SIGCONT')
      playingSince = Date.now()
      audioState = 'playing'
      retained({ state: 'resume_requested', selection: instrument, render: currentRender })
    } else if (audioState === 'stopped') { picker.open(); return }
    redraw()
  }
  function synthesize() {
    const id = ++audioGeneration
    audioState = 'synthesizing'
    status = instrument ? `Rendering ${instrument.name}…` : 'Synthesizing score…'
    currentRender = null
    cancellation = new Int32Array(new SharedArrayBuffer(4))
    retained({ state: 'rendering', selection: instrument, render: null, score_index: index, tracks: tracks() ?? null })
    audioWorker.postMessage({ id, kind: instrument ? 'midi' : 'audio', source: sources[index],
      path: join(directory, `${id}.${instrument ? 'mid' : 'wav'}`),
      cancel: cancellation.buffer, options: { soundfontPath: values.soundfont, tracks: tracks() } })
    redraw()
  }
  renderWorker.on('message', message => {
    renderBusy = false
    if (pendingRender && !closed) {
      const next = pendingRender; pendingRender = null; renderBusy = true
      renderWorker.postMessage(next)
    }
    if (closed || message.id !== renderGeneration) return
    if (message.ok) {
      document = message.result
      page = document.page
      diagnostics = ''
      status = `alphaTab ${document.version}`
      redraw({ imageChanged: true })
    } else {
      // Leave the source snapshot untouched and report the official refusal.
      document = null
      diagnostics = message.error
      textView = true
      write(retire(tmux))
      status = 'Invalid alphaTex; official diagnostics and source below'
      redraw()
    }
  })
  audioWorker.on('message', message => {
    if (closed || message.id !== audioGeneration) return
    if (message.ok) {
      if (message.result.kind === 'midi') {
        const selected = instrument
        const job = nativeJob({ operation: 'render', ...selected,
          midi_path: message.result.path, output_path: join(directory, `${message.id}.wav`) })
        nativeRender = job
        const completion = job.promise.then(async result => {
          if (closed || message.id !== audioGeneration) return
          const saved = await retainRender(stateDirectory, result, message.result.path)
          if (closed || message.id !== audioGeneration) { await saved.discard(); return }
          currentRender = saved.result
          duration = currentRender.duration_ms
          retained({ state: 'rendered', selection: selected, render: currentRender })
          startPlayer(currentRender.output_path, message.id)
        }).catch(error => {
          if (closed || message.id !== audioGeneration) return
          audioState = 'stopped'
          status = `VST: ${error.message}`
          retained({ state: 'failed', selection: selected, error: error.message })
          redraw()
        }).finally(() => {
          nativeRenders.delete(completion)
          if (nativeRender === job) nativeRender = null
        })
        nativeRenders.add(completion)
        return
      }
      duration = message.result.durationMs
      startPlayer(message.result.path, message.id)
    } else {
      audioState = 'stopped'
      status = message.error
      retained({ state: 'failed', selection: instrument, render: currentRender, error: status })
      redraw()
    }
  })
  renderWorker.on('error', error => {
    renderFailure = error.message; renderBusy = false; pendingRender = null
    status = `Renderer unavailable: ${error.message}`; redraw()
  })
  audioWorker.on('error', error => {
    audioFailure = error.message; stop()
    status = `Audio unavailable: ${error.message}`
    retained({ state: 'failed', selection: instrument, render: currentRender, error: status })
    redraw()
  })
  function keypress(text, key = {}) {
    if (picker.view && !(key.ctrl && key.name === 'c')) {
      if (key.name === 's' && !picker.view.searching && picker.view.kind !== 'preset_path') {
        stop(); status = 'Stopped'; redraw(); return
      }
      const hadMenu = picker.view
      picker.keypress(text, key).catch(error => { status = `VST: ${error.message}`; redraw() })
      if (hadMenu && !picker.view) redraw({ imageChanged: true })
      return
    }
    if (key.ctrl && key.name === 'c' || ['escape', 'q'].includes(key.name)) { finish(); return }
    switch (key.name) {
      case 'p': case 'r': {
        if (sessionTask) return
        stop()
        write(retire(tmux))
        suspended = true
        process.stdin.off('keypress', keypress)
        sessionTask = (async () => {
          try {
            if (key.name === 'p') {
              const { viewSequencer } = await import('./sequencer-tui.mjs')
              if (!closed) await viewSequencer({ root: values['project-root'], sessionRoot: values['session-root'],
                soundfontPath: values.soundfont, input: values.input, midi: values.midi, output: values.output,
                midiOutput: values['midi-output'], embedded: true, signal: sessionAbort.signal })
            } else {
              const { viewSession } = await import('./music-session.mjs')
              if (!closed) await viewSession({ root: values['session-root'], input: values.input, midi: values.midi, embedded: true, signal: sessionAbort.signal })
            }
          } catch (error) { status = error.message }
          finally {
            sessionTask = null; suspended = false
            if (!closed) { process.stdin.on('keypress', keypress); render() }
          }
        })()
        return
      }
      case 'up': case 'k': scroll -= 3; break
      case 'down': case 'j': scroll += 3; break
      case 'pageup':
        if (!textView && scroll === 0 && page > 0) { page--; render(); return }
        scroll -= view?.availableRows ?? 10; break
      case 'pagedown':
        if (!textView && document && view && scroll + view.availableRows >= view.fullRows && page + 1 < document.pageCount) {
          page++; scroll = 0; render(); return
        }
        scroll += view?.availableRows ?? 10; break
      case 'home':
        scroll = 0
        if (!textView && page > 0) { page = 0; render(); return }
        break
      case 'end':
        if (!textView && document && page + 1 < document.pageCount) {
          page = document.pageCount - 1; scroll = Number.MAX_SAFE_INTEGER; render(); return
        }
        scroll = view?.fullRows ?? 0; break
      case 'left': case 'right': {
        const next = Math.max(0, Math.min(sources.length - 1, index + (key.name === 'left' ? -1 : 1)))
        if (next === index) break
        stop(); index = next; selectedTrack = -1; scroll = 0; page = 0; document = null; diagnostics = ''; textView = false
        write(retire(tmux)); render(); return
      }
      case 't':
        if (!document) break
        stop(); selectedTrack = selectedTrack + 1 >= document.tracks.length ? -1 : selectedTrack + 1
        scroll = 0; page = 0; render(); return
      case 'space': togglePlayback(); return
      case 'i': stop(); picker.open(); return
      case 'l': repeating = !repeating; break
      case 'v':
        textView = !textView; scroll = 0
        redraw({ imageChanged: !textView }); return
      case 's': stop(); status = 'Stop requested'; break
      default:
        if (text === '[' && document && page > 0) { page--; scroll = 0; render(); return }
        if (text === ']' && document && page + 1 < document.pageCount) { page++; scroll = 0; render(); return }
        if (text === '+' || text === '=') { scale = Math.min(4, scale + 0.25); scroll = 0; render(); return }
        if (text === '-') { scale = Math.max(0.25, scale - 0.25); scroll = 0; render(); return }
        return
    }
    redraw()
  }
  const resize = () => { if (!suspended) render() }
  const onSignal = () => finish()
  const onEnd = () => finish()
  emitKeypressEvents(process.stdin)
  const wasRaw = process.stdin.isRaw
  process.stdin.setRawMode(true)
  process.stdin.resume()
  process.stdin.on('keypress', keypress)
  process.stdin.on('end', onEnd)
  process.stdout.on('resize', resize)
  for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(signal, onSignal)
  const timer = setInterval(() => { if (audioState === 'playing') redraw() }, 1000)
  // The parent relinquishes its alternate screen before this child starts.
  process.stdout.write('\x1b[?1049h\x1b[?25l\x1b[2J')
  render()
  try {
    await done
  } finally {
    stop()
    picker.close()
    closed = true
    sessionAbort.abort()
    clearInterval(timer)
    process.stdin.off('keypress', keypress)
    process.stdin.off('end', onEnd)
    process.stdout.off('resize', resize)
    for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.off(signal, onSignal)
    const exits = [...children.values()]
    for (const child of children.keys()) child.kill('SIGKILL')
    await Promise.all([sessionTask, renderWorker.terminate(), audioWorker.terminate(), picker.settled(),
      Promise.allSettled([...nativeRenders]), ...exits])
    process.stdout.write(retire(tmux) + '\x1b[?25h\x1b[?1049l')
    process.stdin.setRawMode(wasRaw ?? false)
    process.stdin.pause()
    rmSync(directory, { recursive: true, force: true })
  }
}
