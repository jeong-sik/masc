import { arrangementRoute, selectArrangementRoute } from './arrangement-playback.mjs'
import { mkdtemp, rm, writeFile, copyFile } from 'node:fs/promises'
import { constants } from 'node:fs'
import { join, resolve, dirname } from 'node:path'
import { tmpdir } from 'node:os'
import { randomUUID } from 'node:crypto'
import { emitKeypressEvents } from 'node:readline'
import { Worker } from 'node:worker_threads'
import { Note } from 'tonal'
import { GM_DRUM_CHANNEL } from './sequencer-project.mjs'
import { newEditor, editorCommand, editorAction, selectedNote, selectedNotes, editorView, editorAxis, editorHarmony, editorMeters, editorSound, stepInputEffect } from './sequencer-editor.mjs'
import { loadProject, saveProject, projectMidi } from './sequencer-files.mjs'
import { sourceTickAtSeconds, sourceSecondsAtTick } from './midi-source-playback.mjs'
import { sourceExpressions, selectedExpression, sourceTempos, selectedTempo, sourceMeters, selectedMeter } from './midi-source-editor.mjs'
import { safeText } from './terminal.mjs'
import { barAt, isBarStart, beatText } from './meter-bars.mjs'
import { fitLine, cellSegments, bold, dim, inverse, red, green, yellow, blue, magenta, cyan } from './terminal-style.mjs'
import { StatusReader } from './status-reader.mjs'
import { openPlayback } from './playback.mjs'
import { InstrumentPicker, pickerFooter, projectSoundLabel } from './instruments.mjs'
import { defaultStateDirectory, snapshotWriter } from './vst.mjs'
import { renderVstPhrase } from './sequencer-vst.mjs'
import { openVstSession } from './vst-session.mjs'
import { captureVstSound } from './project-sound-files.mjs'
import { captureFluidSound, isFluidSound, renderFluidSound } from './soundfont.mjs'
import { openStepInput, sameStepContext, stepControl } from './step-input.mjs'
import { phraseBacking } from './phrase-backing.mjs'
import { MidiSourcePicker } from './midi-source-picker.mjs'

const help = [
  ':soundfont-fluid [SF2_PATH] saves a FluidSynth SF2; its control-block timing is reported with the selected sound.',
  ':step-input chooses a MIDI keyboard; :step-input SOURCE_UID arms it directly; :step-stop drains.',
  ':step-input [SOURCE_UID] --monitor also plays the selected VST or bound FluidSynth sound through the audio output.',
  ':practice-input [SOURCE_UID] plays live on this track while the other audible phrase tracks repeat; no note edits.',
  ':practice-record PATH [SOURCE_UID] records original MIDI and exact timing into a new take folder; :step-stop saves.',
  ':step-diagnostics PATH exports the current/last monitor output counters and failure.',
  ':step-length 1/3 sets next note length; :step-rest [LENGTH] moves without editing notes.',
  'Lengths/rests use beats or source SMPTE frames; release held keys before changing them.',
  'Release all keys to insert/advance by note length; cursor/track edits stop input and monitoring.',
  'Source :events toggles expression list; Up/Down selects, Enter edits value, +/- changes, x removes.',
  ':cc CTRL VALUE [AT] :bend VALUE [AT] :program VALUE [AT] :pressure VALUE [AT] :poly-pressure KEY VALUE [AT]',
  ':event ID; :event-value VALUE; :event-move AT; :event-set KIND VALUES; :event-channel CH; :event-remove',
  ':event-before first-note|EVENT_ID orders this expression at the same tick; :event-order-reset restores natural order',
  'Source :tempos lists tempo events; :tempo BPM [AT]; :tempo-event ID; :tempo-value BPM; :tempo-move AT; :tempo-remove',
  'Source :meters lists time signatures; :meter NUM DEN [AT [CLOCKS NOTATED32NDS]]; :meter-event ID; :meter-value NUM DEN [CLOCKS NOTATED32NDS]; :meter-move AT; :meter-remove',
  ':arrange snapshots this phrase into backing; q returns to this draft',
  'Source seek/resume restores channel state; unknown initial or opaque device state is an error.',
  'Arrow keys: time/pitch; Shift+arrows: move note; Enter/x: insert/remove note',
  ':select-notes START END [LOW HIGH] selects onsets; :select-all; Esc clears selection',
  'Ctrl+A: select all; Alt+C/X/V: copy/cut/paste notes; Shift+arrows and x/Delete act on selected notes',
  ':copy-notes :cut-notes :paste-notes [AT [SEMITONES]] :delete-notes :move-notes OFFSET SEMITONES',
  ':quantize-notes GRID snaps selected attacks only; lengths, dynamics and other notes remain intact.',
  ':velocity-notes VALUE sets selected attacks; :velocity-add-notes DELTA shifts their dynamics (1–127).',
  'Tab: track; n: new track; m: mute; o: solo; u/y: undo/redo',
  '[/]: halve/double note length; +/-: velocity; g: grid; l: loop; Space: play/pause',
  '{/}: loop from/to the bar under the cursor; </>: one bar shorter/longer; :bars N sets the length',
  's: save; r: recording; q/Esc: save and return; : opens command input',
  'Positions/lengths accept exact decimals or integer fractions: 8.3, 1/3; phrase/PPQ beats or source SMPTE frames.',
  'Values must fit whole native ticks; :move-notes accepts signed offsets. Exponents/hex are refused.',
  ':note C4 0 1 96              pitch, beat, duration, optional velocity',
  ':chord Cmaj7 0 4 drop2 4 0  symbol, beat, duration, mode, octave, inversion',
  ':revoice Cmaj7 drop2 4 0  change cursor voices; retain timing/dynamics; u:compare',
  ':revoice-led 0 12 drop2 C3 C5 Dm7 G7 Cmaj7 changes exact onset groups, retaining rhythm/dynamics; u:compare',
  ':harmony mix|track lists key-set changes; arrows choose, Enter returns to notes, Esc closes',
  ':harmony-export PATH saves the complete ready analysis without replacing a file',
  ':progression 0 4 rootless Dm7 G7 Cmaj7',
  ':progression-led 0 4 drop2 C3 C5 Dm7 G7 Cmaj7 minimizes total movement inside an inclusive register',
  ':tempo 120    :length 32    :meter 3 4    :loop 4 12',
  ':loop START END selects and enables repetition; l toggles it while retaining the range.',
  ':transpose -12    :quantize 0.25    :duplicate 8   (selected track)',
  ':track-add Bass    :track 2    :program 33    :rename Bass',
  ':drum-track Drums creates GM channel 10; :note 36 0 0.25 100 inserts a drum hit',
  ':level 100    :pan 64        track level and pan, each 0–127',
  ':cursor 4 C3    :title My phrase    :undo    :redo    :mute    :solo',
  ':save-as /path/song.json    :export /path/song.mid    :wave /path/song.wav',
  'Close, drop2 and rootless voicings use Tonal. Chord labels are candidates.',
  ':output device-UID selects an audio output; --devices lists device identities.',
  ':midi-output ID sends phrases to a MIDI destination; :audio returns to audio.',
  ':seek 4 moves playback to quarter-note beat 4; :stop ends the transport.',
  'i: choose VST/preset or explicit SoundFont; first audio playback opens the picker.',
  'VST presets own the sound; phrase program/bank messages do not replace them.',
  'Imported MIDI: source ticks retain tempo/expression; :pattern N selects SMF2.',
  'Use :channel 1–16 or :select event-ID for source notes sharing a cursor.',
  'Source: choose a VST or :midi-output ID; selected SMF2 and SMPTE performances are supported.',
  'Multiple source ports: :midi-port PORT ID for each port (0–127).',
  'Source :loop START END chooses a session-local source range; l toggles MIDI / rendered VST window looping.',
]

// A status line is information or a failure; only a failure is drawn as one.
const notice = text => ({ text, failed: false })
const failure = text => ({ text, failed: true })
// Red stays free for failures.
const trackColors = [cyan, green, magenta, yellow, blue]
const blackKeys = new Set([1, 3, 6, 8, 10])
const transportStyles = { playing: [bold, green], paused: [cyan], rendering: [yellow], starting: [yellow], stopped: [dim], practicing: [magenta] }
const cursorRow = selected => selected ? [bold, cyan] : []
// The loop as bars when both ends sit on bar lines, else in axis units.
function loopLabel(view, axis, meters) {
  const { start, end } = view.loop, limit = view.displayLength ?? view.length
  if (meters && start < end && isBarStart(start, meters, axis.per) && (end === limit || isBarStart(end, meters, axis.per))) {
    const firstBar = barAt(start, meters, axis.per).bar, lastBar = barAt(end - 1, meters, axis.per).bar
    return firstBar === lastBar ? `bar ${firstBar}` : `bars ${firstBar}–${lastBar}`
  }
  return `${start / axis.per}–${end / axis.per} ${axis.label}`
}

export async function viewSequencer({ path, root = resolve('music-projects'), embedded = false, signal,
  soundfontPath, sessionRoot, input, midi, output, midiOutput, initialDocument, pattern, initialPortBindings = [],
  stateDirectory = defaultStateDirectory() } = {}) {
  if (!process.stdin.isTTY || !process.stdout.isTTY) throw new Error('Sequencer requires a terminal')
  if (path && initialDocument) throw new Error('Open a saved document or import MIDI, one at a time')
  const loaded = path ? await loadProject(path, { signal }) : null
  if (signal?.aborted) return
  if (loaded?.project.kind === 'arrangement') {
    const { viewArrangement } = await import('./arrangement-tui.mjs')
    return viewArrangement({ loaded, root, embedded, signal, output, midiOutput, stateDirectory })
  }
  if (output !== undefined && midiOutput !== undefined) throw new Error('Choose an audio output or a MIDI destination')
  let editor = newEditor(initialDocument ?? loaded?.project, { pattern }), revision = loaded?.revision ?? null
  path = loaded?.path ?? join(root, `phrase-${randomUUID()}.json`)
  const initialSnapshot = editor.project
  let saved = loaded?.project, status = notice('Enter a note or :help'), prompt = null, showHelp = false
  const statusReader = new StatusReader()
  let loop = false, accepting = true, closed = false, suspended = false, task = Promise.resolve(), childTask = null
  let harmony = null
  let stepInput = null, stepHeld = 0
  let lastStepReport = null
  let sourceMenuOwner = null, openedSourceMenuOwner = null
  const stepOwners = new Set()
  let selectedOutput = output
  let selectedMidiOutput = midiOutput, portBindings = structuredClone(initialPortBindings)
  const sessionAbort = new AbortController()
  const directory = await mkdtemp(join(tmpdir(), 'masc-sequencer-'))
  const worker = new Worker(new URL('./sequencer-worker.mjs', import.meta.url))
  // The chosen VST stays loaded across plays until the editor closes.
  const vstSession = openVstSession()
  const jobs = new Map(), players = new Map()
  const nativeRenders = new Set(), observations = new Set()
  const audioInstrument = () => editor.project.sound ?? { kind: 'unselected' }
  const statusBody = () => [status.text, '', `Instrument: ${projectSoundLabel(audioInstrument())}`,
    `Project: ${path}`].join('\n')
  let currentVstRender = null, pendingSound = null
  const writeSnapshot = snapshotWriter(stateDirectory)
  let jobNumber = 0, generation = 0, transport = { kind: 'stopped' }, workerFailure = null, pendingDraw = null
  const wasRaw = process.stdin.isRaw
  let finish
  const done = new Promise(resolve => { finish = () => { accepting = false; resolve() } })
  const dirty = () => editor.project !== saved
  function observe(fields) {
    const pending = writeSnapshot({ ...fields, view: 'phrase', project_path: path,
      document_kind: editor.project.kind ?? 'phrase' })
    observations.add(pending)
    pending.catch(error => { status = failure(`VST observation: ${error.message}`); draw() })
      .finally(() => observations.delete(pending))
  }
  function chooseInstrument(choice) {
    task = task.then(() => {
      if (!accepting || closed || suspended) return
      stop()
      if (choice.kind === 'vst' || choice.kind === 'fluid-selection') {
        const capture = choice.kind === 'vst' ? captureVstSound(choice.selection, { run: vstSession.run }) : captureFluidSound(choice.path ?? soundfontPath)
        let cancelled = false
        const owned = { cancel() { if (!cancelled) { cancelled = true; capture.cancel() } } }
        pendingSound = owned
        owned.promise = capture.promise.then(sound => {
          task = task.then(() => {
            if (cancelled || pendingSound !== owned || !accepting || closed || suspended) return
            pendingSound = null
            adoptSound(sound, choice.preview !== false)
          }).catch(error => { status = failure(error.message) }).finally(draw)
          return task
        }).catch(error => {
          if (!cancelled && pendingSound === owned && accepting && !closed) status = failure(error.message)
        }).finally(() => { if (pendingSound === owned) pendingSound = null; nativeRenders.delete(owned); draw() })
        nativeRenders.add(owned)
      } else adoptSound(choice)
    }).catch(error => { status = failure(error.message) }).finally(draw)
  }
  function adoptSound(sound, preview = true) {
      // Stop the previous sound's preview while its selection still describes
      // it, so play() renders the adopted sound instead of pausing the old one.
      stopPlayback()
      clearHarmony()
      editor = editorSound(editor, sound)
      selectedMidiOutput = undefined; portBindings = []
      status = notice(`Selected ${projectSoundLabel(sound)}`)
      if (preview) play()
  }
  const picker = new InstrumentPicker({ directory: stateDirectory, notify: draw,
    active: () => {
      const sound = audioInstrument()
      return sound.kind === 'vst' ? sound.selection : sound.kind === 'soundfont' ? null : undefined
    },
    selected: selection => chooseInstrument({ kind: 'vst', selection }),
    soundfont: () => chooseInstrument(editor.project.kind === 'midi-source'
      ? { kind: 'fluid-selection' } : { kind: 'soundfont' }),
    failed: error => { status = failure(`VST: ${error.message}`); draw() } })
  const sourcePicker = new MidiSourcePicker({ notify: draw, selected(source) {
    const monitor = openedSourceMenuOwner?.monitor === true
    const practice = openedSourceMenuOwner?.practice === true
    const recording = openedSourceMenuOwner?.recording
    task = task.then(() => { if (accepting && !closed && !suspended) startStepInput(source, monitor, practice, recording) })
      .catch(error => { status = failure(error.message) }).finally(draw)
  } })
  const fit = line => fitLine(line, process.stdout.columns || 80)
  function playTick() {
    if (!['playing', 'paused'].includes(transport.kind)) return editor.tick
    const view = editorView(editor), per = editorAxis(editor).per
    const start = loop ? view.loop.start : 0
    const elapsed = transport.position + (transport.kind === 'playing' ? (performance.now() - transport.since) / 1000 : 0)
    const seconds = Math.min(loop ? elapsed % transport.duration : elapsed, transport.phraseDuration ?? transport.duration)
    if (editor.project.kind === 'midi-source') return sourceTickAtSeconds(editor.performance,
      Math.min(transport.sourceWindow?.endSeconds ?? Infinity, seconds + (transport.sourceWindow?.startSeconds ?? 0)))
    return start + (loop ? seconds % transport.duration : seconds) / 60 * view.tempo * per
  }
  function draw() {
    if (closed || suspended || pendingDraw) return
    // A paste can deliver a whole command in one input chunk. Rendering each
    // character fills the synchronous TTY output and delays subsequent decisions.
    pendingDraw = setImmediate(() => { pendingDraw = null; drawNow() })
  }
  function drawNow() {
    if (closed || suspended) return
    const reading = statusReader.render(process.stdout)
    if (reading !== null) { process.stdout.write(reading); return }
    const rows = process.stdout.rows || 24, cols = Math.max(1, (process.stdout.columns || 80) - 8)
    const project = editorView(editor), axis = editorAxis(editor), per = axis.per, track = project.tracks[editor.track], current = selectedNote(editor)
    const percussion = editor.project.kind !== 'midi-source' && track.channel === GM_DRUM_CHANNEL
    const noteName = pitch => percussion ? String(pitch) : Note.fromMidi(pitch)
    const selection = new Set(selectedNotes(editor).map(note => note.id))
    const at = editorHarmony(editor)
    const trackColor = trackColors[editor.track % trackColors.length]
    // Bars follow the phrase meter or the imported signature map; SMPTE
    // frames have no bars. A map that cannot be read is shown, not drawn.
    let meters = null, meterProblem = null
    try { meters = editorMeters(editor) } catch (error) { meterProblem = error.message }
    // The cursor is shown exactly, as commands take it. A moving playhead is
    // cut down to a hundredth of a beat first, so it never reads one ahead.
    const position = (tick, rounded = false) => {
      if (rounded) tick = Math.floor(tick * 100 / per) * per / 100
      const beats = `${rounded ? beatText(tick / per) : tick / per} ${axis.label}`
      if (!meters) return meterProblem ? `${beats} (bars unavailable: ${meterProblem})` : beats
      const { bar, beat } = barAt(tick, meters, per)
      return `bar ${bar} beat ${beatText(beat)} · ${beats}`
    }
    const playing = ['playing', 'paused'].includes(transport.kind)
    const playTime = playing ? playTick() : null
    const playhead = Number.isFinite(playTime) ? playTime : null
    const state = stepInput?.kind === 'practice-input' ? 'practicing' : transport.kind
    const statusLine = [...(stepInput ? [[`${stepInput.kind === 'practice-input' ? 'MIDI practice' : 'MIDI step'} · ${stepHeld} held · `, []]] : []),
      [status.text, status.failed ? [bold, red] : []]]
    const lines = [
      [[project.title, [bold]], ...(dirty() ? [[' *', [bold, yellow]]] : []),
        [` · ${project.timingLabel ?? `${project.tempo} BPM`} · ${project.meter.join('/')} · ${(project.displayLength ?? project.length) / per} ${axis.label} · `, []],
        [state, transportStyles[state] ?? []], ...(loop ? [[' · LOOP', [bold, cyan]]] : [])],
      [[`Track ${editor.track + 1}/${project.tracks.length}: `, []], [track.name, [bold, trackColor]],
        [` · ${percussion ? 'GM drums · ' : ''}${track.detail ?? `ch ${track.channel + 1} · program ${track.program} · level ${track.level} · pan ${track.pan}`}`, []],
        ...(track.muted ? [[' · MUTED', [dim]]] : []), ...(track.solo ? [[' · SOLO', [bold, yellow]]] : []), [` · ${track.notes.length} notes`, []]],
      `Cursor ${position(editor.tick)} · ${noteName(editor.pitch)} · grid ${editor.step / per} · length ${(current?.duration ?? editor.duration) / per} · input length ${editor.duration / per} · velocity ${current?.velocity ?? editor.velocity}${selection.size ? ` · ${selection.size} selected` : ''}${editor.noteClipboard ? ` · ${editor.noteClipboard.notes.length} copied` : ''}`,
      [['Chord candidates: ', []], [at.candidates.join(' / ') || '—', at.candidates.length ? [bold, cyan] : [dim]], [` · ${at.notes.join(' ')}`, []]],
      statusLine,
    ]
    if (sourcePicker.view) {
      lines.length = 0
      const view = sourcePicker.view
      lines.push(openedSourceMenuOwner?.practice ? 'Choose live practice MIDI source' : 'Choose MIDI step-input source', statusLine)
      if (view.kind === 'loading') lines.push('Reading MIDI sources…')
      else if (view.kind === 'failed') lines.push(view.error)
      else {
        if (!view.sources.length) lines.push('No available MIDI sources. Connect a keyboard, then refresh.')
        if (view.cursor < 0 && view.sources.length) lines.push('Previous source is unavailable; choose explicitly.')
        const height = Math.max(1, rows - 6), first = Math.max(0, view.cursor - height + 1)
        for (let index = first; index < Math.min(view.sources.length, first + height); index++) {
          const source = view.sources[index]
          lines.push([[`${view.cursor === index ? '›' : ' '} ${source.name} · ${source.id}`, cursorRow(view.cursor === index)]])
        }
      }
    } else if (picker.view) {
      lines.length = 0
      const sound = audioInstrument()
      const selectedSound = projectSoundLabel(sound)
      lines.push([[picker.view.title, [bold]]], [[`${selectedSound} · `, []], ...statusLine])
      if (picker.view.query !== undefined) lines.push(`${picker.view.kind === 'preset_name' ? 'Name' : picker.view.kind === 'preset_path' ? 'Path' : picker.view.searching ? 'Search' : 'Filter'}: ${picker.view.query}`)
      const items = picker.items(), height = Math.max(1, rows - 6)
      const start = Math.max(0, picker.view.cursor - height + 1)
      for (let i = start; i < Math.min(items.length, start + height); i++) {
        const selected = i === picker.view.cursor
        lines.push([[selected ? '›' : ' ', []], [picker.isActive(items[i]) ? '●' : ' ', [bold, green]], [` ${items[i].name}`, cursorRow(selected)]])
      }
    } else if (harmony) {
      lines[3] = `Harmony · ${harmony.scope.kind === 'mix' ? 'audible mix' : 'selected track/channel'} · exact key durations · candidates`
      if (harmony.kind === 'loading') lines.push('Analyzing in worker…')
      else if (harmony.kind === 'failed') lines.push(harmony.error)
      else {
        const capacity = Math.max(1, rows - 10)
        const first = Math.max(0, harmony.cursor - capacity + 1)
        for (const [index, row] of harmony.result.rows.slice(first, first + capacity).entries()) {
          const at = row.kind === 'point' ? `${row.start / per} point` : `${row.start / per}–${row.end / per}`
          lines.push([[`${first + index === harmony.cursor ? '›' : ' '} ${at} ${axis.label} · ${row.candidates.join(' / ') || (row.pitches.length ? 'unclassified' : 'rest')} · ${row.notes.join(' ')}`, cursorRow(first + index === harmony.cursor)]])
        }
        if (!harmony.result.rows.length) lines.push('No key intervals in this performance')
      }
    } else if (showHelp) lines.push(...help)
    else if (editor.project.kind === 'midi-source' && editor.eventView === 'meter') {
      const events = sourceMeters(editor), capacity = Math.max(1, rows - 10)
      const selected = events.findIndex(event => event.id === editor.selectedMeterID)
      const first = Math.max(0, selected - capacity + 1)
      lines.push('Time signatures · Up/Down selects · Shift+Left/Right moves · Enter edits · :meters returns to notes')
      for (const event of events.slice(first, first + capacity)) lines.push([[
        `${event.id === editor.selectedMeterID ? '>' : ' '} ${event.id} · track ${event.track + 1} · ${event.tick / per} ${axis.label} · ${event.numerator}/${event.denominator} · ${event.clocks} clocks/click · ${event.notated32nds} notated 32nds/quarter`, cursorRow(event.id === editor.selectedMeterID)]])
      if (!events.length) lines.push('No recognized time signatures. :meter NUM DEN AT inserts one; the default is 4/4.')
      lines.push('Time signatures retain note/tempo timestamps; the source axis remains beats or SMPTE frames.')
    }
    else if (editor.project.kind === 'midi-source' && editor.eventView === 'tempo') {
      const events = sourceTempos(editor), capacity = Math.max(1, rows - 10)
      const selected = events.findIndex(event => event.id === editor.selectedTempoID)
      const first = Math.max(0, selected - capacity + 1)
      lines.push('Tempo map · Up/Down selects · Shift+Left/Right moves · Enter edits BPM · :tempos returns to notes')
      for (const event of events.slice(first, first + capacity)) lines.push([[
        `${event.id === editor.selectedTempoID ? '>' : ' '} ${event.id} · track ${event.track + 1} · ${event.tick / per} ${axis.label} · ${event.value} BPM · ${event.micros} µs/quarter`, cursorRow(event.id === editor.selectedTempoID)]])
      if (!events.length) lines.push('No explicit tempo events. :tempo BPM AT inserts one; source default is 120 BPM.')
      if (editor.info.timing.kind === 'smpte') lines.push('SMPTE frame timing is independent of this tempo metadata.')
    }
    else if (editor.project.kind === 'midi-source' && editor.eventView) {
      const events = sourceExpressions(editor), capacity = Math.max(1, rows - 10)
      const selected = events.findIndex(event => event.id === editor.selectedExpressionID)
      const first = Math.max(0, selected - capacity + 1)
      lines.push('Expression events · Up/Down selects · Shift+Left/Right moves · Enter edits value · :events returns to notes')
      for (const event of events.slice(first, first + capacity)) lines.push([[
        `${event.id === editor.selectedExpressionID ? '>' : ' '} ${event.id} · ${event.tick / per} ${axis.label} · port ${event.port} ch ${event.channel + 1} · ${event.kind}${event.controller === undefined ? '' : ' ' + event.controller}${event.pitch === undefined ? '' : ' ' + Note.fromMidi(event.pitch)} · ${event.value}`, cursorRow(event.id === editor.selectedExpressionID)]])
      if (!events.length) lines.push('No expression events in this track/channel. :channel CH then :cc CTRL VALUE AT inserts one.')
    } else {
      // While a transport plays, the window follows the playhead, held to the
      // last cell through a release tail. Paused or stopped, it follows the cursor.
      const anchor = transport.kind === 'playing' && playhead !== null ? Math.min(playhead, project.length - 1) : editor.tick
      const span = editor.step * cols, first = Math.floor(anchor / span) * span
      const playColumn = playhead === null ? null : Math.floor((playhead - first) / editor.step)
      const barStart = tick => meters ? isBarStart(tick, meters, per) : tick % per === 0
      const beatStart = tick => meters ? Number.isInteger(barAt(tick, meters, per).beat) : false
      const ruler = Array.from({ length: cols }, (_, x) => {
        const tick = first + x * editor.step
        if (tick >= project.length) return [' ', []]
        const [glyph, styles] = x === playColumn ? ['▼', [bold, green]]
          : barStart(tick) ? ['|', [bold]] : beatStart(tick) ? ['+', []] : ['·', [dim]]
        // The loop range is drawn on the ruler, bold while repetition is on.
        const inLoop = project.loop.start <= tick && tick < project.loop.end && x !== playColumn
        return [glyph, inLoop ? [...new Set([...styles.filter(style => style !== dim), cyan, ...(loop ? [bold] : [])])] : styles]
      })
      // Bar numbers sit under their bar lines while they do not overlap.
      const numbers = Array.from({ length: cols }, () => ' ')
      for (let x = 0; meters && x < cols; x++) {
        const tick = first + x * editor.step
        if (tick >= project.length || !barStart(tick)) continue
        const label = String(barAt(tick, meters, per).bar)
        if (x + label.length > cols || numbers.slice(Math.max(0, x - 1), x + label.length).some(char => char !== ' ')) continue
        for (const [offset, char] of [...label].entries()) numbers[x + offset] = char
      }
      lines.push([['       ', []], ...cellSegments(ruler)], meters ? [['  bar  ', [dim]], [numbers.join(''), [bold]]]
        : `       ${axis.label} ${first / per} → ${Math.min(project.length, first + cols * editor.step) / per}`)
      const height = Math.max(1, rows - 11), high = Math.min(127, Math.max(height - 1, editor.pitch + Math.floor(height / 2)))
      for (let y = 0; y < height; y++) {
        const pitch = high - y
        if (pitch < 0) break
        const cells = Array.from({ length: cols }, (_, x) => first + x * editor.step >= project.length ? [' ', []] : pitch % 12 === 0 ? ['─', []] : ['·', [dim]])
        for (const note of track.notes) {
          if (note.pitch !== pitch) continue
          const left = Math.max(0, Math.floor((note.start - first) / editor.step))
          const right = Math.min(cols - 1, Math.ceil((note.start + note.duration - first) / editor.step) - 1)
          for (let x = left; x <= right; x++) cells[x] = selection.has(note.id) ? ['▓', [bold, yellow]]
            : first + x * editor.step <= note.start ? ['█', [bold, trackColor]] : ['━', [trackColor]]
        }
        // A note under the playhead is sounding; empty cells draw its line.
        if (playColumn !== null && playColumn >= 0 && playColumn < cols && first + playColumn * editor.step < project.length) {
          const [glyph, styles] = cells[playColumn]
          cells[playColumn] = '█━▓'.includes(glyph) ? [glyph, [...styles, inverse]] : ['│', [green]]
        }
        const cursor = Math.floor((editor.tick - first) / editor.step)
        if (pitch === editor.pitch && cursor >= 0 && cursor < cols) cells[cursor] = [current ? '◆' : '◇', [bold, inverse]]
        const label = percussion ? [] : pitch % 12 === 0 ? [bold] : blackKeys.has(pitch % 12) ? [dim] : []
        lines.push([[noteName(pitch).padStart(5), label], ['  ', []], ...cellSegments(cells)])
      }
      const instrument = projectSoundLabel(audioInstrument())
      const destination = portBindings.length ? portBindings.map(binding => `${binding.port}→${binding.destination}`).join(', ')
        : selectedMidiOutput === undefined ? selectedOutput ?? 'system default' : `MIDI ${selectedMidiOutput}`
      lines.push(`Playhead ${playhead === null ? '—' : position(playhead, true)} · loop ${loop ? 'on' : 'off'} ${loopLabel(project, axis, meters)} · ${instrument} · output ${destination} · ${path}`)
    }
    let output = '\x1b[H'
    for (let row = 1; row <= rows; row++) output += `\x1b[${row};1H\x1b[2K`
    lines.slice(0, rows - 2).forEach((line, row) => { output += `\x1b[${row + 1};1H${fit(line)}` })
    output += `\x1b[${rows - 1};1H${fit(sourcePicker.view ? '↑/↓:choose  Enter:arm keyboard  r:refresh  Esc/q:cancel' : picker.view ? pickerFooter(picker.view) : prompt !== null ? `:${prompt}` : harmony ? '↑/↓:choose interval  Enter:go to notes  :commands  Esc/q:return' : 'Space:play  i:instrument  Enter:note  arrows:cursor  Tab:track  :commands  ?:help')}`
    if (!picker.view) output += `\x1b[${rows};1H${fit(sourcePicker.view ? openedSourceMenuOwner?.monitor ? 'Selection arms step input with the chosen instrument and audio output.' : 'Selection opens MIDI input only; no audio or output route.' : harmony && !picker.view ? ':harmony mix|track  :harmony-export PATH · analysis preserves the musical document' : 'Ctrl-L:status  s:save  l:loop  { }:loop bars  < >:bars  r:recording  q:save/back  n:new track  m:mute  o:solo')}`
    process.stdout.write(output)
  }
  function stop(options) {
    stepInput?.stop(options)
    pendingSound?.cancel(); pendingSound = null
    stopPlayback()
  }
  // Edits, loop and Space end playback only. A pending sound capture is
  // retired by stop: :stop, route changes, reselection, record, arrange, close.
  function stopPlayback() {
    generation++
    if (transport.cancel) Atomics.store(transport.cancel, 0, 1)
    transport.native?.cancel()
    transport.handle?.stop()
    if (currentVstRender || transport.native && audioInstrument().kind === 'vst') observe({ state: 'stop_requested',
      selection: audioInstrument().kind === 'vst' ? audioInstrument().selection : null, render: currentVstRender })
    currentVstRender = null
    transport = { kind: 'stopped' }
  }
  function render(snapshot, options = {}) {
    if (!accepting) throw new Error('Sequencer is closing')
    if (workerFailure) throw new Error(workerFailure)
    if (snapshot.kind === 'midi-source' && !['midi', 'vst-midi', 'fluid-plan', 'arrangement', 'harmony'].includes(options.format)) throw new Error('Source audition requires FluidSynth, a VST instrument or MIDI output')
    const id = ++jobNumber, cancel = new Int32Array(new SharedArrayBuffer(4)), path = join(directory, `${id}.${options.format === 'midi' ? 'json' : options.format === 'vst-midi' ? 'mid' : 'wav'}`)
    const promise = new Promise((resolve, reject) => { jobs.set(id, { resolve, reject, cancel }) })
    worker.postMessage({ id, path, project: snapshot, cancel: cancel.buffer, options: { ...options, soundfontPath } })
    return { promise, cancel }
  }
  function clearHarmony() {
    if (harmony?.kind === 'loading') Atomics.store(harmony.job.cancel, 0, 1)
    harmony = null
  }
  function analyze(scope) {
    clearHarmony(); showHelp = false
    const selectedScope = scope === 'mix' ? { kind: 'mix' } : { kind: 'track',
      id: editorView(editor).tracks[editor.track].id, ...(editor.channel === undefined ? {} : { channel: editor.channel }) }
    let job
    try { job = render(editor.project, { format: 'harmony', pattern: editor.pattern, scope: selectedScope }) }
    catch (error) {
      // An admitted analysis keeps its note keys even when preparation cannot
      // start (including close). Otherwise a queued Enter edits the document.
      harmony = { kind: 'failed', scope: selectedScope, error: error.message }
      return
    }
    const owner = { kind: 'loading', scope: selectedScope, job }
    harmony = owner
    job.promise.then(result => {
      if (harmony !== owner || closed || !accepting) return
      const cursor = result.rows.findIndex(row => row.start <= editor.tick && (row.kind === 'point' ? row.start === editor.tick : editor.tick < row.end))
      harmony = { kind: 'ready', scope: selectedScope, result, cursor: Math.max(0, cursor) }
    }).catch(error => {
      if (harmony === owner && !closed) harmony = { kind: 'failed', scope: selectedScope, error: error.message }
    }).finally(draw)
  }
  function changedContext(previous) {
    if (previous.project !== editor.project || previous.pattern !== editor.pattern || previous.track !== editor.track || previous.channel !== editor.channel) clearHarmony()
    if (stepInput && !sameStepContext(previous, editor)) stepInput.cancel()
  }
  function startStepInput(source, monitor = false, practice = false, recording) {
    if (!accepting || closed || suspended || childTask) return
    if (stepInput) throw new Error('Stop the previous step input before starting another')
    if (monitor && (selectedMidiOutput !== undefined || portBindings.length)) throw new Error('Select :audio before instrument input monitoring')
    const backing = practice ? phraseBacking(editor.project, editorView(editor).tracks[editor.track].id, loop) : undefined
    stop(); clearHarmony(); showHelp = false
    const owner = openStepInput({ source, getEditor: () => editor,
      ...(monitor ? { audio: { sound: audioInstrument(), output: selectedOutput, ...(backing ? { backing } : {}) } } : {}),
      ...(practice ? { practice: true } : {}),
      ...(recording ? { recording: { path: resolve(recording.path) } } : {}),
      enqueue(action) {
        const decision = task.then(action)
        task = decision.catch(error => { status = failure(error.message) }).finally(draw)
        return decision
      },
      adoptEditor(next, count) { editor = next; clearHarmony(); status = notice(`Inserted ${count} step notes`) },
      onState(state) { stepHeld = state.held; draw() } })
    stepInput = owner; stepOwners.add(owner)
    status = notice(practice ? 'Opening live practice input and backing' : 'Opening MIDI step input')
    owner.ready.then(info => { if (stepInput === owner && accepting && !closed) { status = notice(`${info.recording ? 'Recording' : info.practice ? 'Practice input' : 'Step input'}${info.monitoring ? ' · instrument monitor' : ''}: ${info.source.name}${info.recording ? ` · ${info.recording.path}` : ''}`); draw() } }, () => {})
    const inputName = practice ? 'Practice input' : 'Step input'
    owner.completion.then(() => { const take = owner.diagnostics?.()?.recording; status = notice(take ? `Take ${take.status}: ${take.path}` : `${inputName} stopped`) },
      error => { const take = owner.diagnostics?.()?.recording; status = failure(`${take ? `Take failed: ${take.path}` : `${inputName} stopped`}: ${error.message}`) }).finally(() => {
      const report = owner.diagnostics?.()
      if (report) lastStepReport = report
      stepOwners.delete(owner)
      if (stepInput === owner) { stepInput = null; stepHeld = 0 }
      draw()
    })
  }
  function renderAudio(snapshot, options = {}) {
    if (!snapshot.sound) throw new Error('Choose an instrument with i before exporting audio')
    if (isFluidSound(snapshot.sound)) {
      const preparation = render(snapshot, { ...options, format: 'fluid-plan' })
      const native = renderFluidSound(snapshot.sound, { preparation, outputPath: join(directory, `${jobNumber}.fluid.wav`) })
      nativeRenders.add(native)
      native.promise.finally(() => nativeRenders.delete(native)).catch(() => {})
      return { promise: native.promise, cancel: preparation.cancel, native }
    }
    if (snapshot.sound.kind === 'soundfont') return render(snapshot, { ...options, format: 'wav' })
    const sound = snapshot.sound, selection = sound.selection
    const preparation = render(snapshot, { ...options, format: 'vst-midi' })
    const native = renderVstPhrase({ preparation, selection, sound, outputPath: join(directory, `${jobNumber}.vst.wav`), stateDirectory, loop: options.loop, run: vstSession.run })
    nativeRenders.add(native)
    native.promise.finally(() => nativeRenders.delete(native)).catch(() => {})
    return { promise: native.promise, cancel: preparation.cancel, native }
  }
  async function startPlayer(wave, id) {
    // Finish the previous owner before a new one can reuse its MIDI keys. Its
    // final note-offs must never cut off the replacement transport's notes.
    await Promise.allSettled([...players.values()])
    if (!accepting || closed || id !== generation) return
    currentVstRender = wave.vst ?? null
    if (wave.vst) observe({ state: 'rendered', selection: wave.selection, render: wave.vst })
    const midiDestination = wave.midiOutput ?? selectedMidiOutput
    const handle = openPlayback({ path: wave.path, output: midiDestination === undefined ? selectedOutput : undefined,
      midiOutput: midiDestination, midiBindings: wave.midiBindings, frameRange: wave.frameRange,
      format: wave.format === 'midi-arrangement' ? 'midi-arrangement' : 'wave', loop, onEvent: event => {
      if (!accepting || closed || id !== generation) return
      if (['playing', 'paused'].includes(event.kind)) {
        const changed = transport.kind !== event.kind
        transport = { kind: event.kind, handle, position: event.currentTime, duration: event.duration,
          phraseDuration: wave.phraseDuration, sourceWindow: wave.sourceWindow, since: performance.now() }
        if (wave.vst && changed) observe({ state: `player_${event.kind}`, selection: wave.selection, render: wave.vst,
          position_seconds: event.currentTime, duration_seconds: event.duration })
      }
      draw()
    } })
    transport = { kind: 'starting', handle }
    handle.ready.catch(error => {
      if (!closed && id === generation) { status = failure(error.message); draw() }
    })
    const settled = handle.completion.then(() => {
      if (!closed && id === generation) { transport = { kind: 'stopped' }; status = notice('Playback finished');
        if (wave.vst) observe({ state: 'player_finished', selection: wave.selection, render: wave.vst }); draw() }
    }, error => {
      if (!closed && id === generation) { transport = { kind: 'stopped' }; status = failure(error.message);
        if (wave.vst) observe({ state: 'failed', selection: wave.selection, render: wave.vst, error: error.message }); draw() }
    }).finally(() => { players.delete(handle) })
    players.set(handle, settled)
    const preview = wave.vst ? `VST: ${wave.selection.name}` : midiDestination !== undefined ? 'MIDI output' : wave.soundfont ? `FluidSynth ${wave.soundfont.engine.version}` : 'SoundFont preview'
    status = notice(`${preview}${wave.clippedSamples > 0 ? ` · ${wave.clippedSamples} samples exceed full scale` : ''}`); draw()
  }
  function play() {
    if (!accepting || suspended || childTask) return
    if (stepInput) throw new Error('Use :step-stop before playback')
    if (transport.kind === 'playing') {
      transport.handle.pause()
      return
    }
    if (transport.kind === 'paused') { transport.handle.resume(); return }
    if (transport.kind !== 'stopped') { stopPlayback(); draw(); return }
    const midiRoute = selectedMidiOutput !== undefined || portBindings.length > 0
    if (!midiRoute && audioInstrument().kind === 'unselected') { picker.open(); return }
    const id = ++generation, options = { loop, pattern: editor.pattern, midiOutput: selectedMidiOutput, portBindings,
      ...(editor.project.kind === 'midi-source' ? { sourceLoop: editor.sourceLoop } : {}) }
    const result = midiRoute ? render(editor.project, { ...options, format: 'midi' }) : renderAudio(editor.project, options)
    transport = { kind: 'rendering', cancel: result.cancel, native: result.native }
    if (result.native && audioInstrument().kind === 'vst') observe({ state: 'rendering', selection: audioInstrument().selection, render: null })
    result.promise.then(wave => startPlayer(wave, id)).catch(error => {
      if (!closed && id === generation) { transport = { kind: 'stopped' }; status = failure(error.message);
        if (result.native && audioInstrument().kind === 'vst') observe({ state: 'failed', selection: audioInstrument().selection, render: null, error: error.message }); draw() }
    })
    draw()
  }
  async function save(target = path) {
    const project = editor.project
    const nextRevision = await saveProject(target, project, target === path ? revision : null)
    path = resolve(target); revision = nextRevision; saved = project; status = notice(`Saved ${path}`)
  }
  async function record() {
    if (!accepting) return
    if (stepInput) throw new Error('Use :step-stop before recording')
    stop(); clearHarmony(); suspended = true; process.stdin.off('keypress', keypress)
    try {
      const { viewSession } = await import('./music-session.mjs')
      if (accepting && !closed) await viewSession({ root: sessionRoot, input, midi, embedded: true, signal: sessionAbort.signal })
    } finally {
      suspended = false
      if (accepting && !closed) { process.stdin.on('keypress', keypress); draw() }
    }
  }
  function arrange() {
    if (!accepting || childTask) return
    if (stepInput) throw new Error('Use :step-stop before opening the arrangement')
    stop(); clearHarmony()
    const expected = generation, snapshot = editor.project
    const route = arrangementRoute({ output: selectedOutput, midiOutput: selectedMidiOutput })
    const bindings = structuredClone(portBindings)
    const job = render(snapshot, { format: 'arrangement', ...(editor.project.kind === 'midi-source' ? { pattern: editor.pattern } : {}) })
    transport = { kind: 'rendering', cancel: job.cancel }; status = notice('Preparing phrase for arrangement')
    let entered = false
    const owned = (async () => {
      try {
        const result = await job.promise
        await Promise.allSettled([...players.values()])
        if (!accepting || closed || generation !== expected) return
        const { viewArrangement } = await import('./arrangement-tui.mjs')
        if (!accepting || closed || generation !== expected) return
        let initialRoute = route
        for (const binding of bindings) initialRoute = selectArrangementRoute(initialRoute,
          { kind: 'midi-port', asset: result.asset, ...binding })
        entered = true; suspended = true; transport = { kind: 'stopped' }
        process.stdin.off('keypress', keypress)
        await viewArrangement({ initialDocument: result.project, root: dirname(path), embedded: true,
          signal: sessionAbort.signal, initialRoute, stateDirectory })
        status = notice('Returned from arrangement; phrase draft retained')
      } catch (error) { if (accepting && generation === expected) { transport = { kind: 'stopped' }; status = failure(error.message) } }
      finally {
        if (entered) { suspended = false; if (accepting && !closed) process.stdin.on('keypress', keypress) }
        if (childTask === owned) childTask = null
        draw()
      }
    })()
    childTask = owned
  }
  async function effect(value, menuOwner = null) {
    if (!accepting && ['play', 'record', 'wave', 'arrange', 'step-input'].includes(value.kind)) return
    switch (value.kind) {
      case 'soundfont-fluid': chooseInstrument({ kind: 'fluid-selection', path: value.path, preview: false }); break
      case 'step-input':
        if (value.source !== undefined) startStepInput(value.source, value.monitor, value.practice, value.recording)
        else {
          if (sourceMenuOwner !== menuOwner) return
          if (stepInput) throw new Error('Use :step-stop before choosing another MIDI source')
          if (!suspended && !childTask) { stop(); clearHarmony(); openedSourceMenuOwner = menuOwner; sourcePicker.open() }
        }
        break
      case 'step-stop': stepInput?.stop(); status = notice('Draining MIDI step input'); break
      case 'step-diagnostics': {
        const report = await stepInput?.inspect() ?? lastStepReport
        if (!report) throw new Error('Open monitored step input before exporting diagnostics')
        await writeFile(value.path, JSON.stringify(report, null, 2) + '\n', { flag: 'wx', mode: 0o600 })
        status = notice(`Exported ${value.path}`); break
      }
      case 'step-length': case 'step-rest': {
        const next = stepInput ? stepInput.control(value) : stepControl(editor, value)
        if (value.kind === 'step-rest') stopPlayback()
        editor = next; clearHarmony()
        status = notice(value.kind === 'step-length' ? 'Input note length changed' : 'Inserted a step rest')
        break
      }
      case 'harmony': analyze(value.scope); break
      case 'harmony-export':
        if (harmony?.kind !== 'ready') throw new Error('Open a ready :harmony analysis before exporting')
        await writeFile(value.path, JSON.stringify(harmony.result, null, 2) + '\n', { flag: 'wx', mode: 0o600 })
        status = notice(`Exported ${value.path}`); break
      case 'arrange': arrange(); break
      case 'save': await save(); break
      case 'save-as': await save(value.path); break
      case 'export': await writeFile(value.path, projectMidi(editor.project), { flag: 'wx', mode: 0o600 }); status = notice(`Exported ${value.path}`); break
      case 'wave': {
        const sound = audioInstrument(), exportPath = resolve(value.path)
        try {
          const job = renderAudio(editor.project, { pattern: editor.pattern })
          const wave = await job.promise
          if (accepting && !closed) {
            await copyFile(wave.path, exportPath, constants.COPYFILE_EXCL)
            if (wave.vst) observe({ state: 'exported', selection: wave.selection,
              render: { ...wave.vst, output_path: exportPath }, export_path: exportPath })
            status = notice(`Exported ${value.path}${wave.clippedSamples > 0 ? ' · clipped; lower :level' : ''}`)
          }
        } catch (error) {
          if (sound.kind === 'vst' && accepting && !closed) observe({ state: 'export_failed',
            selection: sound.selection, render: null, export_path: exportPath, error: error.message })
          throw error
        }
        break
      }
      case 'play': play(); break
      case 'loop': stepInput?.stop(); stopPlayback(); loop = true; status = notice('Loop selected'); break
      case 'stop': stop(); break
      case 'output': stop(); portBindings = []; selectedOutput = value.path; selectedMidiOutput = undefined; status = notice(`Audio output: ${selectedOutput}`); break
      case 'midi-output': stop(); portBindings = []; selectedMidiOutput = value.path; status = notice(`MIDI output: ${selectedMidiOutput}`); break
      case 'midi-port': stop(); selectedMidiOutput = undefined; portBindings = [...portBindings.filter(binding => binding.port !== value.port), { port: value.port, destination: value.destination }]; status = notice(`MIDI port ${value.port}: ${value.destination}`); break
      case 'audio': stop(); portBindings = []; selectedMidiOutput = undefined; status = notice(`Audio output: ${selectedOutput ?? 'system default'}`); break
      case 'seek': {
        if (!accepting) return
        if (!transport.handle) throw new Error('Start playback before seeking')
        if (editor.project.kind === 'midi-source') {
          const window = transport.sourceWindow
          if (window && (value.tick < window.start || value.tick > window.end)) throw new Error('Seek must be within the source loop range')
          const seconds = window && value.tick === window.end ? transport.duration
            : sourceSecondsAtTick(editor.performance, value.tick) - (window?.startSeconds ?? 0)
          transport.handle.seek(window ? Math.min(transport.duration, seconds) : seconds); break
        }
        const view = editorView(editor), per = editorAxis(editor).per
        const start = loop ? view.loop.start : 0
        const end = loop ? view.loop.end : view.length
        // The WAV endpoint is the player's sample-quantized duration. Preserve
        // the musical endpoint instead of rounding it beyond the last sample.
        const seconds = value.tick === end ? transport.duration : (value.tick - start) / per * 60 / view.tempo
        transport.handle.seek(seconds)
        break
      }
      case 'help': showHelp = !showHelp; break
      case 'record': if (!childTask) childTask = record().catch(error => { status = failure(error.message) }).finally(() => { childTask = null }); break
    }
  }
  async function keypress(text, key = {}) {
    if (!accepting || closed || suspended) return
    if (key.ctrl && key.name === 'c') { finish(); return }
    if (sourceMenuOwner) {
      const owner = sourceMenuOwner
      const dismiss = ['escape', 'q'].includes(key.name)
      if (dismiss) sourceMenuOwner = null
      task = task.then(() => {
        // The menu owns keys from command admission, including keys queued
        // before discovery opens, after dismissal, or before view close.
        if (openedSourceMenuOwner !== owner || !sourcePicker.view) return
        if (dismiss) { sourcePicker.close(); openedSourceMenuOwner = null; return }
        if (sourceMenuOwner !== owner) return
        sourcePicker.keypress(text, key)
        if (!sourcePicker.view) { sourceMenuOwner = null; openedSourceMenuOwner = null }
      }).catch(error => { status = failure(error.message) }).finally(draw)
      return
    }
    if (statusReader.keypress(text, key, process.stdout)) { draw(); return }
    if (key.ctrl && key.name === 'l' || prompt === null && !picker.view && text === '!') {
      statusReader.open('Phrase status at open', statusBody())
      draw(); return
    }
    if (picker.view) {
      if (key.name === 's' && !picker.view.searching
          && ['plugins', 'presets'].includes(picker.view.kind)) {
        stop(); status = notice('Stopped'); draw(); return
      }
      try { await picker.keypress(text, key) } catch (error) { status = failure(`VST: ${error.message}`) }
      draw(); return
    }
    if (prompt !== null) {
      if (key.name === 'escape') prompt = null
      else if (key.name === 'backspace') prompt = [...prompt].slice(0, -1).join('')
      else if (key.name === 'return') {
        const line = prompt; prompt = null
        if (statusReader.command(line, 'Phrase status at open', statusBody())) { draw(); return }
        let admittedEffect
        try { admittedEffect = stepInputEffect(line) }
        catch (error) { status = failure(error.message); draw(); return }
        const menuOwner = admittedEffect?.kind === 'step-input' && admittedEffect.source === undefined ? { monitor: admittedEffect.monitor === true, practice: admittedEffect.practice === true, recording: admittedEffect.recording } : null
        if (menuOwner) sourceMenuOwner = menuOwner
        task = task.then(async () => {
          // This command was admitted before close; retain its editor decision.
          // effect() separately refuses new playback/recording/WAV work.
          const result = admittedEffect ? { editor, effect: admittedEffect } : editorCommand(editor, line)
          if (result.editor.project !== editor.project || result.editor.pattern !== editor.pattern) stopPlayback()
          const previous = editor; editor = result.editor; changedContext(previous)
          if (result.effect) await effect(result.effect, menuOwner)
          else status = notice('Edited')
        }).catch(error => { status = failure(error.message) }).finally(() => {
          if (menuOwner && sourceMenuOwner === menuOwner && !sourcePicker.view) sourceMenuOwner = null
          draw()
        })
      } else if (text && !key.ctrl && !key.meta) prompt += safeText(text)
      draw(); return
    }
    if (text === ':') { prompt = ''; draw(); return }
    if (harmony && ['q', 'escape'].includes(key.name)) {
      task = task.then(clearHarmony).finally(draw)
      return
    }
    if (key.name === 'escape' && selectedNotes(editor).length) {
      task = task.then(() => { editor = editorCommand(editor, 'clear-selection').editor }).finally(draw)
      return
    }
    if (['q', 'escape'].includes(key.name)) { finish(); return }
    if (text === '?') { clearHarmony(); showHelp = !showHelp; draw(); return }
    if (key.name === 'n' && !harmony) { prompt = 'track-add '; draw(); return }
    const analysisKey = harmony !== null
    task = task.then(async () => {
      // Drain admitted editor decisions even after input admission closes.
      if (closed && analysisKey) return
      if (harmony) {
        if (harmony.kind === 'ready') {
          if (key.name === 'up' || key.name === 'down') harmony.cursor = Math.max(0, Math.min(harmony.result.rows.length - 1, harmony.cursor + (key.name === 'down' ? 1 : -1)))
          else if (key.name === 'return') {
            const row = harmony.result.rows[harmony.cursor]
            const previous = editor
            if (row) editor = { ...editorAction(editor, { kind: 'move', ticks: row.start - editor.tick,
              pitches: (row.pitches[0] ?? editor.pitch) - editor.pitch }), eventView: undefined }
            changedContext(previous)
            clearHarmony()
          }
        }
        return
      }
      const previous = editor, original = editor.project
      if ((key.ctrl && key.name === 'a') || (key.meta && ['c', 'x', 'v'].includes(key.name))) {
        const command = { a: 'select-all', c: 'copy-notes', x: 'cut-notes', v: 'paste-notes' }[key.name]
        editor = editorCommand(editor, command).editor
        if (editor.project !== original) { stopPlayback(); changedContext(previous); status = notice('Edited selected notes') }
        else status = notice('Note selection updated')
        return
      }
      const eventKind = editor.eventView === 'tempo' ? 'tempo' : editor.eventView === 'meter' ? 'meter' : 'expression'
      switch (key.name) {
        case 'space': play(); break
        case 'i':
          if (stepInput) throw new Error('Use :step-stop before choosing an instrument')
          if (accepting && !suspended && !childTask) { stop(); picker.open() }; break
        case 's': await save(); break
        case 'r': await effect({ kind: 'record' }); break
        case 'l': stepInput?.stop(); stopPlayback(); loop = !loop; break
        case 'tab': editor = editorAction(editor, { kind: 'track' }); break
        case 'return':
          if (editor.eventView) {
            const event = eventKind === 'tempo' ? selectedTempo(editor) : eventKind === 'meter' ? selectedMeter(editor) : selectedExpression(editor)
            if (!event) throw new Error('Select an event first')
            prompt = eventKind === 'meter' ? `meter-value ${event.numerator} ${event.denominator} ${event.clocks} ${event.notated32nds}`
              : (eventKind === 'tempo' ? 'tempo-value ' : 'event-value ') + event.value
          } else editor = editorAction(editor, { kind: 'toggle-note' })
          break
        case 'x': editor = editorAction(editor, { kind: editor.eventView ? `${eventKind}-remove` : selectedNotes(editor).length ? 'remove' : 'toggle-note' }); break
        case 'delete': case 'backspace': editor = editorAction(editor, { kind: editor.eventView ? `${eventKind}-remove` : 'remove' }); break
        case 'u': editor = editorAction(editor, { kind: 'undo' }); break
        case 'y': editor = editorAction(editor, { kind: 'redo' }); break
        case 'm': editor = editorAction(editor, { kind: 'mute' }); break
        case 'o': editor = editorAction(editor, { kind: 'solo' }); break
        case 'g': editor = editorAction(editor, { kind: 'grid' }); break
        case 'left': case 'right': editor = editorAction(editor, { kind: key.shift ? editor.eventView ? `${eventKind}-move` : 'move-note' : 'move', ticks: editor.step * (key.name === 'left' ? -1 : 1) }); break
        case 'up': case 'down': editor = editorAction(editor, editor.eventView ? { kind: `${eventKind}-next`, direction: key.name === 'down' ? 1 : -1 }
          : { kind: key.shift ? 'move-note' : 'move', pitches: key.name === 'up' ? 1 : -1 }); break
        default:
          if (editor.eventView) {
            if (['+', '=', '-'].includes(text)) editor = editorAction(editor, { kind: `${eventKind}-value`, delta: text === '-' ? -1 : 1 })
          } else if (text === '{' || text === '}') editor = editorAction(editor, { kind: 'locator', side: text === '{' ? 'left' : 'right' })
          else if (text === '<' || text === '>') editor = editorAction(editor, { kind: 'bars', delta: text === '>' ? 1 : -1 })
          else if (text === '[' || text === ']') editor = editorAction(editor, { kind: 'duration', value: (selectedNote(editor)?.duration ?? editor.duration) * (text === '[' ? 0.5 : 2) })
          else if (['+', '=', '-'].includes(text)) editor = editorAction(editor, { kind: 'velocity', value: (selectedNote(editor)?.velocity ?? editor.velocity) + (text === '-' ? -1 : 1) })
      }
      if (original !== editor.project) { stopPlayback(); status = notice('Edited') }
      if (!editor.eventView && (text === '{' || text === '}')) {
        // An imported source keeps its loop in the editor, not the document.
        stopPlayback()
        status = notice(`Loop ${loopLabel(editorView(editor), editorAxis(editor), editorMeters(editor))}${loop ? '' : ' · l turns repetition on'}`)
      }
      changedContext(previous)
    }).catch(error => { status = failure(error.message) }).finally(draw)
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
    status = failure(error.message); draw()
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
  const timer = setInterval(() => {
    if (transport.kind === 'playing') {
      try { transport.handle.status() } catch (error) { status = failure(error.message) }
      draw()
    }
  }, 100)
  if (!embedded) process.stdout.write('\x1b[?1049h\x1b[?25l\x1b[2J')
  let recovery = null
  try { draw(); if (signal?.aborted) finish(); await done }
  finally {
    if (pendingDraw) clearImmediate(pendingDraw)
    closed = true; stop({ admittedControls: true }); picker.close(); sourcePicker.close(); clearInterval(timer); sessionAbort.abort()
    // Close native admission now, but retain already admitted editor decisions.
    // MIDI consumers use task, so join them outside that serialized queue.
    for (const owner of stepOwners) owner.stop({ admittedControls: true })
    process.stdin.off('keypress', keypress); process.stdin.off('end', onEnd)
    process.stdout.off('resize', onResize); signal?.removeEventListener('abort', onAbort)
    for (const name of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.off(name, onSignal)
    for (const handle of players.keys()) handle.terminate()
    for (const job of nativeRenders) job.cancel()
    for (const job of jobs.values()) { Atomics.store(job.cancel, 0, 1); job.reject(new Error('Sequencer closed')) }
    jobs.clear()
    try {
      await Promise.allSettled([task, childTask, picker.settled(), sourcePicker.settled(), worker.terminate(), ...players.values(), ...[...nativeRenders].map(job => job.promise), ...[...stepOwners].map(owner => owner.completion)])
      await Promise.allSettled([...observations, vstSession.close()])
      if (dirty()) {
        try { await save() }
        catch {
          const recoveryDirectory = await mkdtemp(join(tmpdir(), 'masc-phrase-recovery-'))
          recovery = join(recoveryDirectory, 'project.json')
          await saveProject(recovery, editor.project)
        }
      }
    } finally {
      clearHarmony()
      await rm(directory, { recursive: true, force: true })
      if (!embedded) {
        process.stdout.write('\x1b[?25h\x1b[?1049l')
        process.stdin.setRawMode(wasRaw ?? false); process.stdin.pause()
      }
      if (recovery) process.stderr.write(`Phrase edits retained at ${recovery}\n`)
    }
  }
  return { project: editor.project, pattern: editor.pattern, changed: editor.project !== initialSnapshot }
}
