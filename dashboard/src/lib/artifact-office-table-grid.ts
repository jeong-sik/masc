export type OfficeTableCellBounds = { readonly row: number; readonly column: number; readonly rows: number; readonly columns: number }
type RowEvent = { row: number; left: number; right: number; delta: -1 | 1 }

function coordinateIndex(coordinates: readonly number[], value: number): number {
  let left = 0, right = coordinates.length
  while (left < right) {
    const middle = Math.floor((left + right) / 2)
    if (coordinates[middle]! < value) left = middle + 1
    else right = middle
  }
  return left
}

/** Row events and compressed column intervals give O(n log n) checks without a rowCount * columnCount allocation.
 * In-range rectangles cover the grid iff they are disjoint and their exact total area matches it. */
export function checkOfficeTableGrid(rows: number, columns: number, cells: readonly OfficeTableCellBounds[], label: string): void {
  if (!Number.isSafeInteger(rows) || !Number.isSafeInteger(columns) || rows <= 0 || columns <= 0) throw new Error(`${label}의 크기가 올바르지 않습니다.`)
  const edges = [0, columns]
  let area = 0n
  for (const cell of cells) {
    if (![cell.row, cell.column, cell.rows, cell.columns].every(Number.isSafeInteger)
      || cell.row < 0 || cell.column < 0 || cell.rows <= 0 || cell.columns <= 0
      || cell.rows > rows - cell.row || cell.columns > columns - cell.column) throw new Error(`${label}의 셀 범위가 올바르지 않습니다.`)
    edges.push(cell.column, cell.column + cell.columns)
    area += BigInt(cell.rows) * BigInt(cell.columns)
  }
  edges.sort((a, b) => a - b)
  const coordinates = edges.filter((value, index) => index === 0 || value !== edges[index - 1]), events: RowEvent[] = []
  for (const cell of cells) {
    const left = coordinateIndex(coordinates, cell.column), right = coordinateIndex(coordinates, cell.column + cell.columns)
    events.push({ row: cell.row, left, right, delta: 1 }, { row: cell.row + cell.rows, left, right, delta: -1 })
  }
  // Remove ending rectangles before adding starts on the same row: touching edges are disjoint.
  events.sort((a, b) => a.row - b.row || a.delta - b.delta)
  const intervals = coordinates.length - 1, maxima = new Int32Array(intervals * 4 + 1), lazy = new Int32Array(maxima.length)
  function add(node: number, left: number, right: number, start: number, end: number, delta: number): void {
    if (start <= left && right <= end) { lazy[node] = lazy[node]! + delta; maxima[node] = maxima[node]! + delta; return }
    const middle = Math.floor((left + right) / 2)
    if (start < middle) add(node * 2, left, middle, start, end, delta)
    if (end > middle) add(node * 2 + 1, middle, right, start, end, delta)
    maxima[node] = lazy[node]! + Math.max(maxima[node * 2]!, maxima[node * 2 + 1]!)
  }
  for (const event of events) {
    add(1, 0, intervals, event.left, event.right, event.delta)
    if (maxima[1]! > 1) throw new Error(`${label}의 병합 셀이 겹칩니다.`)
  }
  if (area !== BigInt(rows) * BigInt(columns)) throw new Error(`${label}의 셀 격자가 비어 있습니다.`)
}
