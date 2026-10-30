import { cellSegments, bold, dim, inverse, green, yellow, blue, magenta, cyan, red } from './candidate-terminal-style.mjs'
const blackKeys = new Set([1, 3, 6, 8, 10])
const pitchColors = [cyan, blue, green, magenta, yellow, red, '96', '94', '92', '95', '93', '91']
export function compute({rows,cols,editor,project,playColumn,first,track,selection,current,percussion}) {
  const lines = [], noteName = String
      const height = Math.max(1, rows - 12), high = Math.min(127, Math.max(height - 1, editor.pitch + Math.floor(height / 2)))
      const notesByPitch = Map.groupBy(track.notes.filter(note => note.pitch <= high && note.pitch > high - height
        && note.start < first + cols * editor.step && note.start + note.duration > first), note => note.pitch)
      for (let y = 0; y < height; y++) {
        const pitch = high - y
        if (pitch < 0) break
        const cells = Array.from({ length: cols }, (_, x) => first + x * editor.step >= project.length ? [' ', []] : pitch % 12 === 0 ? ['─', [dim, cyan]] : ['·', [dim]])
        for (const note of notesByPitch.get(pitch) ?? []) {
          const left = Math.max(0, Math.floor((note.start - first) / editor.step))
          const right = Math.min(cols - 1, Math.ceil((note.start + note.duration - first) / editor.step) - 1)
          for (let x = left; x <= right; x++) cells[x] = selection.has(note.id) ? ['▓', [bold, yellow]]
            : first + x * editor.step <= note.start ? ['█', [bold, pitchColors[pitch % 12]]] : ['▬', [bold, pitchColors[pitch % 12]]]
        }
        // A note under the playhead is sounding; empty cells draw its line.
        if (playColumn !== null && playColumn >= 0 && playColumn < cols && first + playColumn * editor.step < project.length) {
          const [glyph, styles] = cells[playColumn]
          cells[playColumn] = '█▬▓'.includes(glyph) ? [glyph, [bold, green, inverse]] : ['│', [green]]
        }
        const cursor = Math.floor((editor.tick - first) / editor.step)
        if (pitch === editor.pitch && cursor >= 0 && cursor < cols) cells[cursor] = [current ? '◆' : '◇', [bold, magenta, inverse]]
        const label = percussion ? [] : [pitchColors[pitch % 12], ...(pitch % 12 === 0 || pitch === editor.pitch ? [bold] : blackKeys.has(pitch % 12) ? [dim] : [])]
        lines.push([[noteName(pitch).padStart(5), label], ['  ', []], ...cellSegments(cells)])
      }
  return lines
}
