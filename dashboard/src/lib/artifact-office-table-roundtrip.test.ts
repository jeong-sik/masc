import { expect, it } from 'vitest'
import JSZip from 'jszip'
import { XMLSerializer } from '@xmldom/xmldom'
import type { ArtifactDocument } from '../api/published-artifacts'
import { artifactWordFile } from './artifact-word-export'
import { artifactHwpxFile } from './artifact-hwpx-export'
import { importArtifactDocx } from './artifact-docx-import'
import { importArtifactHwpx } from './artifact-hwpx-import'
import { officeNs, readOfficeXml, xmlChild, xmlChildren, xmlDescendants } from './artifact-office-xml'
import { hwpxNs } from './artifact-hwpx-template'
import { officeTableTwips } from './artifact-office-prepared'

function artifact(content: string): ArtifactDocument {
  return { content, revisions: [], artifact: { id: `artifact-${'a'.repeat(32)}`, revision: 1, title: '표 너비', summary: '표의 원본 너비',
    format: 'html', author: 'keeper', created_at: '2026-11-17T00:00:00Z', task_id: null, goal_id: null, url: '/', body: { _blob: { sha256: 'b'.repeat(64) } } } }
}
const table = '<table><tr><td>첫 열</td><td>둘</td><td>셋</td></tr><tr><td colspan="3">전체 병합</td></tr></table>'
const word = officeNs.word, hp = hwpxNs.paragraph

// Set native HWPX fields independently of the HTML producer. The values are
// deliberately not multiples of a twip, so a DOCX detour cannot pass this test.
async function sourceHwpx(): Promise<Uint8Array> {
  const zip = await JSZip.loadAsync((await artifactHwpxFile(artifact(table))).data)
  const xml = await readOfficeXml(zip, 'Contents/section0.xml'), node = xmlDescendants(xml, hp, 'tbl')[0]!
  xmlChild(node, hp, 'sz')!.setAttribute('width', '3213')
  const cells = xmlDescendants(node, hp, 'cellSz')
  for (const [index, width] of [1477, 1002, 734, 3213].entries()) cells[index]!.setAttribute('width', String(width))
  zip.file('Contents/section0.xml', new XMLSerializer().serializeToString(xml))
  return zip.generateAsync({ type: 'uint8array' })
}
async function nativeHwpx(data: ArrayBuffer) {
  const zip = await JSZip.loadAsync(data), xml = await readOfficeXml(zip, 'Contents/section0.xml')
  return xmlDescendants(xml, hp, 'tbl').map(node => ({
    width: xmlChild(node, hp, 'sz')!.getAttribute('width'),
    cells: xmlChildren(node, hp, 'tr').flatMap(row => xmlChildren(row, hp, 'tc').map(cell => ({
      width: xmlChild(cell, hp, 'cellSz')!.getAttribute('width'),
      address: [xmlChild(cell, hp, 'cellAddr')!.getAttribute('rowAddr'), xmlChild(cell, hp, 'cellAddr')!.getAttribute('colAddr')],
      span: [xmlChild(cell, hp, 'cellSpan')!.getAttribute('rowSpan'), xmlChild(cell, hp, 'cellSpan')!.getAttribute('colSpan')],
    }))),
  }))
}

it('preserves integer HWPUNIT widths and merged positions through repeated HWPX imports and exports', async () => {
  let content = (await importArtifactHwpx(await sourceHwpx())).content
  let expected: Awaited<ReturnType<typeof nativeHwpx>> | undefined
  for (let round = 0; round < 4; round++) {
    const file = await artifactHwpxFile(artifact(content)), actual = await nativeHwpx(file.data)
    expect(actual[0]!.width).toBe('3213')
    expect(actual[0]!.cells.map(cell => cell.width)).toEqual(['1477', '1002', '734', '3213'])
    if (expected) expect(actual).toEqual(expected)
    expected = actual
    content = (await importArtifactHwpx(file.data)).content
  }
})

it('rounds shared boundaries once for a DOCX grid, every cell and total width', async () => {
  const imported = await importArtifactHwpx(await sourceHwpx())
  const file = await artifactWordFile(artifact(imported.content)), zip = await JSZip.loadAsync(file.data)
  const xml = await readOfficeXml(zip, 'word/document.xml'), node = xmlDescendants(xml, word, 'tbl')[0]!
  expect(xmlDescendants(node, word, 'gridCol').map(col => col.getAttributeNS(word, 'w'))).toEqual(['295', '201', '147'])
  expect(xmlDescendants(node, word, 'tcW').map(cell => cell.getAttributeNS(word, 'w'))).toEqual(['295', '201', '147', '643'])
  expect(xmlDescendants(node, word, 'tblW')[0]!.getAttributeNS(word, 'w')).toBe('643')
  const again = await importArtifactDocx(file.data), second = await artifactWordFile(artifact(again.content))
  const secondXml = await readOfficeXml(await JSZip.loadAsync(second.data), 'word/document.xml')
  expect(xmlDescendants(secondXml, word, 'gridCol').map(col => col.getAttributeNS(word, 'w'))).toEqual(['295', '201', '147'])
})

it('keeps the wide first column from the public HWP table rather than equalizing nine columns', async () => {
  const widths = [14774, 1539, 1539, 1539, 4614, 4614, 4614, 4614, 4321]
  const content = `<table style="width:421.68pt"><tr>${widths.map((width, index) => `<td style="width:${width / 100}pt">${index}</td>`).join('')}</tr></table>`
  const file = await artifactWordFile(artifact(content)), xml = await readOfficeXml(await JSZip.loadAsync(file.data), 'word/document.xml')
  expect(xmlDescendants(xml, word, 'gridCol').map(col => Number(col.getAttributeNS(word, 'w')))).toEqual(officeTableTwips(widths))
  expect(xmlDescendants(xml, word, 'gridCol')[0]!.getAttributeNS(word, 'w')).toBe('2955')
  const hwpx = await nativeHwpx((await artifactHwpxFile(artifact(content))).data)
  expect(hwpx[0]!.cells.map(cell => Number(cell.width))).toEqual(widths)
})

it('preserves all-merged and conflicting source cell widths without inventing original column widths', async () => {
  for (const content of [
    '<table style="width:50.01pt"><tr><td colspan="3" style="width:50.01pt">병합</td></tr></table>',
    '<table style="width:30pt"><tr><td style="width:10pt">A</td><td style="width:20pt">B</td></tr><tr><td colspan="2" style="width:31pt">C</td></tr></table>',
  ]) {
    const hwpx = await artifactHwpxFile(artifact(content)), native = await nativeHwpx(hwpx.data)
    expect(native[0]!.cells.map(cell => cell.width)).toEqual(content.includes('병합') ? ['5001'] : ['1000', '2000', '3100'])
    expect(hwpx.notices.some(notice => notice.includes('너비'))).toBe(true)
    const imported = await importArtifactHwpx(hwpx.data)
    const again = await nativeHwpx((await artifactHwpxFile(artifact(imported.content))).data)
    expect(again).toEqual(native)
  }
})

it('matches geometry by nested blocks, cells and merges when several tables have the same shape', async () => {
  const inner = (width: number, value: string) => `<table style="width:${width / 100}pt"><tr><td style="width:${width / 100}pt">${value}</td></tr></table>`
  const content = `<p>앞</p><table style="width:100.01pt"><tr><td rowspan="2" style="width:60.01pt"><strong>부모</strong>${inner(2177, '첫째')}</td><td style="width:40pt">옆</td></tr><tr><td style="width:40pt">아래${inner(3123, '둘째')}</td></tr></table>${inner(4179, '셋째')}`
  const file = await artifactHwpxFile(artifact(content)), native = await nativeHwpx(file.data)
  expect(native.map(table => table.width)).toEqual(['10001', '2177', '3123', '4179'])
  expect(native[0]!.cells.map(cell => cell.width)).toEqual(['6001', '4000', '4000'])
  const again = await artifactHwpxFile(artifact((await importArtifactHwpx(file.data)).content))
  expect(await nativeHwpx(again.data)).toEqual(native)
})

it('rejects sub-twip grids rather than widening a narrow explicit column', () => {
  expect(officeTableTwips([1002, 1002, 1002])).toEqual([200, 201, 200])
  expect(() => officeTableTwips([1, 1000])).toThrow('단위보다 작습니다')
})

it('keeps percentage and auto preferences distinct from absolute grid widths', async () => {
  const content = '<table style="width:100%"><colgroup><col style="width:20pt"><col style="width:30pt"></colgroup><tr><td style="width:auto">A</td><td style="width:40%">B</td></tr></table>'
  const file = await artifactWordFile(artifact(content)), xml = await readOfficeXml(await JSZip.loadAsync(file.data), 'word/document.xml')
  const tableWidth = xmlDescendants(xml, word, 'tblW')[0]!, cells = xmlDescendants(xml, word, 'tcW')
  expect([tableWidth.getAttributeNS(word, 'w'), tableWidth.getAttributeNS(word, 'type')]).toEqual(['5000', 'pct'])
  expect(cells.map(cell => [cell.getAttributeNS(word, 'w'), cell.getAttributeNS(word, 'type')])).toEqual([['0', 'auto'], ['2000', 'pct']])
  expect(xmlDescendants(xml, word, 'tblLayout')).toHaveLength(0)
  expect(file.notices.some(notice => notice.includes('백분율'))).toBe(true)
})

it('uses declared columns and leaves valid trailing columns empty in both formats', async () => {
  for (const content of [
    '<table><colgroup span="2" style="width:20pt"></colgroup><tr><td>A</td><td>B</td></tr></table>',
    '<table><colgroup><col span="2" style="width:20pt"></colgroup><tr><td>A</td></tr></table>',
  ]) {
    const wordFile = await artifactWordFile(artifact(content)), xml = await readOfficeXml(await JSZip.loadAsync(wordFile.data), 'word/document.xml')
    expect(xmlDescendants(xml, word, 'gridCol').map(col => col.getAttributeNS(word, 'w'))).toEqual(['400', '400'])
    expect(xmlDescendants(xml, word, 'tc')).toHaveLength(2)
    const hwpx = await nativeHwpx((await artifactHwpxFile(artifact(content))).data)
    expect(hwpx[0]!.cells.map(cell => cell.width)).toEqual(['2000', '2000'])
  }
})

it('refuses a nested default grid that cannot fit in its parent cell in integer twips', async () => {
  const content = '<table style="width:0.05pt"><tr><td style="width:0.05pt"><table><tr><td>A</td><td>B</td></tr></table></td></tr></table>'
  await expect(artifactWordFile(artifact(content))).rejects.toThrow('단위보다 작습니다')
  await expect(artifactHwpxFile(artifact(content))).rejects.toThrow('단위보다 작습니다')
})
