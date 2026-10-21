import { emitKeypressEvents } from 'node:readline'
import { isDeepStrictEqual } from 'node:util'
import { newUmpEditor, umpEditorAction, umpEditorCommand } from './ump-editor.mjs'
import { safeText } from './terminal.mjs'

// The arrangement lends its terminal. All file/device effects remain owned by
// callbacks which settle before this child returns or the parent adopts edits.
export async function viewUmpEditor({ asset, packets, signal, onPreview, onExport }) {
  if (!process.stdin.isTTY || !process.stdout.isTTY) throw new Error('UMP editor requires a terminal')
  if (signal?.aborted) return { changed: false, asset }
  let editor = newUmpEditor(asset, packets), prompt = null, status = 'Select a MIDI2 attack; :help lists commands'
  let accepting = true, suspended = false, showHelp = false, tail = Promise.resolve(), commit = true
  const close = new AbortController(), operationSignal = signal ? AbortSignal.any([signal, close.signal]) : close.signal
  let finish
  const done = new Promise(resolve => { finish = () => { accepting = false; close.abort(); resolve() } })
  function draw() {
    if (!accepting || suspended) return
    const selected = editor.notes.findIndex(note => note.id === editor.selected), height = Math.max(1, (process.stdout.rows || 24) - 6)
    const first = Math.max(0, selected - Math.floor(height / 2))
    const lines = [`Native UMP · ${asset.name} · ${status}`,
      'Pitch edits explicitly override this attack with Pitch7.9; note indices and per-note addresses stay fixed.',
      'Up/Down: attack · u/y: undo/redo · Space: native audition · :command · q: return variant · Ctrl+C: discard']
    if (showHelp) lines.push(...[
      ':scope SOURCE GROUP CHANNEL (1–16) selects its first attack; :select PACKET:WORD selects an exact original message',
      ':pitch-absolute 60.5 sets exact MIDI-note units (1/512); :velocity 0–65535; :reset-note restores original fields',
      ':revoice Cmaj7 drop2 [OCTAVE [INVERSION]] changes the exact-onset group in this source/group/channel',
      ':harmony shows onset candidates; key indices do not resolve MTS/per-note tuning; fractional pitches stay fractional',
      ':play opens native audition; original WAV is unchanged; choose explicit MIDI outputs in the session viewer',
      ':export NEW_DIRECTORY writes edited/original UMP, original audio/clock and provenance; no PPQ conversion',
      'Manufacturer/Profile attributes cannot be overwritten by absolute pitch; velocity edits retain their bytes',
    ])
    else for (const note of editor.notes.slice(first, first + height)) lines.push(
      `${note.id === editor.selected ? '>' : ' '} ${note.id} ${note.source} g${note.group + 1}/ch${note.channel + 1} host:${note.hostTime} index:${note.index} pitch:${note.pitch / 512} (${note.basis}) vel16:${note.velocity}`)
    lines.push(prompt === null ? '' : `:${prompt}`)
    process.stdout.write('\x1b[H\x1b[2J' + lines.map(line => safeText(line).slice(0, Math.max(1, (process.stdout.columns || 80) - 1))).join('\n'))
  }
  function enqueue(action) {
    tail = tail.then(action).catch(error => { if (accepting) status = error.message }).finally(draw)
  }
  async function command(line) {
    const result = umpEditorCommand(editor, line); editor = result.editor
    if (result.harmony) status = `${result.harmony.kind}: ${result.harmony.candidates.join(', ') || 'no 12-TET chord label'}`
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
