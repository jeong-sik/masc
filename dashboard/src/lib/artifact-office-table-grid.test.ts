import { expect, it } from 'vitest'
import JSZip from 'jszip'
import { checkOfficeTableGrid, type OfficeTableCellBounds as Cell } from './artifact-office-table-grid'
import { importArtifactHwpx } from './artifact-hwpx-import'

const check = (rows: number, columns: number, cells: readonly Cell[]) => checkOfficeTableGrid(rows, columns, cells, '표')
const rectangle = (row: number, column: number, rows = 1, columns = 1): Cell => ({ row, column, rows, columns })

it('keeps merged cells and permits shared edges regardless of input order', () => {
  const cells = [rectangle(0, 0, 2), rectangle(0, 1, 1, 2), rectangle(1, 1), rectangle(1, 2, 2), rectangle(2, 0, 1, 2)].map(cell => Object.freeze(cell))
  expect(() => check(3, 3, Object.freeze(cells))).not.toThrow()
  expect(() => check(3, 3, [...cells].reverse())).not.toThrow()
  expect(() => check(2, 1, [rectangle(0, 0), rectangle(1, 0)])).not.toThrow()
  expect(() => check(1, 2, [rectangle(0, 0), rectangle(0, 1)])).not.toThrow()
})
it('refuses overlap even when a hole makes the summed area match', () => {
  expect(() => check(1, 2, [rectangle(0, 0), rectangle(0, 0)])).toThrow('겹칩니다')
  expect(() => check(3, 1, [rectangle(0, 0, 3), rectangle(2, 0)])).toThrow('겹칩니다')
})
it('refuses uncovered cells and empty grids', () => {
  expect(() => check(2, 2, [rectangle(0, 0, 1, 2), rectangle(1, 0)])).toThrow('격자')
  expect(() => check(1, 1, [])).toThrow('격자')
})
for (const cell of [rectangle(-1, 0), rectangle(0, -1), rectangle(0, 0, 0), rectangle(0, 0, 1, 0), rectangle(0, 1, 1, 2), rectangle(0.5, 0), rectangle(0, 0, Infinity), rectangle(NaN, 0)]) {
  it(`refuses invalid cell bounds ${JSON.stringify(cell)}`, () => { expect(() => check(2, 2, [cell])).toThrow('범위') })
}
it('uses exact area without allocating rowCount multiplied by columnCount', () => {
  const dimension = Number.MAX_SAFE_INTEGER
  expect(() => check(dimension, dimension, [rectangle(0, 0, dimension, dimension)])).not.toThrow()
  expect(() => check(dimension, dimension, [rectangle(0, 0, dimension - 1, dimension)])).toThrow('격자')
  expect(() => check(1, dimension, [rectangle(0, dimension - 1, 1, 3)])).toThrow('범위')
})
it('handles every UINT16 column with simultaneous one-row cells', () => {
  const columns = 0xFFFF, cells = Array.from({ length: columns }, (_, column) => rectangle(0, columns - column - 1))
  expect(() => check(1, columns, cells)).not.toThrow()
})
it('matches an independent occupancy oracle for every pair of rectangles in a small grid', () => {
  const rows = 3, columns = 3, rectangles: Cell[] = []
  for (let row = 0; row < rows; row++) for (let column = 0; column < columns; column++) {
    for (let height = 1; height <= rows - row; height++) for (let width = 1; width <= columns - column; width++) rectangles.push(rectangle(row, column, height, width))
  }
  for (const first of rectangles) for (const second of rectangles) {
    const cells = [first, second], occupancy = new Uint8Array(rows * columns)
    for (const cell of cells) for (let row = cell.row; row < cell.row + cell.rows; row++) {
      for (let column = cell.column; column < cell.column + cell.columns; column++) {
        const index = row * columns + column; occupancy[index] = occupancy[index]! + 1
      }
    }
    const expected = occupancy.every(count => count === 1)
    let accepted = true
    try { check(rows, columns, cells) } catch { accepted = false }
    expect(accepted, JSON.stringify(cells)).toBe(expected)
  }
})

async function hwpxTable(overlap: boolean): Promise<Uint8Array> {
  const hp = 'http://www.hancom.co.kr/hwpml/2011/paragraph', opf = 'http://www.idpf.org/2007/opf/'
  const rows = [
    [{ ...rectangle(0, 0, 2), text: '머리' }, { ...rectangle(0, 2), text: 'C' }, { ...rectangle(0, 1), text: 'B' }],
    [{ ...rectangle(1, 2), text: 'F' }, { ...rectangle(1, overlap ? 0 : 1), text: 'E' }],
    [{ ...rectangle(2, 0, 1, 3), text: '합계' }],
    [{ ...rectangle(3, 0), text: '4A' }, { ...rectangle(3, 2), text: '4C' }, { ...rectangle(3, 1), text: '4B' }],
  ]
  const table = `<hp:tbl rowCnt="4" colCnt="3">${rows.map(row => `<hp:tr>${row.map(cell => `<hp:tc><hp:cellAddr rowAddr="${cell.row}" colAddr="${cell.column}"/><hp:cellSpan rowSpan="${cell.rows}" colSpan="${cell.columns}"/><hp:subList><hp:p><hp:run charPrIDRef="0"><hp:t>${cell.text}</hp:t></hp:run></hp:p></hp:subList></hp:tc>`).join('')}</hp:tr>`).join('')}</hp:tbl>`
  const zip = new JSZip().file('mimetype', 'application/hwp+zip')
  zip.file('META-INF/container.xml', '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="Contents/content.hpf" media-type="application/hwpml-package+xml"/></rootfiles></container>')
  zip.file('Contents/content.hpf', `<opf:package xmlns:opf="${opf}"><opf:manifest><opf:item id="header" href="Contents/header.xml" media-type="application/xml"/><opf:item id="body" href="Contents/section0.xml" media-type="application/xml"/></opf:manifest><opf:spine><opf:itemref idref="header"/><opf:itemref idref="body"/></opf:spine></opf:package>`)
  zip.file('Contents/header.xml', '<hh:head xmlns:hh="http://www.hancom.co.kr/hwpml/2011/head"><hh:charPr id="0"/></hh:head>')
  zip.file('Contents/section0.xml', `<hs:sec xmlns:hs="http://www.hancom.co.kr/hwpml/2011/section" xmlns:hp="${hp}"><hp:p><hp:run charPrIDRef="0">${table}</hp:run></hp:p></hs:sec>`)
  return zip.generateAsync({ type: 'uint8array' })
}
it('keeps each HWPX row and orders its cells after shared grid validation', async () => {
  const result = await importArtifactHwpx(await hwpxTable(false)), source = document.createElement('div'); source.innerHTML = result.content
  const table = source.querySelector('table')!
  expect(Array.from(table.rows).map(row => Array.from(row.cells).map(cell => cell.textContent))).toEqual([['머리', 'B', 'C'], ['E', 'F'], ['합계'], ['4A', '4B', '4C']])
  expect(table.rows[0]!.cells[0]!.rowSpan).toBe(2); expect(table.rows[2]!.cells[0]!.colSpan).toBe(3)
})
it('refuses HWPX overlap that is balanced by a hole in another column', async () => {
  await expect(importArtifactHwpx(await hwpxTable(true))).rejects.toThrow('겹칩니다')
})
