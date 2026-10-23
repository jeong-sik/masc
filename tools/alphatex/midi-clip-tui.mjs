import { emitKeypressEvents } from 'node:readline'
import { join } from 'node:path'
import { randomUUID } from 'node:crypto'
import { isDeepStrictEqual } from 'node:util'
import { midiClipEditor, midiClipRows, midiClipAction, midiClipCommand } from './midi-clip-editor.mjs'
import { saveProject } from './sequencer-files.mjs'
import { exportMidiClip } from './midi-clip-files.mjs'
import { clipTempo, clipMeter } from './midi-clip-source.mjs'
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
  'Native playback of imported Clip files is not connected yet; export retains MIDI2 resolution.',
]
const groupColors = [cyan, green, magenta, yellow, blue]

export async function viewMidiClip({ loaded, initialDocument, root, embedded = false, signal } = {}) {
  if (!process.stdin.isTTY || !process.stdout.isTTY) throw new Error('MIDI2 Clip editor requires a terminal')
  if (signal?.aborted) return
  let editor = midiClipEditor(initialDocument ?? loaded?.project), path = loaded?.path ?? join(root, `midi2-${randomUUID()}.json`)
  let saved = loaded?.project, revision = loaded?.revision ?? null, prompt = null, showHelp = false
  let status = 'Select an event; :help lists native editing commands', failed = false, accepting = true, tail = Promise.resolve()
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
      [[status, failed ? [bold, red] : [green]]],
      'Up/Down: select · Tab: view · u/y: undo/redo · s: save · :command · q/Esc: save and return · Ctrl+C: discard draft',
    ]
    if (showHelp) lines.push(...help)
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
    const result = midiClipCommand(editor, line); editor = result.editor
    status = result.harmony ? `${result.harmony.kind}: ${result.harmony.candidates.join(', ') || 'no 12-TET chord label'}` : 'Ready'
    failed = false
    switch (result.effect?.kind) {
      case 'help': showHelp = !showHelp; break
      case 'save': await save(); break
      case 'save-as': await save(result.effect.path, null); break
      case 'export': await exportMidiClip(result.effect.path, editor.project, { signal: operationSignal() }); status = `Exported ${result.effect.path}`; break
    }
  }
  function close(discard = false) {
    if (!accepting) return
    accepting = false; operation.abort()
    tail = tail.then(async () => { if (!discard) await save(); finish() }).catch(error => {
      status = error.message; failed = true
      if (signal?.aborted) { finish(error); return }
      operation = new AbortController(); accepting = true; draw()
    })
  }
  function keypress(text, key = {}) {
    if (!accepting) return
    if (key.ctrl && key.name === 'c') { close(true); return }
    if (prompt !== null) {
      if (key.name === 'escape') prompt = null
      else if (key.name === 'return') { const line = prompt; prompt = null; enqueue(() => command(line)) }
      else if (key.name === 'backspace') prompt = [...prompt].slice(0, -1).join('')
      else if (text && !key.ctrl && !key.meta) prompt += text
      draw(); return
    }
    if (key.name === 'q' || key.name === 'escape') { close(); return }
    if (text === ':') prompt = ''
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
  try { draw(); const error = await done; await tail; if (error) throw error }
  finally {
    signal?.removeEventListener('abort', abort); process.stdin.off('keypress', keypress); process.stdout.off('resize', draw)
    operation.abort(); process.stdin.setRawMode(Boolean(wasRaw))
    if (!embedded) process.stdin.pause()
  }
  return { path, revision, project: editor.project }
}
