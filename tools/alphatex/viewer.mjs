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
    midi: { type: 'string' },
    help: { type: 'boolean' },
  },
})

if (values.help) {
  console.log('masc-alphatex [file.atex] [--bundle snapshot.json] [--index N]\n'
    + '  TUI score viewer: arrows/j/k scroll, +/- zoom, t tracks, Space play/pause, r recording, q exit.\n'
    + '  --record opens audio/MIDI input selection; r begins recording, s saves WAV and UMP.\n'
    + '  --session directory opens a saved waveform/MIDI timeline; --session-root sets the take folder.\n'
    + '  --devices lists CoreAudio/CoreMIDI inputs on macOS.\n'
    + '  --check validates; --render output.png and --audio output.wav export using alphaTab 1.8.4.')
  process.exit(0)
}

try {
  if (values.devices) {
    const { devices } = await import('./capture.mjs')
    console.log(JSON.stringify(await devices()))
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
    output += `\x1b[2;1H${fit(`${track ?? ''} · ${audioState} ${Math.floor(time / 1000)} / ${Math.floor(duration / 1000)}s · ${status}`)}`
    if (textView) {
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
    output += `\x1b[${rows};1H${fit('↑↓/j k:scroll PgUp/PgDn  [ ]:system  +/-:zoom  t:tracks  ←→:score  v:source  Space:play/pause  r:recording  s:stop  q:back')}`
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
    if (player) {
      // A stopped child must be continued before SIGTERM can be handled.
      if (audioState === 'paused') player.kill('SIGCONT')
      player.kill('SIGTERM')
      player = null
    }
    audioState = 'stopped'
    elapsed = 0
    duration = 0
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
      else {
        audioState = 'stopped'
        elapsed = 0
        status = code === 0 ? 'Playback finished' : `Player ended: ${signal}`
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
    } else if (audioState === 'paused' && player) {
      player.kill('SIGCONT')
      playingSince = Date.now()
      audioState = 'playing'
    } else if (audioState === 'stopped') {
      const id = ++audioGeneration
      audioState = 'synthesizing'
      status = 'Synthesizing score…'
      cancellation = new Int32Array(new SharedArrayBuffer(4))
      audioWorker.postMessage({ id, kind: 'audio', source: sources[index], path: join(directory, `${id}.wav`),
        cancel: cancellation.buffer, options: { soundfontPath: values.soundfont, tracks: tracks() } })
    }
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
      duration = message.result.durationMs
      startPlayer(message.result.path, message.id)
    } else {
      audioState = 'stopped'
      status = message.error
      redraw()
    }
  })
  renderWorker.on('error', error => {
    renderFailure = error.message; renderBusy = false; pendingRender = null
    status = `Renderer unavailable: ${error.message}`; redraw()
  })
  audioWorker.on('error', error => {
    audioFailure = error.message; stop()
    status = `Audio unavailable: ${error.message}`; redraw()
  })
  function keypress(text, key = {}) {
    if (key.ctrl && key.name === 'c' || ['escape', 'q'].includes(key.name)) { finish(); return }
    switch (key.name) {
      case 'r': {
        if (sessionTask) return
        stop()
        write(retire(tmux))
        suspended = true
        process.stdin.off('keypress', keypress)
        sessionTask = (async () => {
          try {
            const { viewSession } = await import('./music-session.mjs')
            if (!closed) await viewSession({ root: values['session-root'], input: values.input, midi: values.midi, embedded: true, signal: sessionAbort.signal })
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
      case 'v':
        textView = !textView; scroll = 0
        redraw({ imageChanged: !textView }); return
      case 's': stop(); status = 'Stopped'; break
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
    closed = true
    sessionAbort.abort()
    clearInterval(timer)
    process.stdin.off('keypress', keypress)
    process.stdin.off('end', onEnd)
    process.stdout.off('resize', resize)
    for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.off(signal, onSignal)
    const exits = [...children.values()]
    for (const child of children.keys()) child.kill('SIGKILL')
    await Promise.all([sessionTask, renderWorker.terminate(), audioWorker.terminate(), ...exits])
    process.stdout.write(retire(tmux) + '\x1b[?25h\x1b[?1049l')
    process.stdin.setRawMode(wasRaw ?? false)
    process.stdin.pause()
    rmSync(directory, { recursive: true, force: true })
  }
}
