import cliTruncate from 'cli-truncate'
import stringWidth from 'string-width'
import { safeText } from './terminal.mjs'

const graphemes = new Intl.Segmenter(undefined, { granularity: 'grapheme' })

function wrap(text, width) {
  const rows = []
  for (const source of text.split(/\r\n|\r|\n/)) {
    let line = '', used = 0
    for (const { segment } of graphemes.segment(safeText(source))) {
      const cells = stringWidth(segment, { countAnsiEscapeCodes: true })
      if (used + cells > width && line.length) { rows.push(line); line = ''; used = 0 }
      line += segment; used += cells
    }
    rows.push(line)
  }
  return rows
}

// A reading owns only the message observed at open, never an editor or transport
// snapshot. Normal asynchronous work continues; closing reveals its current state.
export class StatusReader {
  #reading = null
  #offset = 0
  #wrapped = null

  open(title, body) {
    this.#reading = Object.freeze({ title, body })
    this.#offset = 0
    this.#wrapped = null
  }

  command(line, title, body) {
    // Exact, argument-free UI grammar; do not enter editor effect dispatch.
    if (line.trim() !== 'status') return false
    this.open(title, body)
    return true
  }

  #view({ columns = 80, rows = 24 }) {
    const width = Math.max(0, columns - 1), height = Math.max(0, rows - 2)
    if (width < 2 || height === 0) return { width, height: 0, rows: [] }
    if (this.#wrapped?.width !== width) {
      // Preserve authored newlines before sanitizing terminal controls. Source
      // text remains unchanged in the frozen reading; wrapping is display only.
      this.#wrapped = { width, rows: wrap(this.#reading.body, width) }
    }
    const lines = this.#wrapped.rows
    this.#offset = Math.min(this.#offset, Math.max(0, lines.length - height))
    return { width, height, rows: lines }
  }

  keypress(text, key, geometry) {
    if (this.#reading === null) return false
    if (['escape', 'q', 'return'].includes(key.name) || text === '!' || key.ctrl && key.name === 'l') {
      this.#reading = null; this.#wrapped = null
      return true
    }
    const view = this.#view(geometry)
    if (view.height) {
      switch (key.name) {
        case 'up': case 'k': this.#offset--; break
        case 'down': case 'j': this.#offset++; break
        case 'pageup': this.#offset -= view.height; break
        case 'pagedown': case 'space': this.#offset += view.height; break
        case 'home': this.#offset = 0; break
        case 'end': this.#offset = view.rows.length - view.height; break
      }
      this.#offset = Math.max(0, Math.min(this.#offset, Math.max(0, view.rows.length - view.height)))
    }
    // All input belongs to the open reading. In particular, save/edit/play/record
    // keys cannot fall through into the view underneath it.
    return true
  }

  render(geometry) {
    if (this.#reading === null) return null
    const view = this.#view(geometry), rows = geometry.rows || 24
    const fit = text => cliTruncate(safeText(text), view.width)
    let output = '\x1b[H'
    for (let row = 1; row <= rows; row++) output += `\x1b[${row};1H\x1b[2K`
    if (!view.height) return output + `\x1b[1;1H${fit('Resize to read status; Esc returns')}`
    output += `\x1b[1;1H${fit(this.#reading.title)}`
    view.rows.slice(this.#offset, this.#offset + view.height).forEach((line, index) => {
      output += `\x1b[${index + 2};1H${line}`
    })
    output += `\x1b[${rows};1H${fit(`${this.#offset + 1}–${Math.min(view.rows.length, this.#offset + view.height)}/${view.rows.length} · ↑/↓ PgUp/PgDn Home/End · Esc/q: return`)}`
    return output
  }
}
