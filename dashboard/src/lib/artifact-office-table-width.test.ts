import { expect, it } from 'vitest'
import { officeTableFixedLayout, officeTableHtmlStyle, officeTableWidthStyle, parseOfficeTableWidth, resolveOfficeTableWidths, type OfficeTableWidth, type OfficeTableWidthCell } from './artifact-office-table-width'

const absolute = (hwpUnits: number): OfficeTableWidth => ({ kind: 'absolute', hwpUnits })
const cell = (column: number, columns: number, hwpUnits: number): OfficeTableWidthCell => ({ column, columns, width: absolute(hwpUnits) })

it.each([[14774, '147.74pt'], [1539, '15.39pt'], [100, '1pt'], [10, '0.1pt'], [1, '0.01pt'], [0, '0pt'], [4294967295, '42949672.95pt']])('keeps %s HWPUNIT in canonical standard HTML', (hwpUnits, css) => {
  expect(officeTableWidthStyle(absolute(hwpUnits))).toBe(`width:${css}`)
  expect(parseOfficeTableWidth(`width:${css}`)).toEqual(absolute(hwpUnits))
})
it.each([['2px', 150], ['1in', 7200], ['1pc', 1200], ['1.27mm', 360], ['1.27cm', 3600], ['1e2pt', 10000], ['+1pt', 100], ['0', 0]])('reads CSS absolute length %s without binary floating point drift', (css, hwpUnits) => {
  expect(parseOfficeTableWidth(`width:${css}`)).toEqual(absolute(hwpUnits))
})
it('uses CSS declaration order and importance without splitting strings or comments', () => {
  expect(parseOfficeTableWidth('background:url("data:text/plain;a:b"); width:12pt; /* ; width:2pt */ width:33pt !important; width:14pt')).toEqual(absolute(3300))
  expect(parseOfficeTableWidth('width:12pt!important;width:3pt !IMPORTANT')).toEqual(absolute(300))
  expect(parseOfficeTableWidth('w\\69 dth:1p\\74')).toEqual(absolute(100))
  expect(parseOfficeTableWidth('color:red', '12')).toEqual(absolute(900))
  expect(parseOfficeTableWidth('width:auto', '12')).toEqual({ kind: 'auto' })
  expect(parseOfficeTableWidth(undefined, '33.5%')).toEqual({ kind: 'percent', value: 33.5 })
  expect(parseOfficeTableWidth(undefined)).toEqual({ kind: 'absent' })
})
it.each(['calc(100% - 1pt)', 'var(--table-width)', '2em', '1mm', '0.3333333333333333pt', '1e1000000000pt', '-1pt', '9007199254740993pt', '0.000000000000000000001pt'])('retains unsupported CSS %s as unknown geometry', value => {
  expect(parseOfficeTableWidth(`width:${value}`)).toEqual({ kind: 'unsupported', value })
})
it.each(['1\\30 pt', '1\\30 0pt', '\\31 0pt', '1. pt', '1.pt', '1 p\\74'])('never synthesizes a numeric token while decoding CSS escapes: %s', value => {
  expect(parseOfficeTableWidth(`width:${value}`)).toEqual({ kind: 'unsupported', value })
})
it('rejects rules inside inline declarations and never loads source-map annotations', () => {
  expect(() => parseOfficeTableWidth('width:1pt}body{width:2pt')).toThrow()
  expect(() => parseOfficeTableWidth('@media all {width:1pt}')).toThrow()
  expect(parseOfficeTableWidth('width:2pt;/*# sourceMappingURL=file:///missing-masc-source-map */')).toEqual(absolute(200))
})
it('solves unequal native cell widths and sums merged intervals exactly', () => {
  expect(resolveOfficeTableWidths(9, [cell(0, 1, 14774), cell(1, 3, 4617), cell(1, 1, 1539), cell(2, 1, 1539), cell(3, 1, 1539),
    cell(4, 1, 4614), cell(5, 1, 4614), cell(6, 1, 4614), cell(7, 1, 4614), cell(8, 1, 4321)], { table: absolute(42168) })).toEqual({
    kind: 'unique', widths: [14774, 1539, 1539, 1539, 4614, 4614, 4614, 4614, 4321],
  })
  expect(resolveOfficeTableWidths(3, [cell(0, 2, 6000), cell(2, 1, 4000), cell(0, 1, 2000), cell(1, 2, 8000)])).toEqual({ kind: 'unique', widths: [2000, 4000, 4000] })
})
it('keeps internal boundaries unknown when every cell spans the same columns', () => {
  expect(resolveOfficeTableWidths(3, [cell(0, 3, 9000), cell(0, 3, 9000)])).toEqual({ kind: 'partial', widths: [null, null, null] })
  expect(resolveOfficeTableWidths(3, [cell(0, 2, 6000)], { columns: [absolute(2000), { kind: 'absent' }, { kind: 'absent' }] })).toEqual({ kind: 'partial', widths: [2000, 4000, null] })
  expect(resolveOfficeTableWidths(2, [], { columns: [absolute(3000), { kind: 'auto' }], table: { kind: 'percent', value: 100 } })).toEqual({ kind: 'partial', widths: [3000, null] })
})
it('does not count a rowspan more than once and leaves conflicting preferences unresolved', () => {
  expect(resolveOfficeTableWidths(2, [cell(0, 1, 3000), cell(1, 1, 7000), cell(1, 1, 7000)])).toEqual({ kind: 'unique', widths: [3000, 7000] })
  expect(resolveOfficeTableWidths(2, [cell(0, 1, 3000), cell(0, 1, 3100), cell(1, 1, 7000)])).toEqual({ kind: 'conflicting', widths: [null, null] })
  expect(resolveOfficeTableWidths(2, [cell(0, 2, 9000)], { columns: [absolute(6000), absolute(4000)] }).kind).toBe('conflicting')
})
it('uses memory proportional to declared boundaries and cell intervals rather than table area', () => {
  expect(resolveOfficeTableWidths(1000, Array.from({ length: 4001 }, () => cell(0, 1000, 42000))).kind).toBe('partial')
  expect(() => resolveOfficeTableWidths(2, [cell(1, 2, 100)])).toThrow('구간')
  expect(() => resolveOfficeTableWidths(2, [], { columns: [absolute(1)] })).toThrow('개수')
})

it('fixes browser tracks only when positive absolute source constraints determine every boundary', () => {
  const cells = [cell(0, 1, 14774), cell(1, 1, 1539)]
  expect(officeTableFixedLayout(2, cells)).toEqual({ width: 16313, widths: [14774, 1539] })
  expect(officeTableHtmlStyle({ kind: 'absent' }, officeTableFixedLayout(2, cells))).toBe('width:163.13pt;table-layout:fixed;border-collapse:collapse;border-spacing:0')
  expect(officeTableFixedLayout(1, [cell(0, 1, 1001), cell(0, 1, 1001)])).toEqual({ width: 1001, widths: [1001] })
  expect(officeTableFixedLayout(3, [cell(0, 3, 9000)])).toBeNull()
  expect(officeTableFixedLayout(2, [cell(0, 1, 3000), cell(0, 1, 3100), cell(1, 1, 7000)])).toBeNull()
  expect(officeTableFixedLayout(2, [cell(0, 1, 0), cell(1, 1, 3000)])).toBeNull()
})
it.each<OfficeTableWidth>([{ kind: 'auto' }, { kind: 'percent', value: 100 }, { kind: 'unsupported', value: 'var(--width)' }])('keeps $kind preferences automatic even when other constraints identify the grid', preference => {
  const cells = [cell(0, 1, 1000), cell(1, 1, 2000)], columns = [absolute(1000), absolute(2000)]
  expect(officeTableFixedLayout(2, cells, { table: preference, columns })).toBeNull()
  expect(officeTableFixedLayout(2, [...cells, { column: 0, columns: 1, width: preference }], { table: absolute(3000), columns })).toBeNull()
  expect(officeTableFixedLayout(2, cells, { table: absolute(3000), columns: [preference, absolute(2000)] })).toBeNull()
  expect(officeTableHtmlStyle(preference, null)).toBe(officeTableWidthStyle(preference))
})
it('does not allocate a logical-column array for a sparse, huge merged interval', () => {
  expect(officeTableFixedLayout(4294967295, [cell(0, 4294967295, 3000)], { table: absolute(3000), columns: [] })).toBeNull()
})
