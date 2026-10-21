import { mkdtemp, rm, mkdir } from 'node:fs/promises'
import { join, resolve } from 'node:path'
import { randomUUID } from 'node:crypto'
import { tmpdir } from 'node:os'
import { prepareCapturedPlayback, prepareCapturedWave } from './capture-playback.mjs'
import { midiDestinations, openPlayback } from './playback.mjs'
import { emitKeypressEvents } from 'node:readline'
import { spawn } from 'node:child_process'
import { devices, record } from './capture.mjs'
import { CaptureTimeline, readCapture, waveform, exportMidiClips } from './session-data.mjs'
import { safeText } from './terminal.mjs'
import { StatusReader } from './status-reader.mjs'

// The score viewer lends us its terminal while suspended; standalone invocation
// additionally owns alternate screen/raw mode and restores exactly what it acquired.
export async function viewSession({ directory, root = resolve('music-sessions'), input, midi, signal, embedded = false, exportRoot, output, midiOutput, sourceBindings = [] } = {}) {
  if (!process.stdin.isTTY || !process.stdout.isTTY) throw new Error('Music sessions require a terminal')
  let destinations = [], audioOutput = output, selectedMidi = midiOutput, sourceOutputs = sourceBindings, prompt = null
  let playbackAbort = null, playbackTask = null, paired = null, pairedState = null
  let available = null, inputIndex = 0, midiIndex = 0, timeline = null
  let take = directory, capture = null, captureTask = null, player = null
  let captureIntent = null
  const players = new Map()
  const discoveryAbort = new AbortController()
  let phase = directory ? 'loading' : 'discovering', status = '', closed = false, scroll = 0, dirty = false
  let start = 0, span = 10, follow = true, exportTask = null
  let helpShown = false
  const statusReader = new StatusReader()
  const wasRaw = process.stdin.isRaw
  let finish
  const done = new Promise(resolve => { finish = () => { discoveryAbort.abort(); resolve() } })
  const fit = text => {
    let used = 0, result = ''
    for (const char of safeText(text)) {
      const code = char.codePointAt(0)
      const width = code >= 0x1100 && (code <= 0x115f || code >= 0x2e80) ? 2 : 1
      if (used + width > Math.max(1, process.stdout.columns - 1)) break
      result += char; used += width
    }
    return result
  }
  const inputs = () => available?.audio.filter(device => device.inputs > 0) ?? []
  const midiChoices = () => [{ id: 'all', name: 'All MIDI inputs' }, { id: 'none', name: 'No MIDI input' }, ...(available?.midi ?? [])]
  function playbackPosition() {
    if (pairedState === null) return null
    const elapsed = pairedState.kind === 'playing' ? (performance.now() - pairedState.since) / 1000 : 0
    return Math.min(pairedState.duration, pairedState.currentTime + elapsed)
  }
  function draw() {
    if (closed) return
    dirty = false
    const reading = statusReader.render(process.stdout)
    if (reading !== null) { process.stdout.write(reading); return }
    const rows = process.stdout.rows || 24, width = Math.max(1, (process.stdout.columns || 80) - 9)
    const position = playbackPosition()
    // Native seconds start at the prepared route's origin, while recorded
    // waveform/MIDI seconds start at requestedStart. Keep those clocks distinct.
    const timelinePosition = position === null ? null : position + pairedState.timelineOffsetSeconds
    const first = Math.min(0, pairedState?.timelineOffsetSeconds ?? 0)
    if (follow && timeline) start = timelinePosition === null ? Math.max(0, timeline.duration - span)
      : Math.min(Math.max(first, timeline.duration - span), Math.max(first, timelinePosition - span / 2))
    const playhead = timelinePosition === null ? null : Math.floor((timelinePosition - start) * width / span)
    const cursor = cells => cells.map((cell, index) => index === playhead ? '│' : cell).join('')
    const lines = [
      `Music session · ${phase} · ${timeline?.duration.toFixed(2) ?? '0.00'}s · ${status}`,
      pairedState !== null
        ? `Playback ${pairedState.kind} · ${pairedState.kind === 'playing' ? '≈' : ''}${position.toFixed(2)} / ${pairedState.duration.toFixed(2)}s · ${pairedState.device.name}`
        : playbackTask ? `Playback ${playbackAbort?.signal.aborted ? 'stopping' : 'preparing'}`
          : player ? 'Playback external WAV · position unavailable' : 'Playback idle',
      `Next audio: ${inputs()[inputIndex]?.name ?? 'no input'} · MIDI: ${midiChoices()[midiIndex]?.name ?? ''}${timeline ? ` · Take: ${timeline.manifest.input.name}` : ''}`,
      `Save: ${take ?? root}`,
      `Outputs: audio ${audioOutput ?? 'system default'} · MIDI ${selectedMidi ?? 'WAV only'} · ${sourceOutputs.length} source bindings`,
      `${start.toFixed(2)}s ${'─'.repeat(Math.max(1, width - 10))} ${(start + span).toFixed(2)}s`,
    ]
    const tracks = []
    if (helpShown) tracks.push(
      'i: choose the next audio input; m: choose MIDI inputs (all, none or one source)',
      'r: begin a new take using the selected inputs; s: stop and save',
      'Space: play/stop this take; o selects MIDI output, a selects audio output',
      'p: pause/resume native playback; :seek SECONDS moves its audio and MIDI together',
      ':source SOURCE_ID MIDI_UID binds one captured input; :midi-output UID sets a default',
      'Stateful UMP seeks restore live voices and expression when source baselines are known.',
      'e: export one MIDI 2.0 Clip per input source (saved takes only)',
      'Up/Down: scroll tracks; Left/Right: move the time window',
      '+/-: zoom time; f: follow playback or the end of the take',
      'The playhead follows the acknowledged native position; ≈ advances it while playing.',
      '?: show/hide help; q/Esc: finish recording and return',
    )
    else if (timeline) {
      for (let channel = 0; channel < timeline.channels; channel++) {
        const peaks = waveform(timeline, channel, start, span / width, width)
        const peak = peaks.reduce((max, pair) => pair ? Math.max(max, Math.abs(pair[0]), Math.abs(pair[1])) : max, 0)
        const scale = peak || 1
        tracks.push(`Audio ${channel + 1} · ${timeline.sampleRate}Hz · ${peak ? `${(20 * Math.log10(peak)).toFixed(1)} dBFS` : 'silence'} · display ±${scale.toFixed(3)}`)
        for (let y = 0; y < 5; y++) {
          const high = (1 - y * 0.4) * scale, low = high - 0.4 * scale
          tracks.push(`       ${cursor(peaks.map(pair => pair && (pair[0] !== 0 || pair[1] !== 0) && pair[1] >= low && pair[0] <= high ? '█' : y === 2 ? '─' : ' '))}`)
        }
      }
      for (const track of timeline.midi.values()) {
        tracks.push(`${track.name} · group ${(track.group ?? -1) + 1 || '—'} · channel ${(track.channel ?? -1) + 1 || '—'} · ${track.events.length} events`)
        const pitches = [...new Set(track.notes.map(note => note.pitch))].sort((a, b) => b - a)
        if (!pitches.length) tracks.push('       MIDI data preserved · no note events')
        for (const pitch of pitches) {
          const cells = Array(width).fill(' ')
          for (const note of track.notes) {
            if (note.pitch !== pitch) continue
            const first = Math.max(0, Math.floor((note.start - start) * width / span))
            const last = Math.min(width - 1, Math.floor(((note.end ?? timeline.duration) - start) * width / span))
            for (let x = first; x <= last; x++) cells[x] = '━'
          }
          tracks.push(`${String(pitch).padStart(6)} ${cursor(cells)}`)
        }
      }
    }
    const height = Math.max(1, rows - lines.length - 2)
    scroll = Math.max(0, Math.min(scroll, Math.max(0, tracks.length - height)))
    lines.push(...tracks.slice(scroll, scroll + height))
    let output = '\x1b[H'
    for (let row = 1; row <= rows; row++) output += `\x1b[${row};1H\x1b[2K`
    lines.forEach((line, row) => { if (row < rows - 1) output += `\x1b[${row + 1};1H${fit(line)}` })
    output += `\x1b[${rows};1H${fit(prompt === null ? 'Ctrl-L:status  r:record  s:save  Space:play/stop  p:pause/resume  :seek SECONDS  q:back  ?:help' : `:${prompt}`)}`
    process.stdout.write(output)
  }
  function stopPlayer() {
    pairedState = null
    playbackAbort?.abort(); paired?.terminate()
    if (player) { player.kill('SIGTERM'); player = null }
  }
  function startRecording() {
    if (!['ready', 'saved', 'failed'].includes(phase) || !inputs().length || captureTask) return
    stopPlayer()
    phase = 'starting'; status = ''; timeline = null; start = 0; scroll = 0; follow = true
    take = join(root, `take-${new Date().toISOString().replaceAll(':', '-')}-${randomUUID()}`)
    const input = inputs()[inputIndex].id, midi = midiChoices()[midiIndex].id
    const intent = new AbortController()
    captureIntent = intent
    captureTask = (async () => {
      try {
        await mkdir(root, { recursive: true, mode: 0o700 })
        // Closing during directory preparation must not begin a new recording.
        if (closed || signal?.aborted || intent.signal.aborted) return
        capture = record({ input, midi, directory: take, onEvent: event => {
          dirty = true
          switch (event.kind) {
            case 'recording':
              timeline = new CaptureTimeline({ ...event, schemaVersion: 1, state: 'recorded' })
              phase = intent.signal.aborted ? 'saving' : 'recording'; break
            case 'audio':
              if (!timeline) throw new Error('Audio arrived before the capture clock')
              timeline.addAudio(event); break
            case 'midi':
              if (!timeline) throw new Error('MIDI arrived before the capture clock')
              timeline.addMidi(event); break
            case 'stopped': phase = 'saving'; break
            case 'error': status = event.message; break
          }
        } })
        timeline = await capture.completion
        phase = 'saved'; status = 'WAV and MIDI saved'
      } catch (error) { phase = 'failed'; status = error.message }
      finally { capture = null; captureTask = null; captureIntent = null; draw() }
    })()
    draw()
  }
  function playWave() {
    if (player || playbackTask) { stopPlayer(); status = 'Stopped'; return }
    if (phase !== 'saved' || !take) return
    if (process.platform === 'darwin' || selectedMidi !== undefined || sourceOutputs.length || audioOutput !== undefined) { playCaptured(); return }
    pairedState = null
    const child = spawn('ffplay',
      ['-nodisp', '-autoexit', '-loglevel', 'error', join(take, 'audio.wav')],
      { stdio: ['ignore', 'ignore', 'pipe'] })
    player = child
    let detail = ''
    child.stderr.setEncoding('utf8').on('data', text => { detail += text })
    child.once('error', error => { status = error.message; draw() })
    players.set(child, new Promise(resolve => child.once('close', (code, signal) => {
      if (player === child) { player = null; status = code === 0 ? 'Playback finished' : detail || `Playback ended: ${code ?? signal}`; draw() }
      players.delete(child)
      resolve()
    })))
    status = 'Playing WAV'
  }
  function playCaptured() {
    const abort = new AbortController(); playbackAbort = abort
    pairedState = null
    status = 'Preparing original WAV and UMP…'
    const input = take, midiOutput = selectedMidi, sourceBindings = sourceOutputs, output = audioOutput, expectedManifest = timeline.manifest
    playbackTask = (async () => {
      let directory
      try {
        directory = await mkdtemp(join(tmpdir(), 'masc-captured-play-'))
        const plan = midiOutput !== undefined || sourceBindings.length
          ? await prepareCapturedPlayback(input, { directory, midiOutput, sourceBindings, expectedManifest, signal: abort.signal })
          : await prepareCapturedWave(input, { directory, expectedManifest, signal: abort.signal })
        abort.signal.throwIfAborted()
        paired = openPlayback({ ...plan, midiBindings: plan.bindings, output, signal: abort.signal, onEvent(event) {
          if (closed || abort.signal.aborted) return
          if (['playing', 'paused', 'stopped'].includes(event.kind)) pairedState = { ...event, timelineOffsetSeconds: plan.timelineOffsetSeconds, since: performance.now() }
          status = event.kind === 'error' ? event.message : event.refusal ?? `Capture ${event.kind}`; draw()
        } })
        await paired.completion
      } catch (error) { if (!closed && !abort.signal.aborted) { pairedState = null; status = error.message } }
      finally {
        paired = null
        try { if (directory) await rm(directory, { recursive: true, force: true }) }
        finally { playbackAbort = null; playbackTask = null; draw() }
      }
    })()
    playbackTask.catch(error => { status = error.message; draw() })
  }
  function outputCommand(line) {
    const [kind, ...args] = line.trim().split(/\s+/)
    if (['pause', 'resume', 'stop', 'seek'].includes(kind)) {
      if (kind === 'stop' && args.length === 0) { stopPlayer(); return }
      if (!paired) throw new Error('Start native playback with an audio or MIDI output selected')
      if (kind === 'seek' && args.length === 1 && args[0] !== '') paired.seek(Number(args[0]))
      else if (kind === 'pause' && args.length === 0) paired.pause()
      else if (kind === 'resume' && args.length === 0) paired.resume()
      else throw new Error('Use :pause, :resume, :seek SECONDS or :stop')
    } else if (kind === 'source' && args.length === 2) {
      stopPlayer();sourceOutputs = [...sourceOutputs.filter(binding => binding.source !== args[0]), { source: args[0], destination: args[1] }]
    } else if (kind === 'midi-output' && args.length === 1) { stopPlayer();selectedMidi = args[0];sourceOutputs = [] }
    else if (kind === 'output' && args.length === 1) { stopPlayer();audioOutput = args[0] }
    else throw new Error('Use :seek SECONDS, :pause, :resume, :stop, :source SOURCE_ID MIDI_UID, :midi-output MIDI_UID or :output AUDIO_UID')
  }
  function keypress(text, key = {}) {
    if (key.ctrl && key.name === 'c') { finish(); return }
    if (statusReader.keypress(text, key, process.stdout)) { draw(); return }
    if (key.ctrl && key.name === 'l' || prompt === null && text === '!') {
      statusReader.open('Music session status at open', `${phase}\n${status}\n\nTake: ${take ?? root}`)
      draw(); return
    }
    if (prompt !== null) {
      if (key.name === 'escape') prompt = null
      else if (key.name === 'backspace') prompt = [...prompt].slice(0, -1).join('')
      else if (key.name === 'return') {
        const line = prompt; prompt = null
        if (statusReader.command(line, 'Music session status at open', `${phase}\n${status}\n\nTake: ${take ?? root}`)) { draw(); return }
        try { outputCommand(line) } catch (error) { status = error.message }
      }
      else if (text && !key.ctrl && !key.meta) prompt += safeText(text)
      draw();return
    }
    if (text === ':') { prompt = '';draw();return }
    if (['q', 'escape'].includes(key.name)) { finish(); return }
    if (text === '?') { helpShown = !helpShown; scroll = 0; draw(); return }
    switch (key.name) {
      case 'p':
        try { outputCommand(pairedState?.kind === 'paused' ? 'resume' : 'pause') } catch (error) { status = error.message }
        draw(); return
      case 'r': startRecording(); return
      case 'o': {
        stopPlayer();const index = destinations.findIndex(device => device.id === selectedMidi) + 1
        selectedMidi = destinations[index]?.id;sourceOutputs = [];break
      }
      case 'a': {
        stopPlayer();const outputs = available?.audio.filter(device => device.outputs > 0) ?? []
        const index = outputs.findIndex(device => device.id === audioOutput) + 1
        audioOutput = outputs[index]?.id;break
      }
      case 's':
        captureIntent?.abort()
        if (capture) { phase = 'saving'; capture.stop() }
        else if (captureTask) { phase = 'ready'; status = 'Recording cancelled before opening inputs'; take = null }
        break
      case 'i': if (!captureTask && inputs().length) inputIndex = (inputIndex + 1) % inputs().length; break
      case 'm': if (!captureTask) midiIndex = (midiIndex + 1) % midiChoices().length; break
      case 'space': playWave(); break
      case 'up': scroll -= 3; break
      case 'down': scroll += 3; break
      case 'left': follow = false; start = Math.max(Math.min(0, pairedState?.timelineOffsetSeconds ?? 0), start - span / 2); break
      case 'right': follow = false; start += span / 2; break
      case 'f': follow = !follow; break
      case 'e':
        if (phase === 'saved' && !exportTask) {
          const target = exportRoot && take === directory ? join(exportRoot, `midi-${randomUUID()}`) : take
          exportTask = (async () => {
            if (target !== take) await mkdir(target, { recursive: true, mode: 0o700 })
            const paths = await exportMidiClips(timeline, target)
            status = `${paths.length} MIDI 2.0 clips exported to ${target}`
          })().catch(error => { status = error.message }).finally(() => { exportTask = null; draw() })
        }
        break
      default:
        let nextSpan
        if (text === '+' || text === '=') nextSpan = span / 2
        else if (text === '-') nextSpan = span * 2
        else return
        if (!(Number.isFinite(nextSpan) && nextSpan > 0)) return
        span = nextSpan
        // A visible column cannot be finer than a PCM frame.
        if (timeline) span = Math.max(span, widthInFrames() / timeline.sampleRate)
    }
    draw()
  }
  const widthInFrames = () => Math.max(1, (process.stdout.columns || 80) - 9)
  const onEnd = () => finish(), onSignal = () => finish(), onAbort = () => finish()
  const resize = () => draw()
  emitKeypressEvents(process.stdin)
  process.stdin.setRawMode(true); process.stdin.resume()
  process.stdin.on('keypress', keypress); process.stdin.on('end', onEnd)
  process.stdout.on('resize', resize)
  for (const name of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(name, onSignal)
  signal?.addEventListener('abort', onAbort, { once: true })
  if (!embedded) process.stdout.write('\x1b[?1049h\x1b[?25l\x1b[2J')
  const timer = setInterval(() => { if (dirty || pairedState?.kind === 'playing') draw() }, 100)
  try {
    if (signal?.aborted) finish()
    draw()
    // Discovery is not recording. It never opens an input stream.
    const [audio, midiOutputs] = await Promise.allSettled([devices({ signal: discoveryAbort.signal }), midiDestinations({ signal: discoveryAbort.signal })])
    if (audio.status === 'fulfilled') available = audio.value
    else if (!discoveryAbort.signal.aborted) status = audio.reason.message
    if (midiOutputs.status === 'fulfilled') destinations = midiOutputs.value
    else if (!discoveryAbort.signal.aborted) status = midiOutputs.reason.message
    if (discoveryAbort.signal.aborted) return
    if (input !== undefined) {
      inputIndex = inputs().findIndex(device => device.id === input)
      if (inputIndex < 0) throw new Error('Selected audio input is unavailable')
    }
    if (midi !== undefined) {
      midiIndex = midiChoices().findIndex(source => source.id === midi)
      if (midiIndex < 0) throw new Error('Selected MIDI input is unavailable')
    }
    if (directory) {
      timeline = await readCapture(directory, { signal: discoveryAbort.signal })
      phase = timeline.manifest.state === 'recorded' ? 'saved' : 'failed'
      status = timeline.manifest.failure ?? status
    } else phase = available ? 'ready' : 'failed'
    draw()
    if (signal?.aborted) finish()
    await done
  } catch (error) {
    if (!discoveryAbort.signal.aborted) throw error
  } finally {
    closed = true
    clearInterval(timer)
    process.stdin.off('keypress', keypress); process.stdin.off('end', onEnd)
    process.stdout.off('resize', resize)
    for (const name of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.off(name, onSignal)
    signal?.removeEventListener('abort', onAbort)
    captureIntent?.abort()
    capture?.stop(); stopPlayer()
    for (const child of players.keys()) child.kill('SIGTERM')
    await Promise.allSettled([captureTask, ...players.values(), exportTask, playbackTask])
    if (!embedded) {
      process.stdout.write('\x1b[?25h\x1b[?1049l')
      process.stdin.setRawMode(wasRaw ?? false); process.stdin.pause()
    }
  }
}
