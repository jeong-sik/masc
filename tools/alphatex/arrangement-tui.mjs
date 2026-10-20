import { practiceEnabled } from './arrangement-practice.mjs'
import { viewSession } from './music-session.mjs'
import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises'
import { join, dirname, resolve } from 'node:path'
import { tmpdir } from 'node:os'
import { randomUUID } from 'node:crypto'
import { Worker } from 'node:worker_threads'
import { emitKeypressEvents } from 'node:readline'
import { arrangementRoute, selectArrangementRoute, arrangementPlaybackRequest } from './arrangement-playback.mjs'
import { startSoundArrangement } from './arrangement-sound.mjs'
import { arrangementEditor, arrangementAction, arrangementCommand, arrangementCommandAdmission, arrangementImported, arrangementUmpDraft, arrangementPracticePass, arrangementPracticeSound, arrangementCalibrated, arrangementRecordingCorrection, selectedRegion, arrangementTakes, arrangementTakeSelected, arrangementSound } from './arrangement-editor.mjs'
import { captureFluidSound } from './soundfont.mjs'
import { loadArrangement, verifyArrangementAssets, saveArrangement } from './arrangement-files.mjs'
import { saveProject } from './sequencer-files.mjs'
import { safeText } from './terminal.mjs'
import { StatusReader } from './status-reader.mjs'
import { openPlayback } from './playback.mjs'
import { devices, record, monitorInput } from './capture.mjs'
import { openLiveMidi, backingMidiClaims, liveMidiPlan } from './live-midi.mjs'
import { midiDestinations } from './playback.mjs'
import { recordingEpoch } from './arrangement-recording.mjs'
import { recordingCorrectionContext, recordingCorrectionCapture } from './recording-correction.mjs'
import { measureAudioCalibration } from './audio-calibration.mjs'
import { calibrationMilliseconds, calibrationResidual, validateCalibrationCapture } from './calibration-profile.mjs'
import { InstrumentPicker, pickerFooter, selectionLabel } from './instruments.mjs'
import { defaultStateDirectory } from './vst.mjs'
import { captureVstSound } from './project-sound-files.mjs'

const help = [
  ':edit-ump [ASSET] edits native MIDI2 absolute pitch/velocity and onset voicings; raw capture stays unchanged',
  'i chooses a VST/preset for the selected MIDI region or asset; Space plays it with WAV backing through the audio output',
  ':phrase opens a new phrase; :edit-midi [ASSET] [PATTERN] makes an editable variant; Enter places its new asset',
  ':practice BARS on|off   count-in bars and metronome; :record also starts stopped backing',
  ':record-calibration DIRECTORY   inspect next-take measurement; :record-correction pulse N | manual MS IN OUT | none',
  ':calibration-open DIRECTORY   inspect saved samples/clocks; :calibration-apply PULSE_NUMBER adopts one displayed residual',
  ':capture-channel IN_CH OUT_CH   route one captured audio channel; :capture-channel all restores every source channel',
  ':takes [ASSET] lists loop takes; :take N|next|previous [ASSET] selects paired audio/MIDI; Space auditions',
  ':split-take   separate selected captured audio/MIDI; :capture-offset MS (positive advances, negative delays)',
  ':calibrate OUTPUT_UID IN_CH OUT_CH MAX_LAG_MS  audio loopback candidates; Esc/q cancels and returns',
  ':import-wave /path/take.wav     :import-midi /path/song.mid',
  ':import-take /path/session      :open-take [ASSET] (WAV + raw UMP)',
  ':capture-midi [ASSET] derives the complete captured take as MIDI1 / 960 PPQ; :edit-midi edits it; raw WAV/UMP stays intact',
  ':capture-midi-region derives the selected original MIDI cut, restoring entry keys/pedals and releasing them at its end',
  ':import-practice /path/take     import original MIDI from a completed practice take',
  ':practice-soundfont ASSET [SF2_PATH] binds a SoundFont for that raw take; :practice-sound-original ASSET restores its recorded sound',
  ':practice-backing [ASSET] restores its editable phrase backing; Enter places it, :edit-midi edits it',
  ':practice-midi [ASSET] derives the whole performance as MIDI1 / 960 PPQ; :edit-midi edits the variant',
  ':practice-midi-region derives only the selected original practice region, restoring entry notes and pedals',
  ':practice-passes [ASSET] lists original passes; :practice-pass NUMBER [ASSET] places or replaces the selected source region',
  ':practice-region ASSET BEAT OFFSET EXTENT DIVISOR [REPEAT] places an exact fractional host cut',
  ':trim-fraction OFFSET EXTENT DIVISOR edits a practice cut; :trim returns to whole host ticks',
  ':place asset-1 0               full source at quarter-note beat 0',
  ':place asset-2 4 2             MIDI format-2 pattern 2 at beat 4',
  ':region asset-1 0 1200 4800 2   asset, beat, native offset/extent, repeats',
  ':region asset-2 4 0 2002 1 2    optional final pattern starts at 1',
  ':capture-region asset-3 4 0.5 2 3  beat, source start/duration seconds, repeats',
  ':trim-time 0.5 2              captured region source start/duration seconds',
  ':trim 2400 4800                WAV frames, MIDI ticks or captured host ticks',
  ':move 8    :repeat 4    :duplicate 16    :remove',
  ':loop START END continuously repeats a WAV/SMF range, including mixed backing; :loop off restores one-shot playback',
  ':lane-add wave Bass    :lane-add midi Keys    :lane 2',
  ':region-lane 2    :lane-name Bass    :region-name Verse    :lane-remove',
  ':asset asset-1    :select region-1    :cursor 4    :grid 0.25',
  ':tempo 120    :meter 3 4    :title Experiment    :mute    :solo',
  ':save    :save-as /path/song.json    :undo    :redo',
  ':wave /path/song.wav exports the complete arrangement once, without practice clicks or playback looping; :stop cancels',
  ':export /path/song.mid exports MIDI tracks, expression and independent ports; audio requires :wave',
  'Arrows: cursor/regions; Shift+Left/Right: move region; Tab: lane; a: asset',
  'Enter: place selected asset; d: duplicate at cursor; x/Delete: remove',
  'Captured asset: Enter opens source; :place adds its region.',
  'u/y: undo/redo; m/o: mute/solo; s: save; q/Esc: save and return',
  'Regions run at original speed. Project tempo moves positions without warping.',
  'Space: play/pause/resume; :stop; :seek BEAT; :output AUDIO_UID',
  ':midi-output MIDI_UID    :midi-port asset-1 PORT MIDI_UID',
  ':midi-source asset-2 SOURCE_ID MIDI_UID overrides one captured input.',
  ':mixed-output AUDIO_UID enables audio plus the selected MIDI routes.',
  'Stored instruments play through the audio output; explicit MIDI routes send those sources externally.',
  ':play-audio explicitly auditions WAV, including captured regions, silent gaps and saved loops.',
  ':inputs lists audio/MIDI inputs; :input AUDIO_UID; :midi-input all|none|UID',
  ':record starts simultaneous WAV + raw MIDI against playing backing; :record-stop',
  ':monitor AUDIO_OUTPUT_UID enables input monitoring; :monitor off disables it.',
  ':midi-monitor SOURCE_UID DEST_UID [GROUP CHANNEL ...] (1–16); omit pairs for all messages.',
  'Repeat for more routes; :midi-monitor remove SOURCE_UID DEST_UID; :midi-monitor off.',
  'Channel scopes filter system/SysEx. Transport/edits finalize recording; loop passes become separate take lanes, with the last take selected.',
]

export async function viewArrangement({ path, loaded, initialDocument, root = resolve('music-projects'), embedded = false, signal, output, midiOutput, initialRoute, stateDirectory = defaultStateDirectory() } = {}) {
  if (!process.stdin.isTTY || !process.stdout.isTTY) throw new Error('Arrangement editor requires a terminal')
  if ((path || loaded) && initialDocument) throw new Error('Open a saved arrangement or a new one, one at a time')
  if (signal?.aborted) return
  if (loaded) await verifyArrangementAssets(loaded.project, dirname(loaded.path), { signal })
  else loaded = path ? await loadArrangement(path, { signal }) : null
  if (signal?.aborted) return
  if (initialRoute && (output !== undefined || midiOutput !== undefined)) throw new Error('Choose a handoff route or output selections')
  let editor = arrangementEditor(initialDocument ?? loaded?.project), saved = loaded?.project
  path = loaded?.path ?? join(root, `arrangement-${randomUUID()}.json`)
  path = resolve(path)
  if (!loaded) await verifyArrangementAssets(editor.project, dirname(path), { signal })
  if (signal?.aborted) return
  let sourceRoot = dirname(path), revision = loaded?.revision ?? null
  let accepting = true, closed = false, suspended = false, takeAbort = null, takeTask = null, phrasePreparation = null, task = Promise.resolve(), prompt = null, status = 'Import a WAV or MIDI source with :help', showHelp = false
  const statusReader = new StatusReader()
  let pendingDraw = null, sequence = 0, workerFailure = null, recovery = null, terminatingWorker = false
  const failedSavePaths = new Set()
  const directory = await mkdtemp(join(tmpdir(), 'masc-arrangement-play-'))
  let worker
  try { worker = new Worker(new URL('./arrangement-worker.mjs', import.meta.url)) }
  catch (error) { await rm(directory, { recursive: true, force: true }); throw error }
  const jobs = new Map(), players = new Map(), preparations = new Set(), wasRaw = process.stdin.isRaw
  let transport = { kind: 'stopped' }, generation = 0, preparing = null, route = initialRoute ? structuredClone(initialRoute) : arrangementRoute({ output, midiOutput })
  let monitoring = null, monitorOutput = null
  let liveMidi = null, liveRoutes = [], liveTransitions = Promise.resolve()
  const playerPlans = new Map(), planInspections = new Map()
  let recordStart = null, recording = null, input = null, midiInput = 'all', transportPending = false, inputDevices = null, discoveryTicket = 0
  let showTakes = null
  let derivationAdmission = 0
  let calibration = null
  let calibrationInspection = null, recordingInspection = null
  const discovery = new AbortController()
  let pickerAsset = null, pendingSound = null, exporting = null
  const soundJobs = new Set()
  function cancelSound() { pendingSound?.capture.cancel(); pendingSound = null }
  const picker = new InstrumentPicker({ directory: stateDirectory, notify: draw,
    active: () => editor.project.assets.find(asset => asset.id === pickerAsset)?.source?.sound?.selection,
    selected(selection) {
      enqueue(async () => {
        if (!accepting || closed || suspended) return
        await settleRecording(); stop(); cancelSound()
        const project = editor.project, asset = pickerAsset, capture = captureVstSound(selection)
        const owned = { capture }; pendingSound = owned; status = 'Capturing selected VST sound…'
        const completion = capture.promise.then(sound => {
          return enqueue(() => {
            if (!accepting || closed || suspended || pendingSound !== owned || editor.project !== project) return
            pendingSound = null
            adopt(arrangementSound(editor, asset, sound))
            route = { kind: 'audio', output: route.output }
            status = `Selected ${selectionLabel(sound.selection)}`
            play()
          })
        }).catch(error => { if (pendingSound === owned && accepting && !closed) status = error.message })
          .finally(() => { if (pendingSound === owned) pendingSound = null; soundJobs.delete(completion); draw() })
        soundJobs.add(completion)
      })
    }, failed: error => { status = error.message; draw() } })
  async function chooseInstrument() {
    await settleRecording(); stop(); cancelSound()
    const id = selectedRegion(editor)?.asset ?? editor.asset
    if (editor.project.assets.find(asset => asset.id === id)?.kind !== 'midi') throw new Error('Select a MIDI region or asset, then press i to choose its instrument')
    pickerAsset = id
    await picker.open()
  }
  let complete
  const done = new Promise(resolve => { complete = resolve })
  function finish() {
    if (!accepting) return
    accepting = false
    picker.close(); cancelSound()
    calibration?.abort()
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
    if (recording || monitoring || liveMidi) Promise.allSettled([settleRecording(), settleMonitoring(), settleLiveMidi()]).finally(release)
    else release()
  }
  async function settleMonitoring() {
    const owned = monitoring
    if (!owned) return
    owned.handle.stop()
    await owned.completion
    if (owned.failure) throw owned.failure
  }
  function startMonitoring() {
    if (!accepting || suspended || recording || monitoring || !monitorOutput || !input) return
    const owned = { handle: null, phase: 'opening', info: null, completion: null, failure: null }
    monitoring = owned
    try {
      owned.handle = monitorInput({ input, monitorOutput, onEvent(event) {
        if (monitoring !== owned) return
        if (event.kind === 'monitoring') { owned.phase = 'active'; owned.info = event.monitoring }
        draw()
      } })
      owned.completion = owned.handle.completion.catch(error => {
        owned.failure = error
        if (monitoring === owned) { status = error.message; monitorOutput = null }
      }).finally(() => { if (monitoring === owned) monitoring = null; draw() })
    } catch (error) { monitoring = null; monitorOutput = null; status = error.message; draw() }
    draw()
  }
  function transitionLiveMidi(action) {
    const pending = liveTransitions.then(action)
    liveTransitions = pending.catch(() => {})
    return pending
  }
  async function settleLiveMidi() {
    const owned = liveMidi
    if (!owned) return
    owned.controller.abort(); owned.handle?.stop()
    await owned.completion
  }
  function inspectMidiPlan(plan, signal) {
    const pending = backingMidiClaims({ path: plan.path, format: plan.format, signal })
    const readers = planInspections.get(plan) ?? new Set()
    planInspections.set(plan, readers); readers.add(pending)
    return pending.finally(() => { readers.delete(pending); if (!readers.size) planInspections.delete(plan) })
  }
  function startLiveMidi(extraPlan) {
    if (!accepting || suspended || liveMidi || !liveRoutes.length) return null
    const routes = liveRoutes, owned = { controller: new AbortController(), handle: null, info: null, phase: 'opening', completion: null, ready: null }
    liveMidi = owned
    let admit, refuse
    owned.ready = new Promise((resolve, reject) => { admit = resolve; refuse = reject }); owned.ready.catch(() => {})
    owned.completion = (async () => {
      try {
        const signal = owned.controller.signal, plans = [...playerPlans.values(), ...(extraPlan ? [extraPlan] : [])]
        const reserved = (await Promise.all(plans.map(plan => inspectMidiPlan(plan, signal)))).flat()
        signal.throwIfAborted()
        owned.handle = await openLiveMidi({ routes, reserved, signal, directory, onEvent(event) {
          if (liveMidi !== owned || signal.aborted) return
          if (event.kind === 'monitoring') { owned.info = event; owned.phase = 'active' }
          if (event.kind === 'error') { owned.failure = new Error(event.message); owned.phase = 'failed'; owned.info = null }
          draw()
        } })
        const active = await owned.handle.ready
        signal.throwIfAborted(); if (owned.failure) throw owned.failure
        admit(active)
        await owned.handle.completion
      } catch (error) {
        refuse(error)
        if (!owned.controller.signal.aborted && liveMidi === owned) { status = error.message; liveRoutes = [] }
      } finally {
        owned.handle?.stop()
        if (owned.handle) await owned.handle.completion.catch(() => {})
        if (liveMidi === owned) liveMidi = null
        draw()
      }
    })()
    return owned
  }
  async function settleRecording() {
    if (recordStart) { stop(); return }
    const owned = recording
    if (!owned) return
    owned.phase = 'finalizing'; owned.controller.abort(); owned.handle?.stop(); draw()
    await owned.completion
  }
  function startRecording() {
    if (recording) throw new Error('A recording is already opening or finalizing')
    if (!input) throw new Error('Select :input AUDIO_UID first; :inputs lists devices')
    if (transport.kind !== 'playing' || transportPending) throw new Error('Start arrangement playback before recording')
    const project = editor.project, projectPath = path, selectedInput = input, selectedMidi = midiInput, selectedMonitor = monitorOutput, backing = transport.handle
    const correction = structuredClone(project.recordingCorrection ?? { kind: 'none' })
    recordingCorrectionContext(correction, { input: selectedInput, output: route.output, monitorOutput: selectedMonitor })
    const selectedOutput = route.output
    const owned = { controller: new AbortController(), phase: 'opening', directory: join(dirname(path), 'recordings', randomUUID()), handle: null, epoch: null, failure: null, generation }
    recording = owned
    const expected = generation
    owned.completion = (async () => {
      try {
        // Input ownership transfers only after the monitoring child has closed.
        await settleMonitoring()
        await mkdir(dirname(owned.directory), { recursive: true, mode: 0o700 })
        if (owned.controller.signal.aborted || !accepting || generation !== expected) return
        // This correlated barrier follows earlier native pause/seek commands.
        // An old unsolicited status cannot supply the admission epoch.
        const playback = await backing.recordingEpoch({ signal: owned.controller.signal })
        recordingCorrectionContext(correction, { input: selectedInput, output: selectedOutput, monitorOutput: selectedMonitor, playback })
        const epoch = recordingEpoch(playback)
        if (owned.controller.signal.aborted || !accepting || generation !== expected || transport.handle !== backing || editor.project !== project || path !== projectPath) return
        owned.epoch = epoch
        // The native recorder creates a fresh take directory itself. Retain the
        // chosen policy beside it before opening inputs, including failed takes.
        await writeFile(owned.directory + '.request.json', JSON.stringify({ projectPath, epoch, correction }, null, 2), { flag: 'wx', mode: 0o600 })
        if (owned.controller.signal.aborted || !accepting || generation !== expected || transport.handle !== backing || editor.project !== project || path !== projectPath) return
        owned.handle = record({ input: selectedInput, midi: selectedMidi, directory: owned.directory, monitorOutput: selectedMonitor, onEvent(event) {
          if (event.kind === 'recording') {
            if (correction.kind === 'audio' && (event.input?.id !== correction.input || correction.audioChannel.input > event.channels
                || correction.placement.kind === 'calibrated' && event.sampleRate !== correction.placement.profile.input.sampleRate)) throw new Error('Capture opened with a different correction input/channel/rate')
            owned.phase = owned.controller.signal.aborted ? 'finalizing' : 'recording'
          }
          if (event.kind === 'monitoring') owned.monitoring = event.monitoring
          if (event.kind === 'error') status = event.message
          draw()
        } })
        const captured = await owned.handle.completion
        owned.phase = 'attaching'; draw()
        // Import is separate from recording success. A failed/late import must
        // preserve the complete finalized source and its recovery coordinates.
        await writeFile(join(owned.directory, 'arrangement-recording.json'), JSON.stringify({ projectPath, epoch, correction }, null, 2), { flag: 'wx', mode: 0o600 })
        recordingCorrectionCapture(correction, captured.manifest)
        if (owned.failure) throw owned.failure
        if (editor.project !== project || path !== projectPath) throw new Error('Project changed before recording attachment')
        const result = await request({ kind: 'attach-recording', project, projectPath, path: owned.directory, epoch, correction })
        if (owned.failure) throw owned.failure
        if (editor.project !== project || path !== projectPath) throw new Error('Project changed during recording attachment')
        await writeFile(join(owned.directory, 'alignment.json'), JSON.stringify(result.alignment, null, 2), { flag: 'wx', mode: 0o600 })
        if (owned.failure) throw owned.failure
        if (recording !== owned || editor.project !== project || path !== projectPath) throw new Error('Recording attachment authority changed')
        recording = null
        editor = arrangementImported(editor, result)
        showTakes = null
        status = 'Recorded WAV and raw MIDI attached; original take retained'
      } catch (error) {
        if (!owned.handle && owned.controller.signal.aborted && !owned.failure) status = 'Recording cancelled before opening inputs'
        else {
          status = `${error.message}; take retained at ${owned.directory}`
          process.stderr.write(`Recording recovery: ${owned.directory} (${error.message})\n`)
        }
      } finally { if (recording === owned) recording = null; startMonitoring(); draw() }
    })()
    draw()
  }
  function request(value, issued, onProgress) {
    if (workerFailure) return Promise.reject(workerFailure)
    const id = ++sequence
    return new Promise((resolve, reject) => {
      jobs.set(id, { resolve, reject, onProgress })
      issued?.(id)
      try { worker.postMessage({ ...value, id }) }
      catch (error) { jobs.delete(id); reject(error) }
    })
  }
  function fail(error) {
    calibration?.abort()
    if (recording) recording.failure = error
    stop()
    workerFailure = error
    for (const job of jobs.values()) job.reject(error)
    jobs.clear(); status = error.message; draw()
  }
  worker.on('message', message => {
    const job = jobs.get(message.id)
    if (!job) return
    if (message.kind === 'progress') { job.onProgress?.(message.progress, message.id); return }
    jobs.delete(message.id)
    if (message.ok) job.resolve(message.result)
    else { const error = new Error(message.error); error.name = message.cancelled ? 'AbortError' : 'Error'; job.reject(error) }
  })
  worker.on('error', fail)
  worker.on('exit', code => { if (!terminatingWorker) fail(new Error(`Arrangement worker exited ${code}`)) })
  function stop() {
    recording?.controller.abort(); recording?.handle?.stop()
    recordStart = null
    generation++; transportPending = false
    if (preparing?.kind === 'sound' || preparing?.kind === 'sound-selection') preparing.handle.cancel()
    else if (preparing?.kind === 'worker' && !workerFailure) worker.postMessage({ kind: 'cancel', request: preparing.id })
    preparing = null
    if (exporting !== null && !workerFailure) worker.postMessage({ kind: 'cancel', request: exporting.id })
    exporting = null
    transport.handle?.stop()
    transport = { kind: 'stopped' }
    status = 'Playback stopped'
    draw()
  }
  function adopt(next) {
    if (next.project !== editor.project || next.region !== editor.region) calibrationInspection = recordingInspection = null
    if (next.project !== editor.project) { cancelSound(); stop() }
    editor = next
    if (showTakes !== null && (editor.asset !== showTakes || !editor.project.assets.some(asset => asset.id === showTakes && asset.selectedTake !== undefined))) showTakes = null
  }
  function choosePracticeSoundfont(value) {
    if (!accepting || suspended) return
    stop()
    const expected = generation, project = editor.project, selection = captureFluidSound(value.path)
    preparing = { kind: 'sound-selection', handle: selection }
    transport = { kind: 'preparing' }; status = 'Capturing practice SoundFont'
    const pending = (async () => {
      try {
        const sound = await selection.promise
        if (!accepting || generation !== expected || editor.project !== project) return
        preparing = null; transport = { kind: 'stopped' }
        adopt(arrangementPracticeSound(editor, value.asset, sound))
        status = 'Practice SoundFont selected; original take and recorded sound retained'
      } finally {
        if (generation === expected && preparing?.handle === selection) {
          preparing = null; transport = { kind: 'stopped' }
        }
      }
    })()
    preparations.add(pending)
    pending.catch(error => { if (accepting && generation === expected) { status = error.message; draw() } })
      .finally(() => { preparations.delete(pending); draw() })
    draw()
  }
  function play(audioOnly = false) {
    if (!accepting) return
    if (exporting !== null) stop()
    if (transport.kind === 'playing') { transportPending = true; transport.handle.pause(); return }
    if (transport.kind === 'paused') { transportPending = true; transport.handle.resume(); return }
    if (transport.kind === 'preparing' || transport.kind === 'starting') { stop(); return }
    const selection = audioOnly ? { kind: 'prepare-audio', output: route.output } : arrangementPlaybackRequest(editor.project, route)
    let resolveStart, rejectStart
    const started = new Promise((yes, no) => { resolveStart = yes; rejectStart = no })
    started.catch(() => {})
    const expected = ++generation, project = editor.project, projectPath = path, output = selection.output
    transport = { kind: 'preparing' }; status = 'Preparing arrangement sources…'
    const sound = selection.kind === 'prepare-sound' ? startSoundArrangement({ project, route, sourceRoot, directory, request,
      cancelRequest: id => { if (!workerFailure) worker.postMessage({ kind: 'cancel', request: id }) } }) : null
    if (sound) preparing = { kind: 'sound', handle: sound }
    const prepared = sound ? sound.promise : request({ ...selection, project, sourceRoot, directory }, id => { preparing = { kind: 'worker', id } }, (progress, id) => {
      if (!accepting || closed || suspended || generation !== expected || preparing?.kind !== 'worker' || preparing.id !== id
          || editor.project !== project || path !== projectPath || transport.kind !== 'preparing' || selection.kind !== 'prepare-vst') return
      switch (progress.kind) {
        case 'vst-projection': status = 'Projecting VST MIDI sources…'; break
        case 'vst-render': status = `Rendering VST instances ${progress.completed}/${progress.total} complete`; break
        case 'vst-mix': status = `Mixing ${progress.total} VST instances…`; break
        default: return
      }
      transport = { ...transport, progress }
      draw()
    })
    const preparation = (async () => {
      let result, playbackCompletion, playbackHandle, startedPlaying = false
      try {
        result = await prepared
        if (generation === expected) {
          preparing = null
          if (transport.progress) {
            transport = { kind: 'preparing' }
            status = 'VST backing prepared; waiting for playback ownership…'
            draw()
          }
        }
        await Promise.allSettled([...players.values()])
        if (!accepting || generation !== expected) return
        const admitted = await transitionLiveMidi(async () => {
          await settleLiveMidi()
          if (!accepting || generation !== expected) return
          const live = startLiveMidi(result)
          if (live) await live.ready
          if (!accepting || generation !== expected || live && liveMidi !== live) return
          transport = { kind: 'starting' }
          const handle = openPlayback({ path: result.path, format: result.format, output, midiOutput: result.midiOutput, midiBindings: result.bindings, loop: result.loop ?? false,
            onEvent(event) {
              if (generation !== expected) return
              const captured = recording?.generation === expected ? recording : null
              if (event.kind === 'error') {
                if (captured) captured.failure = new Error(event.message)
                captured?.controller.abort(); captured?.handle?.stop(); status = event.message; return
              }
              if (event.kind === 'stopped' && captured) {
                if (captured.epoch?.loop) {
                  if (typeof event.clock?.end === 'string') captured.epoch.end = event.clock.end
                  else captured.failure = new Error('Loop backing stopped without its recording end clock')
                } else if (captured.epoch) captured.epoch.duration = Math.min(captured.epoch.duration, event.currentTime)
                captured.controller.abort(); captured.handle?.stop()
              }
              if (!accepting) return
              if (!startedPlaying && event.kind === 'playing') {
                startedPlaying = true
                status = 'Playback started'
              }
              transportPending = false
              transport = { ...transport, kind: event.kind, event: { ...event,
                currentTime: event.currentTime + (result.originSeconds ?? 0), duration: event.duration + (result.originSeconds ?? 0) } }
              draw()
            } })
          playbackHandle = handle
          transport = { ...transport, handle, originSeconds: result.originSeconds ?? 0 }
          playerPlans.set(handle, result)
          const completion = handle.completion.then(event => {
            if (recording?.generation === expected) { recording.controller.abort(); recording.handle?.stop() }
            if (generation === expected) { transport = { kind: 'stopped', event }; status = 'Playback stopped'; draw() }
          }, error => {
            if (recording?.generation === expected) { recording.failure = error; recording.controller.abort(); recording.handle?.stop() }
            if (generation === expected) { transport = { kind: 'stopped' }; status = error.message; draw() }
          }).finally(() => { players.delete(handle); playerPlans.delete(handle) })
          players.set(handle, completion)
          return { handle, completion }
        })
        if (admitted) {
          playbackCompletion = admitted.completion
          await admitted.handle.ready
          if (!accepting || generation !== expected || transport.handle !== admitted.handle || transport.kind !== 'playing') throw new Error('Playback start was cancelled')
          resolveStart()
          await admitted.completion
        }
      } catch (error) {
        rejectStart(error)
        playbackHandle?.stop()
        if (generation === expected) { preparing = null; transport = { kind: 'stopped' }; status = error.message; draw() }
      } finally {
        rejectStart(new Error('Playback start was cancelled'))
        if (playbackCompletion) await playbackCompletion
        if (result) {
          await Promise.allSettled([...(planInspections.get(result) ?? [])])
          if (!sound) await rm(dirname(result.path), { recursive: true, force: true })
        }
        if (sound) await sound.dispose()
      }
    })()
    preparations.add(preparation)
    preparation.catch(error => { if (accepting) { status = error.message; draw() } }).finally(() => preparations.delete(preparation))
    draw()
    return started
  }
  function openTake(asset) {
    if (!accepting || takeTask || phrasePreparation) return
    stop()
    const expected = ++generation
    transport = { kind: 'preparing' }; status = 'Preparing captured source…'
    const prepared = request({ kind: 'prepare-take', project: editor.project, asset, sourceRoot, directory }, id => { preparing = { kind: 'worker', id } })
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
        await Promise.all([settleMonitoring(), settleLiveMidi()])
        if (!accepting || controller.signal.aborted) return
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
          startMonitoring()
          transitionLiveMidi(async () => { await settleLiveMidi(); const live = startLiveMidi(); if (live) await live.ready }).catch(() => {})
          draw()
        }
      }
    })()
    preparations.add(preparation)
    preparation.catch(error => { if (accepting) { status = error.message; draw() } }).finally(() => preparations.delete(preparation))
    draw()
  }
  function openPhrase(asset, pattern) {
    if (!accepting || takeTask || phrasePreparation) return
    stop()
    const expected = generation, project = editor.project, clip = selectedRegion(editor)
    const prepared = request({ kind: 'prepare-phrase', project, asset }, id => { preparing = { kind: 'worker', id } })
    transport = { kind: 'preparing' }; status = 'Opening MIDI experiment'
    const preparation = (async () => {
      let controller
      try {
        const document = await prepared
        if (generation === expected) preparing = null
        await Promise.allSettled([...players.values()])
        if (!accepting || generation !== expected) return
        const { viewSequencer } = await import('./sequencer-tui.mjs')
        if (!accepting || generation !== expected) return
        controller = new AbortController(); takeAbort = controller; takeTask = preparation
        suspended = true; transport = { kind: 'stopped' }; process.stdin.off('keypress', keypress)
        await Promise.all([settleMonitoring(), settleLiveMidi()])
        if (!accepting || controller.signal.aborted) return
        const bindings = (route.portBindings ?? []).filter(binding => binding.asset === asset).map(({ port, destination }) => ({ port, destination }))
        const midiOutput = document.kind === 'midi-source' ? route.midiOutput : bindings.find(binding => binding.port === 0)?.destination ?? route.midiOutput
        const edited = await viewSequencer({ initialDocument: document, root: join(sourceRoot, 'phrases'),
          embedded: true, signal: controller.signal, pattern: pattern ?? (clip?.asset === asset ? clip.pattern : undefined),
          output: midiOutput === undefined && !bindings.length ? route.output : undefined, midiOutput,
          initialPortBindings: document.kind === 'midi-source' ? bindings : [], stateDirectory })
        if (!accepting || controller.signal.aborted || generation !== expected || editor.project !== project || !edited?.changed) return
        const imported = await request({ kind: 'import-phrase', project, document: edited.project })
        if (!accepting || controller.signal.aborted || generation !== expected || editor.project !== project) return
        adopt(arrangementImported(editor, { ...imported, pattern: edited.pattern })); status = 'MIDI variant imported; Enter places the new asset'
      } catch (error) { if (generation === expected) { preparing = null; transport = { kind: 'stopped' }; status = error.message } }
      finally {
        if (controller && takeAbort === controller) {
          takeAbort = null; suspended = false
          if (accepting && !closed) process.stdin.on('keypress', keypress)
        }
        if (takeTask === preparation) takeTask = null
        if (phrasePreparation === preparation) phrasePreparation = null
        startMonitoring()
        transitionLiveMidi(async () => { await settleLiveMidi(); const live = startLiveMidi(); if (live) await live.ready }).catch(() => {})
        draw()
      }
    })()
    phrasePreparation = preparation; preparations.add(preparation)
    preparation.catch(error => { if (accepting) { status = error.message; draw() } }).finally(() => preparations.delete(preparation))
    draw()
  }
  function openUmp(asset) {
    if (!accepting || takeTask || phrasePreparation) return
    stop()
    const expected = generation, project = editor.project
    const prepared = request({ kind: 'prepare-ump', project, asset, sourceRoot, directory }, id => { preparing = { kind: 'worker', id } })
    transport = { kind: 'preparing' }; status = 'Opening native UMP experiment'
    const preparation = (async () => {
      let controller, terminalBorrowed = false
      try {
        const source = await prepared
        if (generation === expected) preparing = null
        await Promise.allSettled([...players.values()])
        if (!accepting || generation !== expected) return
        const { viewUmpEditor } = await import('./ump-tui.mjs')
        if (!accepting || generation !== expected) return
        controller = new AbortController(); takeAbort = controller; takeTask = preparation
        transport = { kind: 'stopped' }
        await Promise.all([settleMonitoring(), settleLiveMidi()])
        if (!accepting || controller.signal.aborted || generation !== expected || editor.project !== project) return
        suspended = true; process.stdin.off('keypress', keypress); terminalBorrowed = true
        async function io(kind, edited, signal, path) {
          signal.throwIfAborted()
          const candidate = { ...project, assets: project.assets.map(item => item.id === asset ? edited : item) }
          let id
          const cancel = () => { if (id !== undefined) worker.postMessage({ kind: 'cancel', request: id }) }
          signal.addEventListener('abort', cancel, { once: true })
          try {
            return await request({ kind, project: candidate, asset, sourceRoot, directory, ...(path ? { path: resolve(path) } : {}) }, issued => {
              id = issued; if (signal.aborted) cancel()
            })
          } finally { signal.removeEventListener('abort', cancel) }
        }
        const edited = await viewUmpEditor({ ...source, signal: controller.signal,
          onPreview: async (candidate, signal, borrowTerminal) => {
            let snapshot
            try {
              snapshot = await io('prepare-take', candidate, signal)
              signal.throwIfAborted()
              await borrowTerminal(() => viewSession({ directory: snapshot.directory, embedded: true, signal, output: route.output, midiOutput: route.midiOutput,
                sourceBindings: (route.sourceBindings ?? []).filter(binding => binding.asset === asset).map(({ source, destination }) => ({ source, destination })) }))
            } finally { if (snapshot) await rm(snapshot.directory, { recursive: true, force: true }) }
          },
          onExport: (candidate, target, signal) => io('export-ump', candidate, signal, target) })
        if (!accepting || controller.signal.aborted || editor.project !== project || !edited?.changed) return
        if (generation !== expected && !workerFailure) return
        const draft = arrangementUmpDraft(editor, source, edited.asset.ump)
        let imported, failure
        try {
          imported = await request({ kind: 'import-ump', project, asset, ump: edited.asset.ump, sourceRoot, directory })
        } catch (error) { failure = error }
        if (!accepting || controller.signal.aborted || editor.project !== project || generation !== expected && !workerFailure) return
        if (failure || workerFailure) {
          adopt(draft); status = `Native UMP draft retained; source verification failed: ${(failure ?? workerFailure).message}`
        } else {
          adopt(arrangementImported(editor, imported)); status = 'Native UMP variant imported; :place adds its region, :open-take auditions'
        }
      } catch (error) { if (generation === expected) { preparing = null; transport = { kind: 'stopped' }; status = error.message } }
      finally {
        if (controller && takeAbort === controller) {
          takeAbort = null; suspended = false
          if (terminalBorrowed && accepting && !closed) process.stdin.on('keypress', keypress)
        }
        if (takeTask === preparation) takeTask = null
        if (phrasePreparation === preparation) phrasePreparation = null
        startMonitoring()
        transitionLiveMidi(async () => { await settleLiveMidi(); const live = startLiveMidi(); if (live) await live.ready }).catch(() => {})
        draw()
      }
    })()
    phrasePreparation = preparation; preparations.add(preparation)
    preparation.catch(error => { if (accepting) { status = error.message; draw() } }).finally(() => preparations.delete(preparation))
    draw()
  }
  async function save(target = path) {
    target = resolve(target)
    if (target !== path && exporting !== null) stop()
    const project = editor.project, nextRoot = dirname(target)
    const retained = new Map()
    if (nextRoot !== sourceRoot) for (const document of [project, ...editor.undo, ...editor.redo]) {
      for (const asset of document.assets) if (['wave', 'capture', 'practice'].includes(asset.kind)) retained.set(asset.file ?? JSON.stringify(asset.parts), asset)
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
      case 'practice-soundfont': choosePracticeSoundfont(value); break
      case 'phrase': openPhrase(); break
      case 'edit-midi': openPhrase(value.asset, value.pattern); break
      case 'edit-ump': openUmp(value.asset); break
      case 'record-calibration': {
        recordingInspection = null
        if (!input || !route.output) throw new Error('Select :input and :mixed-output before inspecting a recording calibration')
        const project = editor.project, selectedInput = input, selectedOutput = route.output, selectedMonitor = monitorOutput
        status = 'Verifying next-take calibration samples and clocks'; draw()
        const profile = await request({ kind: 'inspect-calibration', path: value.path })
        if (!accepting || editor.project !== project || input !== selectedInput || route.output !== selectedOutput || monitorOutput !== selectedMonitor) return
        const correction = { kind: 'audio', input, output: route.output,
          audioChannel: { input: profile.input.channel, output: profile.output.channel },
          placement: { kind: 'calibrated', profile, match: 0, advanceNanoseconds: calibrationResidual(profile, profile.pulses[0]) } }
        recordingCorrectionContext(correction, { input, output: route.output, monitorOutput })
        recordingInspection = { profile, project, input, output: route.output, monitorOutput }
        status = 'Inspect both pulses; :record-correction pulse N selects one for future takes'
        break
      }
      case 'record-correction': {
        let correction
        switch (value.action) {
          case 'clear': correction = { kind: 'none' }; break
          case 'manual': correction = { kind: 'audio', input, output: route.output, audioChannel: value.audioChannel, placement: value.placement }; break
          case 'measured': {
            const owned = recordingInspection
            if (!owned || owned.project !== editor.project || owned.input !== input || owned.output !== route.output || owned.monitorOutput !== monitorOutput) throw new Error('Inspect calibration for the current recording input/output before selecting a pulse')
            const profile = owned.profile, pulse = profile.pulses[value.match]
            if (!pulse) throw new Error('Choose one inspected calibration pulse')
            correction = { kind: 'audio', input, output: route.output, audioChannel: { input: profile.input.channel, output: profile.output.channel },
              placement: { kind: 'calibrated', profile, match: value.match, advanceNanoseconds: calibrationResidual(profile, pulse) } }
            break
          }
          default: throw new Error('Unknown recording correction action')
        }
        recordingCorrectionContext(correction, { input, output: route.output, monitorOutput })
        adopt(arrangementRecordingCorrection(editor, correction))
        status = 'Recording correction selected; original take files and MIDI remain unchanged'
        break
      }
      case 'calibration-open': {
        calibrationInspection = null
        const project = editor.project, region = editor.region, output = route.output
        const clip = selectedRegion(editor)
        if (clip?.component !== 'audio' || !clip.audioChannel) throw new Error('Choose a separated audio component and :capture-channel first')
        status = 'Verifying retained calibration samples and clocks'; draw()
        const profile = await request({ kind: 'inspect-calibration', path: value.path })
        if (!accepting || editor.project !== project || editor.region !== region || route.output !== output) return
        validateCalibrationCapture(profile, project.assets.find(asset => asset.id === clip.asset), clip, output ?? null)
        calibrationInspection = { profile, project, region, output }
        status = 'Inspect both pulses; :calibration-apply 1 or 2 explicitly adopts one residual'
        break
      }
      case 'calibration-apply': {
        const owned = calibrationInspection
        if (!owned || owned.project !== editor.project || owned.region !== editor.region || owned.output !== route.output) throw new Error('Open calibration for the current component and output before applying it')
        adopt(arrangementCalibrated(editor, { profile: owned.profile, match: value.match, output: route.output }))
        status = 'Selected measured audio advance applied; original MIDI and source retained'
        break
      }
      case 'calibrate': {
        if (workerFailure) throw workerFailure
        if (!input) throw new Error('Select :input AUDIO_UID before calibration')
        if (recording || transport.kind !== 'stopped' || players.size || preparations.size) throw new Error('Stop and drain arrangement playback before calibration')
        const selectedInput = input, target = join(dirname(path), 'calibrations', randomUUID())
        const owned = new AbortController(); calibration = owned
        try {
          await mkdir(dirname(target), { recursive: true, mode: 0o700 })
          await settleMonitoring()
          await transitionLiveMidi(() => settleLiveMidi())
          owned.signal.throwIfAborted()
          if (!accepting) return
          if (workerFailure) throw workerFailure
          status = 'Measuring selected audio loopback; Esc/q cancels and returns'; draw()
          const result = await measureAudioCalibration({ ...value, input: selectedInput, directory: target, signal: owned.signal,
            analyze: async ({ signal, ...job }) => {
              signal.throwIfAborted()
              let cancel
              try {
                return await request({ kind: 'analyze-calibration', ...job }, id => {
                  cancel = () => { if (!workerFailure) worker.postMessage({ kind: 'cancel', request: id }) }
                  signal.addEventListener('abort', cancel, { once: true })
                })
              } finally { signal.removeEventListener('abort', cancel) }
            } })
          owned.signal.throwIfAborted()
          if (accepting) status = `Unapplied calibration: ${result.matches.map(m => `${m.residualMs.toFixed(3)} ms (correlation ${m.correlation.toFixed(3)})`).join(', ')}; saved ${result.directory}`
        } finally {
          // Keep ownership through cleanup and route restoration. Repeated
          // cancel keys must not turn a draining measurement into a view exit.
          try {
            startMonitoring()
            await transitionLiveMidi(async () => { const live = startLiveMidi(); if (live) await live.ready })
          } finally { if (calibration === owned) calibration = null }
        }
        break
      }
      case 'inputs': {
        const ticket = ++discoveryTicket
        if (inputDevices !== null) { inputDevices = null; break }
        inputDevices = []; status = 'Discovering input devices; :inputs returns to arrangement'
        const pending = Promise.all([devices({ signal: discovery.signal }), midiDestinations({ signal: discovery.signal })]).then(([found, destinations]) => {
          if (!accepting || discovery.signal.aborted || ticket !== discoveryTicket) return
          inputDevices = [...found.audio.filter(device => device.inputs > 0).map(device => `Audio ${device.id}: ${device.name}`),
            ...found.midi.map(device => `MIDI input ${device.id}: ${device.name}`),
            ...destinations.map(device => `MIDI output ${device.id}: ${device.name}`),
            ...found.audio.filter(device => device.outputs > 0).map(device => `Monitor output ${device.id}: ${device.name}`)]
          status = 'Select :input AUDIO_UID and :midi-input all|none|MIDI_UID; :inputs returns'
          draw()
        }, error => { if (!discovery.signal.aborted) { status = error.message; draw() } })
        preparations.add(pending); pending.finally(() => preparations.delete(pending)); break
      }
      case 'input': await settleMonitoring(); input = value.input; startMonitoring(); status = 'Audio input selected'; break
      case 'monitor':
        if (value.output && !input) throw new Error('Select :input AUDIO_UID before monitoring')
        await settleMonitoring(); monitorOutput = value.output; startMonitoring(); break
      case 'midi-monitor': {
        await transitionLiveMidi(async () => {
          let next
          switch (value.action) {
            case 'clear': next = []; break
            case 'remove': next = liveRoutes.filter(route => route.source !== value.source || route.destination !== value.destination); break
            case 'set': next = [...liveRoutes.filter(route => route.source !== value.route.source || route.destination !== value.route.destination), value.route]; break
            default: throw new Error('Unknown live MIDI route change')
          }
          if (next.length) next = liveMidiPlan(next, []).routes
          if (!liveMidi || !next.length) {
            await settleLiveMidi(); liveRoutes = next
            const live = startLiveMidi(); if (live) await live.ready
            return
          }
          // The owner is running: reconfigure it in place. Routes that stay
          // active keep their CoreMIDI connections, only added routes open and
          // only removed routes close, so a failure never blinks the rest.
          const owner = liveMidi, signal = owner.controller.signal
          const reserved = (await Promise.all([...playerPlans.values()].map(plan => inspectMidiPlan(plan, signal)))).flat()
          signal.throwIfAborted()
          const ack = await owner.handle.set(next, next.map(route => route.key), reserved)
          if (ack.error) throw new Error(`Live MIDI rejected the route set: ${ack.error}`)
          liveRoutes = next.filter(route => ack.admitted.includes(route.key))
          if (ack.rejected.length) {
            // A route that could not open leaves the target; re-queue the
            // remainder so the monitor converges without a restart.
            await owner.handle.set(next, liveRoutes.map(route => route.key), reserved)
          }
        })
        break
      }
      case 'midi-input': midiInput = value.input; status = 'MIDI input selected'; break
      case 'record': {
        if (recordStart) throw new Error('Recording backing is already opening')
        if (transport.kind === 'stopped' && practiceEnabled(editor.project)) {
          if (!input) throw new Error('Select :input AUDIO_UID first; :inputs lists devices')
          const started = play(), owned = { generation }
          recordStart = owned
          started.then(() => {
            if (recordStart !== owned || !accepting || generation !== owned.generation) return
            recordStart = null; startRecording()
          }).catch(error => { if (accepting && generation === owned.generation) { status = error.message; draw() } })
            .finally(() => { if (recordStart === owned) recordStart = null })
        } else startRecording()
        break
      }
      case 'record-stop': await settleRecording(); break
      case 'takes': inputDevices = null; showHelp = false; showTakes = showTakes === value.asset ? null : value.asset; break
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
        // The native horizon can round outward from the nominal beat span.
        // The user's exact range end still means the next cycle's phase zero.
        transport.handle.seek(value.tick === editor.project.playbackLoop?.end ? 0
          : value.tick / editor.project.ppq * 60 / editor.project.tempo - (transport.originSeconds ?? 0))
        break
      }
      case 'midi-output': case 'midi-port': case 'midi-source': case 'output': case 'mixed-output':
        stop(); route = selectArrangementRoute(route, value); status = 'Playback outputs selected'; break
      case 'save': await save(); break
      case 'save-as': if (accepting) await save(value.path); break
      case 'export-midi': case 'export-wave': {
        if (!accepting) return
        stop()
        const owned = { id: null, project: editor.project, projectPath: path }
        exporting = owned
        status = value.kind === 'export-midi' ? 'Exporting complete arrangement as MIDI…' : 'Exporting complete arrangement as float WAV…'
        const active = () => accepting && exporting === owned && editor.project === owned.project && path === owned.projectPath
        const pending = request({ ...value, project: owned.project, sourceRoot, directory }, id => { owned.id = id }, progress => {
          if (!active()) return
          switch (progress.kind) {
            case 'midi-projection': status = 'Reconstructing MIDI region expression…'; break
            case 'midi-encode': status = 'Writing MIDI tracks and source provenance…'; break
            case 'wave-snapshot': status = 'Snapshotting WAV export sources…'; break
            case 'vst-projection': status = 'Projecting WAV export instruments…'; break
            case 'vst-render': status = `Exporting VST instances ${progress.completed}/${progress.total} complete`; break
            case 'vst-mix': status = 'Mixing VST export sources…'; break
            case 'wave-mix': status = 'Mixing complete arrangement for export…'; break
            default: return
          }
          draw()
        }).then(result => {
          if (!active()) return
          status = result.kind === 'midi-export'
            ? `Exported ${result.path} · ${result.tracks} MIDI tracks · timing error ≤${(result.maxTimingErrorNanoseconds / 1000).toFixed(3)} µs · ${result.excludedAudioRegions.length} audio regions excluded; choose instruments in your sequencer`
            : `Exported ${result.path} · ${result.frames} frames / ${result.sampleRate} Hz / ${result.channels} channels${result.peak > 1 ? ' · peak above 0 dBFS; float samples retained' : ''}`
        }, error => { if (active()) status = error.message }).finally(() => {
          if (exporting === owned) exporting = null
          preparations.delete(pending); draw()
        })
        preparations.add(pending); draw(); break
      }
      case 'import-wave': case 'import-midi': case 'import-take': case 'import-practice': {
        if (!accepting) return
        status = 'Importing source…'; draw()
        const result = await request({ ...value, project: editor.project, projectPath: path })
        if (accepting) { adopt(arrangementImported(editor, result)); status = value.kind === 'import-take' ? `Imported ${result.asset}; Enter opens WAV and MIDI` : `Imported ${result.asset}; Enter places it at the cursor` }
        break
      }
      case 'capture-midi': case 'capture-midi-region': case 'practice-midi-region': case 'practice-midi': case 'practice-backing': {
        if (!accepting) return
        stop()
        const project = editor.project, expected = generation
        let owned
        status = value.kind === 'practice-backing' ? 'Restoring captured phrase backing…' : 'Deriving performance as MIDI1 / 960 PPQ…'; draw()
        transport = { kind: 'preparing' }
        try {
          const result = await request({ ...value, project, sourceRoot }, id => { owned = preparing = { kind: 'worker', operation: 'derivation', id } })
          if (accepting && generation === expected && editor.project === project) {
            preparing = null
            const region = ['practice-midi-region', 'capture-midi-region'].includes(value.kind)
            adopt({ ...arrangementImported(editor, result), ...(region ? { tick: value.tick } : {}) })
            status = `${value.kind === 'practice-backing' ? 'Restored backing' : region ? 'Derived selected region MIDI1 / 960 PPQ' : 'Derived whole performance MIDI1 / 960 PPQ'} ${result.asset}; Enter places it, :edit-midi edits it`
          }
        } finally {
          if (generation === expected) {
            if (preparing === owned) preparing = null
            transport = { kind: 'stopped' }
          }
        }
        break
      }
      case 'practice-passes': case 'practice-pass': {
        if (!accepting) return
        status = 'Reading original practice passes…'; draw()
        const result = await request({ ...value, project: editor.project, sourceRoot, directory })
        if (accepting) {
          if (value.kind === 'practice-pass') adopt(arrangementPracticePass(editor, value, result))
          else adopt({ ...editor, asset: value.asset, pattern: undefined })
          status = value.kind === 'practice-pass' ? `Practice pass ${result.pass}${result.full ? '' : ' (partial)'} selected; Space auditions`
            : `${result.asset}: ${result.count} passes (${result.firstPass ?? 'none'}–${result.lastPass ?? 'none'}) · ${result.tempo} BPM · :practice-pass NUMBER`
        }
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
    return task
  }
  function keypress(text, key = {}) {
    if (!accepting || closed || suspended) return
    if (key.ctrl && key.name === 'c') { finish(); return }
    if (statusReader.keypress(text, key, process.stdout)) { draw(); return }
    if (key.ctrl && key.name === 'l' || prompt === null && !picker.view && text === '!') {
      statusReader.open('Arrangement status at open', statusBody())
      draw(); return
    }
    if (picker.view) {
      if (key.name === 's' && !picker.view.searching && ['plugins', 'presets'].includes(picker.view.kind)) stop()
      picker.keypress(text, key).catch(error => { status = error.message }).finally(draw)
      return
    }
    if (pendingSound && key.name === 'escape') { cancelSound(); status = 'Instrument selection cancelled'; draw(); return }
    if (prompt !== null) {
      if (key.name === 'escape') prompt = null
      else if (key.name === 'backspace') prompt = [...prompt].slice(0, -1).join('')
      else if (key.name === 'return') {
        const line = prompt; prompt = null
        // Reading a status must never finalize an active recording.
        if (statusReader.command(line, 'Arrangement status at open', statusBody())) { draw(); return }
        if (arrangementCommandAdmission(line).kind === 'stop') {
          derivationAdmission++
          // Also invalidate derivations admitted in this same input batch,
          // whose serialized command has not issued its worker request yet.
          if (preparing?.operation === 'derivation') { stop(); status = 'Cancelling MIDI derivation'; draw(); return }
        }
        const admission = derivationAdmission
        enqueue(async () => {
          let result = arrangementCommand(editor, line)
          const derivation = ['capture-midi', 'capture-midi-region', 'practice-midi-region', 'practice-midi', 'practice-backing'].includes(result.effect?.kind)
          if (derivation && admission !== derivationAdmission) return
          if (result.editor.project !== editor.project || result.effect && !['record', 'record-stop', 'inputs', 'input', 'midi-input', 'midi-monitor', 'help', 'takes'].includes(result.effect.kind)) {
            await settleRecording()
            if (derivation && admission !== derivationAdmission) return
            // Finalization may select a newly imported asset. Retain the source
            // the user chose before waiting; never reinterpret it on that asset.
            result = result.selection?.kind === 'take-selection'
              ? { editor: arrangementTakeSelected(editor, result.selection) }
              : ['edit-ump', 'capture-midi', 'capture-midi-region', 'practice-midi-region', 'practice-midi', 'practice-backing', 'practice-pass', 'practice-passes'].includes(result.effect?.kind) ? { editor, effect: result.effect } : arrangementCommand(editor, line)
          }
          adopt(result.editor); if (result.effect) await effect(result.effect); else status = 'Edited'
        })
      } else if (text && !key.ctrl && !key.meta) prompt += safeText(text)
      draw(); return
    }
    if (calibration && ['escape', 'q'].includes(key.name)) { calibration.abort(); return }
    if (['escape', 'q'].includes(key.name)) { finish(); return }
    if (text === ':') { prompt = ''; draw(); return }
    if (text === '?') { showHelp = !showHelp; draw(); return }
    enqueue(async () => {
      let action
      switch (key.name) {
        case 'i': await chooseInstrument(); return
        case 's': await settleRecording(); await save(); return
        case 'a': action = { kind: 'asset' }; break
        case 'tab': action = { kind: 'lane' }; break
        case 'return':
          if (editor.project.assets.find(asset => asset.id === editor.asset)?.kind === 'capture') { await settleRecording(); openTake(editor.asset); return }
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
  function playbackSummary() {
    return `Playback ${transport.kind}${transport.event?.practice?.phase === 'count-in' ? ' · count-in ' + transport.event.practice.remainingSeconds.toFixed(2) + ' s' : ''} · ${(transport.event?.currentTime ?? 0).toFixed(2)} s · ${transport.event?.device.name ?? route.output ?? route.midiOutput ?? 'default output'}`
  }
  function statusBody() {
    return [status, '', playbackSummary(),
      `Recording ${recording?.phase ?? 'idle'} · input ${input ?? 'not selected'} · MIDI ${midiInput}`,
      `Project: ${path}`].join('\n')
  }
  function draw() {
    if (!closed && !suspended && !pendingDraw) pendingDraw = setImmediate(() => { pendingDraw = null; drawNow() })
  }
  function drawNow() {
    if (closed || suspended) return
    const reading = statusReader.render(process.stdout)
    if (reading !== null) { process.stdout.write(reading); return }
    const project = editor.project, clip = selectedRegion(editor), asset = project.assets.find(asset => asset.id === editor.asset)
    const monitorInfo = recording?.monitoring ?? monitoring?.info
    const reportedLatency = monitorInfo ? ` · ${((monitorInfo.latency.inputSeconds + monitorInfo.latency.outputSeconds) * 1000).toFixed(2)} ms reported I/O` : ''
    const rows = process.stdout.rows || 24, width = Math.max(1, (process.stdout.columns || 80) - 24)
    if (picker.view) {
      const items = picker.items(), capacity = Math.max(1, rows - 4)
      const start = Math.max(0, (picker.view.cursor ?? 0) - capacity + 1)
      const lines = [picker.view.title, `${pickerAsset} · ${status}`,
        ...(picker.view.query === undefined ? [] : [`${picker.view.searching ? 'Search' : 'Filter'}: ${picker.view.query}`]),
        ...items.slice(start, start + capacity).map((item, index) => `${start + index === picker.view.cursor ? '›' : ' '} ${picker.isActive(item) ? '●' : ' '} ${item.name}`)]
      let output = '\x1b[H'
      for (let row = 1; row <= rows; row++) output += `\x1b[${row};1H\x1b[2K`
      lines.slice(0, rows - 1).forEach((line, index) => { output += `\x1b[${index + 1};1H${fit(line)}` })
      process.stdout.write(output + `\x1b[${rows};1H${fit(pickerFooter(picker.view))}`)
      return
    }
    const policy = project.recordingCorrection ?? { kind: 'none' }
    const profile = recordingInspection?.profile ?? calibrationInspection?.profile ?? clip?.placement?.profile
    const residuals = profile?.pulses.map(pulse => calibrationMilliseconds(profile, pulse))
    const lines = [`Arrangement · ${project.title}${project !== saved ? ' *' : ''} · ${project.tempo} BPM · ${project.meter.join('/')}${project.playbackLoop ? ` · LOOP ${project.playbackLoop.start / project.ppq}–${project.playbackLoop.end / project.ppq}` : ''}`,
      `Cursor ${editor.tick / project.ppq} beats · grid ${editor.step / project.ppq} · ${status}`,
      playbackSummary(),
      `Practice ${project.practice?.countInBars ?? 0} count-in bars · metronome ${project.practice?.metronome ? 'on' : 'off'}`,
      `Recording ${recording?.phase ?? 'idle'} · input ${input ?? 'choose :input'} · MIDI ${midiInput} · correction ${policy.kind === 'none' ? 'none' : policy.placement.kind + ' ' + Number(policy.placement.advanceNanoseconds.numerator) / Number(policy.placement.advanceNanoseconds.denominator) / 1e6 + ' ms'}`,
      `Monitor ${recording?.monitoring ? 'active to ' + recording.monitoring.output.id : monitoring ? monitoring.phase + ' to ' + monitorOutput : 'off'}${reportedLatency}`,
      `MIDI monitor ${liveMidi?.phase ?? 'off'}${liveMidi?.info ? ' · ' + liveMidi.info.bindings.map(binding => binding.device.name + ' ← ' + binding.source).join(', ') : ''}`]
    if (profile) lines.push(`Calibration ${profile.input.id}:${profile.input.channel} → ${profile.output.id}:${profile.output.channel} · ${profile.input.sampleRate}/${profile.output.sampleRate} Hz`,
      ...profile.pulses.map((pulse, index) => `Pulse ${index + 1}: ${residuals[index].toFixed(3)} ms · correlation ${pulse.correlation.toFixed(6)}`),
      `Spread ${(Math.max(...residuals) - Math.min(...residuals)).toFixed(3)} ms · sample resolution ${(1000 / profile.input.sampleRate).toFixed(6)} ms`)
    if (inputDevices !== null) lines.push(...inputDevices)
    else if (showHelp) lines.push(...help)
    else if (showTakes !== null) {
      const group = arrangementTakes(project, showTakes), source = project.assets.find(asset => asset.id === group.asset)
      const selected = group.takes.findIndex(take => take.cycle === group.selectedCycle), capacity = Math.max(1, rows - lines.length - 5)
      const start = Math.max(0, selected - capacity + 1)
      lines.push(`${source.id} · ${source.name} · selected take ${BigInt(group.selectedCycle) + 1n}`,
        ':take NUMBER|next|previous selects audio and MIDI together; Space plays; :takes returns')
      for (const take of group.takes.slice(start, start + capacity)) {
        const audible = take.clips.filter(clip => !project.lanes.find(lane => lane.id === clip.lane).muted)
        lines.push(`${take.cycle === group.selectedCycle ? '>' : ' '} Take ${BigInt(take.cycle) + 1n} · ${take.clips.map(clip => clip.component ?? 'audio+MIDI').join(', ')} · ${audible.length}/${take.clips.length} regions unmuted`)
      }
      if (!group.takes.length || selected < 0) lines.push('Selected take has no remaining regions; choose another take.')
      lines.push('Lane mute and solo still apply. Take selection stops backing; Space starts the selected performance.')
    }
    else {
      const left = Math.floor(editor.tick / editor.step / width) * width * editor.step
      const selected = project.lanes.findIndex(lane => lane.id === editor.lane), capacity = Math.max(1, rows - 10 - (profile ? 4 : 0))
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
      lines.push(clip ? `${clip.id} · ${clip.name}${clip.audioChannel ? ` [input ${clip.audioChannel.input} → output ${clip.audioChannel.output}]` : ''}${clip.component ? ` (${clip.component}${clip.placement ? `, ${clip.placement.kind === 'calibrated' ? 'measured' : 'manual'} advance ${Number(clip.placement.advanceNanoseconds.numerator) / Number(clip.placement.advanceNanoseconds.denominator) / 1e6} ms` : ''})` : ''} · beat ${clip.position / project.ppq} · source ${clip.offset}+${clip.extent} ${['capture', 'practice'].includes(project.assets.find(asset => asset.id === clip.asset).kind) ? `host ticks${clip.sourceDivisor === undefined ? '' : ' / ' + clip.sourceDivisor}` : ''} · repeat ${clip.repeat}${clip.pattern === undefined ? '' : ` · pattern ${clip.pattern + 1}`}` : 'Up/Down selects a region on the current lane.')
      lines.push(asset ? `${asset.id} · ${asset.name}${asset.selectedTake === undefined ? '' : ` · take ${BigInt(asset.selectedTake) + 1n} (:takes)`} · ${asset.kind === 'wave' ? `${asset.metadata.frames} frames / ${asset.metadata.sampleRate} Hz / ${asset.metadata.channels} channels` : asset.kind === 'capture' ? `${asset.manifest.audioFrames} frames + ${asset.manifest.midiPacketCount} UMP packets; Enter opens the take` : asset.kind === 'practice' ? `${asset.metadata.packets} original UMP packets; Enter places a host-clock region` : 'original MIDI ticks; format-2 patterns require explicit selection'}` : 'No imported asset. :import-wave FILE or :import-midi FILE')
      const sounding = project.assets.find(asset => asset.id === (clip?.asset ?? editor.asset))
      if (sounding?.kind === 'midi') lines.push(`Instrument ${sounding.source.sound?.kind === 'vst' ? selectionLabel(sounding.source.sound.selection) : 'choose with i'} · ${sounding.id}`)
      lines.push(`Library ${project.assets.length} sources · ${project.clips.length} regions · a cycles sources · i instrument · ? help`, path)
    }
    let output = '\x1b[H'
    for (let row = 1; row <= rows; row++) output += `\x1b[${row};1H\x1b[2K`
    lines.slice(0, Math.max(0, rows - 2)).forEach((line, index) => { output += `\x1b[${index + 1};1H${fit(line)}` })
    output += `\x1b[${Math.max(1, rows - 1)};1H${fit(prompt === null ? `arrows:cursor/regions  Shift+←→:move  Tab:lane  a:asset  Enter:${asset?.kind === 'capture' ? 'open source' : 'place'}  u/y:undo/redo` : `:${prompt}`)}`
    output += `\x1b[${rows};1H${fit('Ctrl-L:status  s:save  d:duplicate  x:remove  m/o:mute/solo  :commands  ?:help  q:save/back')}`
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
    picker.close(); cancelSound()
    clearInterval(ticker)
    stop()
    if (pendingDraw) clearImmediate(pendingDraw)
    process.stdin.off('keypress', keypress); process.stdin.off('end', onEnd)
    process.stdout.off('resize', onResize); signal?.removeEventListener('abort', onAbort)
    for (const name of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.off(name, onSignal)
    try {
      await task
      await Promise.allSettled([picker.settled(), ...soundJobs])
      await Promise.allSettled([settleMonitoring(), settleLiveMidi()])
      await liveTransitions
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
