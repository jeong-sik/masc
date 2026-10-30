import { emitKeypressEvents } from 'node:readline'
import { join } from 'node:path'
import { randomUUID } from 'node:crypto'
import { isDeepStrictEqual } from 'node:util'
import { midiClipEditor, midiClipRows, midiClipAction, midiClipCommand } from './midi-clip-editor.mjs'
import { saveProject } from './sequencer-files.mjs'
import { exportMidiClip } from './midi-clip-files.mjs'
import { clipTempo, clipMeter } from './midi-clip-source.mjs'
import { MidiClipPlayer, midiClipOutputs } from './midi-clip-player.mjs'
import { fitLine, bold, dim, cyan, magenta, green, blue, yellow, red, inverse } from './terminal-style.mjs'

const help = [
  ':notes / :expressions / :events changes view; :select BYTE_OFFSET chooses one original event.',
  ':pitch-absolute 60.5 sets Pitch7.9 (1/512 semitone); :velocity 0–65535; :reset-words restores source data.',
  ':value32 0–4294967295 edits a native per-note controller, pitch bend or poly pressure.',
  ':time TICKS sets a sequence event; :reset-time restores only its musical position.',
  ':select-events ID... explicitly groups attacks, releases and expression; :deselect-events clears it.',
  ':shift-events-ticks SIGNED_TICKS; :stretch-events RATIO [ANCHOR_TICKS]; :reset-event-times.',
  'Group edits are one Undo. Choose releases and expression explicitly; associations are not inferred.',
  ':revoice Cmaj7 drop2 [OCTAVE [INVERSION]] voices the exact onset in the selected group/channel.',
  ':harmony reports onset candidates; fractional and opaque pitches are identified separately.',
  ':tempo-value VALUE edits selected Set Tempo in 10ns/quarter (UInt32); :meter-value NUM_CODE DEN_POWER N32.',
  'Configuration delays and raw profile setup remain source data. Sequence edits retain original PPQ.',
  ':save-as NEW_JSON; :export NEW_MIDI2; :title NAME; :undo / :redo.',
  'o: choose a native MIDI2 output; Space: play/pause/resume; 0: restart full Clip; .: stop.',
  ':midi-output ID pins an output; :play / :pause / :resume / :stop; :seek-event [ID] seeks the admitted snapshot.',
  ':initial-tempo 50000000 explicitly supplies missing initial tempo (10ns/quarter); :initial-tempo clears it.',
  'MIDI1-only outputs and setup needing MIDI-CI negotiation are explicit playback refusals.',
]
const groupColors = [cyan, green, magenta, yellow, blue]

export async function viewMidiClip({ loaded, initialDocument, root, embedded = false, signal, midiOutput } = {}) {
  if (!process.stdin.isTTY || !process.stdout.isTTY) throw new Error('MIDI2 Clip editor requires a terminal')
  if (signal?.aborted) return
  let editor = midiClipEditor(initialDocument ?? loaded?.project), path = loaded?.path ?? join(root, `midi2-${randomUUID()}.json`)
  let saved = loaded?.project, revision = loaded?.revision ?? null, prompt = null, showHelp = false
  let status = 'Select an event; :help lists native editing commands', failed = false, accepting = true, tail = Promise.resolve()
  let outputs = null, outputCursor = 0, outputTask = null
  const player = new MidiClipPlayer({ destination: midiOutput, notify: state => {
    if (!accepting) return
    if (state.error) { status = state.error.message; failed = true }
    else if (state.event?.refusal) { status = state.event.refusal; failed = true }
    draw()
  } })
  let operation = new AbortController()
  const operationSignal = () => signal ? AbortSignal.any([signal, operation.signal]) : operation.signal
  let finish
  const done = new Promise(resolve => { finish = resolve })
  const dirty = () => !isDeepStrictEqual(editor.project, saved)
  async function save(target = path, expected = revision) {
    if (target === path && !dirty()) return
    const next = await saveProject(target, editor.project, expected)
    path = target; revision = next; saved = editor.project; status = `Saved ${path}`; failed = false
  }
  function draw() {
    if (!accepting) return
    const rows = midiClipRows(editor), selected = rows.findIndex(row => row.id === editor.selected)
    const height = Math.max(1, (process.stdout.rows || 24) - 7), first = Math.max(0, selected - Math.floor(height / 2))
    const lines = [
      [[`MIDI2 Clip · ${editor.project.name}${dirty() ? ' *' : ''}`, [bold, cyan]],
        [` · ${editor.performance.ppq} ticks/quarter · ${editor.performance.ticks} ticks`, [dim]]],
      [[`${editor.view} · ${rows.length} events · ${editor.selection.length} grouped · ${editor.project.changes.length} edited`, [magenta]]],
      [[`${player.state.kind} · MIDI2 output ${player.destination ?? 'choose with o'}${player.state.event ? ` · ${player.state.event.currentTime.toFixed(3)} / ${player.state.event.duration.toFixed(3)}s${BigInt(player.state.event.currentNanoseconds) < BigInt(player.state.event.setupNanoseconds) ? ' · setting up' : ''}` : ''}`,
        player.state.kind === 'playing' ? [bold, green] : [cyan]]],
      [[status, failed ? [bold, red] : [green]]],
      'Space: play/pause · 0: restart · .: stop · o: output · Up/Down: select · Tab: view · u/y: undo/redo · s: save · :command · q: return',
    ]
    if (outputs) {
      lines.push('Choose a native MIDI2 destination · Up/Down: select · Enter: use · Esc: close')
      const firstOutput = Math.max(0, outputCursor - Math.floor(height / 2))
      for (const [offset, output] of outputs.slice(firstOutput, firstOutput + Math.max(1, height - 1)).entries()) {
        const index = firstOutput + offset
        lines.push([[`${index === outputCursor ? '> ' : '  '}${output.name} · ${output.id}${output.nativeProtocol === 2 ? '' : ' · MIDI1 only'}`,
        index === outputCursor ? [bold, inverse] : output.nativeProtocol === 2 ? [green] : [dim]]])
      }
      if (!outputs.length) lines.push('No MIDI destinations reported')
    } else if (showHelp) lines.push(...help)
    else for (const row of rows.slice(first, first + height)) {
      const group = row.words[0] >>> 24 & 15, channel = row.words[0] >>> 16 & 15
      const tempo = clipTempo(row), meter = clipMeter(row)
      const detail = editor.view === 'notes' ? `index:${row.index} pitch:${row.pitch / 512} (${row.basis}) vel16:${row.velocity}`
        : tempo !== null ? `Set Tempo ${tempo} × 10ns/quarter`
          : meter !== null ? `Meter codes ${meter.numeratorCode}/${meter.denominatorPower} n32:${meter.notated32nds}`
            : row.words.map(word => word.toString(16).padStart(8, '0')).join(' ')
      lines.push([[`${row.id === editor.selected ? '>' : ' '}${editor.selection.includes(row.id) ? '+' : ' '} ${row.id} ${row.section} t:${row.tick ?? 'untimed'} `,
        row.id === editor.selected ? [bold, inverse] : [dim]],
      [`g${group + 1}/ch${channel + 1} ${detail}`, [groupColors[group % groupColors.length]]]])
    }
    lines.push([[path, [dim]]], prompt === null ? '' : `:${prompt}`)
    process.stdout.write('\x1b[H\x1b[2J' + lines.map(line => fitLine(line, process.stdout.columns || 80)).join('\n'))
  }
  function enqueue(action) {
    tail = tail.then(action).catch(error => { status = error.message; failed = true }).finally(draw)
  }
  async function command(line) {
    const result = midiClipCommand(editor, line)
    if (result.editor.project !== editor.project) player.stop()
    editor = result.editor
    status = result.harmony ? `${result.harmony.kind}: ${result.harmony.candidates.join(', ') || 'no 12-TET chord label'}` : 'Ready'
    failed = false
    switch (result.effect?.kind) {
      case 'help': showHelp = !showHelp; break
      case 'save': await save(); break
      case 'save-as': await save(result.effect.path, null); break
      case 'export': await exportMidiClip(result.effect.path, editor.project, { signal: operationSignal() }); status = `Exported ${result.effect.path}`; break
      case 'play': player.play(editor.project); break
      case 'pause': player.pause(); break
      case 'resume': player.resume(); break
      case 'stop': player.stop(); break
      case 'seek-event': player.seekEvent(result.effect.id); break
      case 'midi-output': player.setOutput(result.effect.path); break
      case 'initial-tempo': player.setInitialTempo(result.effect.value); status = result.effect.value === undefined
        ? 'Using declared source tempo only' : `Explicit initial tempo ${result.effect.value} × 10ns/quarter; session only`; break
    }
  }
  function close(discard = false) {
    if (!accepting) return
    accepting = false; operation.abort(); player.stop()
    tail = tail.then(async () => { await player.settle(); await outputTask; if (!discard) await save(); finish() }).catch(error => {
      status = error.message; failed = true
      if (signal?.aborted) { finish(error); return }
      operation = new AbortController(); accepting = true; draw()
    })
  }
  function keypress(text, key = {}) {
    if (!accepting) return
    if (key.ctrl && key.name === 'c') { close(true); return }
    if (outputs) {
      if (key.name === 'escape' || key.name === 'q') outputs = null
      else if (key.name === 'up' || key.name === 'down') outputCursor = Math.max(0, Math.min(outputs.length - 1, outputCursor + (key.name === 'up' ? -1 : 1)))
      else if (key.name === 'return' && outputs[outputCursor]) {
        const selected = outputs[outputCursor]
        if (selected.nativeProtocol !== 2) { status = 'Choose a native MIDI2 destination; this output is MIDI1 only'; failed = true }
        else { player.setOutput(selected.id); outputs = null; status = `Selected ${selected.name}`; failed = false }
      }
      draw(); return
    }
    if (prompt !== null) {
      if (key.name === 'escape') prompt = null
      else if (key.name === 'return') { const line = prompt; prompt = null; enqueue(() => command(line)) }
      else if (key.name === 'backspace') prompt = [...prompt].slice(0, -1).join('')
      else if (text && !key.ctrl && !key.meta) prompt += text
      draw(); return
    }
    if (key.name === 'q' || key.name === 'escape') { close(); return }
    if (text === ':') prompt = ''
    else if (key.name === 'space') enqueue(() => player.toggle(editor.project))
    else if (text === '0') enqueue(() => player.restart(editor.project))
    else if (text === '.') enqueue(() => player.stop())
    else if (text === 'o' && !outputTask) {
      outputTask = midiClipOutputs({ signal: operationSignal() }).then(found => { if (accepting) { outputs = found; outputCursor = 0 } })
        .catch(error => { if (accepting) { status = error.message; failed = true } }).finally(() => { outputTask = null; draw() })
    }
    else if (key.name === 'tab') enqueue(() => {
      const views = ['notes', 'expressions', 'events']; editor = midiClipAction(editor, { kind: 'view', view: views[(views.indexOf(editor.view) + 1) % views.length] })
    })
    else if (['up', 'down'].includes(key.name)) enqueue(() => { editor = midiClipAction(editor, { kind: 'move', direction: key.name === 'up' ? -1 : 1 }) })
    else if (['u', 'y', 's', '?'].includes(text)) enqueue(() => command({ u: 'undo', y: 'redo', s: 'save', '?': 'help' }[text]))
    draw()
  }
  const abort = () => close()
  const wasRaw = process.stdin.isRaw
  emitKeypressEvents(process.stdin); process.stdin.setRawMode(true); process.stdin.resume()
  process.stdin.on('keypress', keypress); process.stdout.on('resize', draw); signal?.addEventListener('abort', abort, { once: true })
  if (signal?.aborted) abort()
  const poll = setInterval(() => { try { player.status() } catch (error) { if (accepting) { status = error.message; failed = true; draw() } } }, 250)
  try { draw(); const error = await done; await tail; if (error) throw error }
  finally {
    signal?.removeEventListener('abort', abort); process.stdin.off('keypress', keypress); process.stdout.off('resize', draw)
    clearInterval(poll); operation.abort(); await player.close(); process.stdin.setRawMode(Boolean(wasRaw))
    if (!embedded) process.stdin.pause()
  }
  return { path, revision, project: editor.project }
}
