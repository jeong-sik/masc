import { emitKeypressEvents } from 'node:readline'
import { isDeepStrictEqual } from 'node:util'
import { newUmpEditor, umpEditorRows, umpEditorAction, umpEditorCommand } from './ump-editor.mjs'
import { captureSecondsAtHost } from './capture-time.mjs'
import { safeText } from './terminal.mjs'

// The arrangement lends its terminal. All file/device effects remain owned by
// callbacks which settle before this child returns or the parent adopts edits.
export async function viewUmpEditor({ asset, packets, tempo, signal, onPreview, onExport }) {
  if (!process.stdin.isTTY || !process.stdout.isTTY) throw new Error('UMP editor requires a terminal')
  if (signal?.aborted) return { changed: false, asset }
  let editor = newUmpEditor(asset, packets, { tempo }), prompt = null, status = 'Select a MIDI2 event; :help lists commands'
  let accepting = true, suspended = false, showHelp = false, tail = Promise.resolve(), commit = true
  const close = new AbortController(), operationSignal = signal ? AbortSignal.any([signal, close.signal]) : close.signal
  let finish
  const done = new Promise(resolve => { finish = () => { accepting = false; close.abort(); resolve() } })
  function draw() {
    if (!accepting || suspended) return
    const noteView = editor.selection.kind === 'note', eventView = editor.selection.kind === 'event', rows = umpEditorRows(editor)
    const selected = rows.findIndex(row => row.id === editor.selection.id), height = Math.max(1, (process.stdout.rows || 24) - 6)
    const first = Math.max(0, selected - Math.floor(height / 2))
    const lines = [`Native UMP · ${asset.name} · ${editor.eventSelection.length} grouped events${tempo === undefined ? '' : ` · ${tempo} BPM`} · ${status}`,
      noteView ? 'Pitch edits explicitly override this attack with Pitch7.9; note indices and per-note addresses stay fixed.'
        : eventView ? 'Original packet:word IDs survive authored time/order changes; raw words stay native UMP.'
          : 'Expression values retain note addresses; authored time edits are stored separately from recorded timestamps.',
      'Up/Down: select · Tab: notes/expressions · :events: all messages · u/y: undo/redo · Space: audition · :command · q: return · Ctrl+C: discard']
    if (showHelp) lines.push(...[
      ':scope SOURCE GROUP CHANNEL (1–16) selects its first event in the current view; :select PACKET:WORD selects an exact attack',
      ':pitch-absolute 60.5 sets exact MIDI-note units (1/512); :velocity 0–65535; :reset-note restores original fields',
      ':expressions / :notes switches views; :select-expression PACKET:WORD selects a recorded per-note message',
      ':value32 0–4294967295 edits its raw data word; :reset-expression restores its original value',
      ':events shows all original messages; :select-event PACKET:WORD; :time HOST_TICKS edits the selected event',
      ':select-events ID... replaces an explicit event group; + marks its messages in every view; :deselect-events clears it',
      ':shift-events-ticks N / :shift-events-seconds S / :shift-events-beats B moves the whole group in one Undo',
      ':stretch-events RATIO [ANCHOR_BEATS] scales exact tick distances about the earliest selected event or explicit beat',
      'Stretch requires whole native ticks; choose attacks, releases and expression explicitly; no association is guessed.',
      ':reset-event-times restores only grouped timestamps; other timing/value edits and original WAV remain intact',
      ':note-time OFF_ID START_HOST END_HOST edits an explicitly chosen attack/release; no pairing is inferred',
      ':shift-time SIGNED_TICKS moves the selected event; :duration-ticks OFF_ID TICKS sets the explicit release',
      ':at-seconds S / :shift-seconds S edit decimal seconds; :note-seconds OFF_ID START_S END_S edits a pair',
      ':duration-seconds OFF_ID S sets length; seconds round to nearest native tick, half ties away from zero',
      'Seconds use this asset’s fixed original source zero; * marks authored time; :clock shows exact ticks',
      ':at-beats B / :shift-beats B / :note-beats OFF_ID START END / :duration-beats OFF_ID B',
      'Beat inputs accept decimals or fractions (1/3); quarter notes at the opening arrangement tempo, same source zero.',
      'Beat edits round once to native ticks; later project tempo changes do not retime this captured variant or WAV.',
      ':reset-time restores selected original time; ticks are exact UInt64; controls and WAV do not follow notes',
      'Sources containing JR/delta-clock utility messages need an embedded-clock editor before time changes.',
      'Per-note registered/assignable controllers, pitch bend and poly pressure keep their original note addresses.',
      ':revoice Cmaj7 drop2 [OCTAVE [INVERSION]] changes the exact-onset group in this source/group/channel',
      ':harmony shows onset candidates; key indices do not resolve MTS/per-note tuning; fractional pitches stay fractional',
      ':play opens native audition; original WAV is unchanged; choose explicit MIDI outputs in the session viewer',
      ':export NEW_DIRECTORY writes edited/original UMP, original audio/clock and provenance; no PPQ conversion',
      'Manufacturer/Profile attributes cannot be overwritten by absolute pitch; velocity edits retain their bytes',
    ])
    else for (const row of rows.slice(first, first + height)) lines.push(
      `${row.id === editor.selection.id ? '>' : ' '}${editor.eventSelection.includes(row.id) ? '+' : ' '} ${row.id} ${row.source} g${row.group + 1}/ch${row.channel + 1} t:${captureSecondsAtHost(editor.asset, row.hostTime).toFixed(6)}s${row.hostTime === row.originalHostTime ? '' : '*'} `
      + (noteView ? `index:${row.index} pitch:${row.pitch / 512} (${row.basis}) vel16:${row.velocity}` : eventView
        ? row.words.map(word => word.toString(16).padStart(8, '0')).join(' ')
        : `index:${row.index} ${row.kind}${row.controller === undefined ? '' : ` #${row.controller}`} value32:${row.value}`))
    lines.push(prompt === null ? '' : `:${prompt}`)
    process.stdout.write('\x1b[H\x1b[2J' + lines.map(line => safeText(line).slice(0, Math.max(1, (process.stdout.columns || 80) - 1))).join('\n'))
  }
  function enqueue(action) {
    tail = tail.then(action).catch(error => { if (accepting) status = error.message }).finally(draw)
  }
  async function command(line) {
    const result = umpEditorCommand(editor, line); editor = result.editor
    if (result.harmony) status = `${result.harmony.kind}: ${result.harmony.candidates.join(', ') || 'no 12-TET chord label'}`
    else if (result.clock) status = `host:${result.clock.hostTime} original:${result.clock.originalHostTime} zero:${result.clock.sourceOrigin}`
    else status = 'Edited'
    if (result.effect?.kind === 'help') showHelp = !showHelp
    if (result.effect?.kind === 'play') {
      if (operationSignal.aborted) return
      await onPreview(editor.asset, operationSignal, async run => {
        operationSignal.throwIfAborted()
        suspended = true; process.stdin.off('keypress', keypress)
        try { await run() }
        finally { suspended = false; if (accepting) process.stdin.on('keypress', keypress) }
      })
    }
    if (result.effect?.kind === 'export' && !operationSignal.aborted) {
      await onExport(editor.asset, result.effect.path, operationSignal); status = `Exported ${result.effect.path}`
    }
  }
  function keypress(text, key = {}) {
    if (!accepting || suspended) return
    if (key.ctrl && key.name === 'c') { commit = false; finish(); return }
    if (prompt !== null) {
      if (key.name === 'escape') prompt = null
      else if (key.name === 'return') { const line = prompt; prompt = null; enqueue(() => command(line)) }
      else if (key.name === 'backspace') prompt = [...prompt].slice(0, -1).join('')
      else if (text && !key.ctrl && !key.meta) prompt += text
      draw(); return
    }
    if (key.name === 'q' || key.name === 'escape') { finish(); return }
    if (text === ':') prompt = ''
    else if (key.name === 'tab') enqueue(() => command(editor.selection.kind === 'note' && editor.expressions.length ? 'expressions' : editor.notes.length ? 'notes' : 'events'))
    else if (key.name === 'space') enqueue(() => command('play'))
    else if (['up', 'down'].includes(key.name)) enqueue(() => { editor = umpEditorAction(editor, { kind: 'move', direction: key.name === 'up' ? -1 : 1 }) })
    else if (['u', 'y'].includes(key.name)) enqueue(() => command(key.name === 'u' ? 'undo' : 'redo'))
    draw()
  }
  const aborted = () => { commit = false; finish() }
  const wasRaw = process.stdin.isRaw
  emitKeypressEvents(process.stdin); process.stdin.setRawMode(true); process.stdin.resume()
  process.stdin.on('keypress', keypress); process.stdout.on('resize', draw); signal?.addEventListener('abort', aborted, { once: true })
  if (signal?.aborted) aborted()
  try { draw(); await done; await tail }
  finally {
    signal?.removeEventListener('abort', aborted); process.stdin.off('keypress', keypress); process.stdout.off('resize', draw)
    process.stdin.setRawMode(Boolean(wasRaw))
  }
  return { asset: editor.asset, changed: commit && !signal?.aborted && !isDeepStrictEqual(asset, editor.asset) }
}
