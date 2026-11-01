import { safeText } from './terminal.mjs'

// SGR parameters of the terminal's own 16-colour palette, so its light or
// dark theme decides the drawn colours.
export const bold = '1'
export const dim = '2'
export const inverse = '7'
export const red = '31'
export const green = '32'
export const yellow = '33'
export const blue = '34'
export const magenta = '35'
export const cyan = '36'

export const cellWidth = char => {
  const code = char.codePointAt(0)
  return code >= 0x1100 && (code <= 0x115f || code >= 0x2e80) ? 2 : 1
}

const paint = (text, styles) => text && styles.length ? `\x1b[${styles.join(';')}m${text}\x1b[0m` : text

// A line is a list of [text, styles] segments or any other value, drawn as
// its text as fit() did. It stops before the last terminal column; every
// style it opens is closed again.
export function fitLine(line, columns) {
  const segments = Array.isArray(line) ? line : [[String(line), []]]
  let used = 0, result = ''
  for (const [text, styles] of segments) {
    let piece = ''
    for (const char of safeText(text)) {
      const width = cellWidth(char)
      if (used + width >= columns) return result + paint(piece, styles)
      piece += char; used += width
    }
    result += paint(piece, styles)
  }
  return result
}

// Adjacent [char, styles] cells with the same styles become one segment.
export function cellSegments(cells) {
  const segments = []
  for (const [char, styles] of cells) {
    const last = segments.at(-1)
    if (last && last[1].join(';') === styles.join(';')) last[0] += char
    else segments.push([char, styles])
  }
  return segments
}
