// Kitty graphics transport is kept apart from the viewer's terminal effects.
export function safeText(value) {
  return String(value).replace(/[\x00-\x1f\x7f-\x9f]/g, ' ')
}

export function apc(command, data = '', tmux = false) {
  const bytes = `\x1b_G${command}${data ? `;${data}` : ''}\x1b\\`
  return tmux ? `\x1bPtmux;${bytes.replaceAll('\x1b', '\x1b\x1b')}\x1b\\` : bytes
}

// Use one image owned by this child. Its terminal is handed back before the
// parent repaints, so no placement can outlive the score session.
export const scoreImageId = 27183
export function transmit(png, tmux) {
  const data = Buffer.from(png).toString('base64')
  let output = ''
  // Kitty defines a maximum 4096 bytes of base64 per graphics chunk.
  for (let offset = 0; offset < data.length; offset += 4096) {
    const more = offset + 4096 < data.length ? 1 : 0
    output += apc(`${offset === 0 ? `a=t,f=100,i=${scoreImageId},q=2,` : ''}m=${more}`, data.slice(offset, offset + 4096), tmux)
  }
  return output
}

export function viewport(image, { columns, rows, cellWidth, cellHeight, scroll }) {
  const cols = Math.max(1, columns - 2)
  const availableRows = Math.max(1, rows - 4)
  const pixelsPerRow = image.width / cols / cellWidth * cellHeight
  const fullRows = Math.max(1, Math.ceil(image.height / pixelsPerRow))
  const topRow = Math.max(0, Math.min(scroll, Math.max(0, fullRows - availableRows)))
  const visibleRows = Math.min(availableRows, fullRows - topRow)
  const top = Math.floor(topRow * pixelsPerRow)
  const end = Math.min(image.height, Math.floor((topRow + visibleRows) * pixelsPerRow))
  return { cols, rows: visibleRows, top, height: Math.max(1, end - top), scroll: topRow, fullRows, availableRows }
}

export function place(view, tmux) {
  return apc(`a=p,i=${scoreImageId},q=2,p=1,y=${view.top},h=${view.height},c=${view.cols},r=${view.rows},C=1`, '', tmux)
}

export function retire(tmux) {
  return apc(`a=d,d=I,i=${scoreImageId},q=2`, '', tmux)
}
