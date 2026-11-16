import { expect, it } from 'vitest'
import JSZip from 'jszip'
import { DOMParser, XMLSerializer, type Document as XmlDocument, type Element as XmlElement } from '@xmldom/xmldom'
import { Document, Paragraph, Table, TableCell, TableRow, Packer } from 'docx'
import { ChartRun } from 'docx/charts'
import type { ArtifactDocument } from '../api/published-artifacts'
import { importArtifactDocx } from './artifact-docx-import'
import { importArtifactHwpx } from './artifact-hwpx-import'
import { artifactWordFile } from './artifact-word-export'
import { artifactHwpxFile } from './artifact-hwpx-export'
import { artifactHtmlTextEditor } from './artifact-html-text'
import { seedSharedDocument, selectSharedTextRange, replaceSharedSelection, sharedSource } from './artifact-shared-document'
import { loadOfficeArchive, readOfficeBytes, officeImportLimits, parseOfficeXml } from './artifact-office-xml'

const word = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'
const chart = 'http://schemas.openxmlformats.org/drawingml/2006/chart'
const sheet = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
const paragraph = 'http://www.hancom.co.kr/hwpml/2011/paragraph'
const formats = ['docx', 'hwpx'] as const, kinds = ['column', 'bar', 'line', 'pie'] as const
type Format = typeof formats[number]
type Kind = typeof kinds[number]
const categories = ['서울', '부산', '대전', '인천']
const serializer = new XMLSerializer()
const elements = (xml: XmlDocument | XmlElement, namespace: string, name: string) => Array.from(xml.getElementsByTagNameNS(namespace, name))
async function xmlPart(zip: JSZip, path: string): Promise<XmlDocument> {
  const part = zip.file(path); expect(part).not.toBeNull()
  return new DOMParser().parseFromString(await part!.async('string'), 'application/xml')
}
function artifact(content: string): ArtifactDocument {
  return { content, revisions: [], artifact: { id: `artifact-${'a'.repeat(32)}`, revision: 3, title: '예산', summary: '입력 자료',
    format: 'html', author: 'keeper', created_at: '2026-11-16T00:00:00Z', task_id: null, goal_id: null, url: '/', body: { _blob: { sha256: 'b'.repeat(64) } } } }
}
function html(content: string): HTMLDivElement { const div = document.createElement('div'); div.innerHTML = content; return div }
function figures(content: string) {
  return Array.from(html(content).querySelectorAll('figure')).map(figure => {
    const rows = Array.from(figure.querySelectorAll('tr')), headers = Array.from(rows[0]!.querySelectorAll('th')).slice(1)
    return { kind: figure.getAttribute('data-masc-chart'), categories: rows.slice(1).map(row => row.cells[0]!.textContent),
      names: headers.map(header => header.textContent), values: headers.map((_, column) => rows.slice(1).map(row => {
        const value = row.cells[column + 1]!.textContent!; return value.trim() === '' ? null : Number(value)
      })) }
  })
}
function tableCells(content: string) {
  const table = Array.from(html(content).querySelectorAll('table')).find(table => !table.closest('figure'))!
  return Array.from(table.rows).map(row => Array.from(row.cells).map(cell => ({ value: cell.textContent, rows: cell.rowSpan, columns: cell.colSpan })))
}
const expectedCells = [
  [{ value: '합계', rows: 2, columns: 1 }, { value: '계약금액', rows: 1, columns: 2 }],
  [{ value: '현재', rows: 1, columns: 1 }, { value: '', rows: 1, columns: 1 }],
]
async function independentDocx(kind: Kind | 'area' = 'column', stacking: 'none' | 'stacked' = 'none'): Promise<Uint8Array> {
  const series = [{ name: '실적', values: [2, null, 0, kind === 'pie' ? 3 : -3] }]
  const run = kind === 'pie' ? new ChartRun({ type: kind, title: '집행 금액', categories, series })
    : new ChartRun({ type: kind, title: '집행 금액', categories, stacking, series: [...series, { name: '예산', values: [10, 20, null, 40] }] })
  return Packer.toBuffer(new Document({ sections: [{ children: [
    new Table({ rows: [
      new TableRow({ children: [new TableCell({ rowSpan: 2, children: [new Paragraph('합계')] }), new TableCell({ columnSpan: 2, children: [new Paragraph('계약금액')] })] }),
      new TableRow({ children: [new TableCell({ children: [new Paragraph('현재')] }), new TableCell({ children: [new Paragraph({})] })] }),
    ] }), new Paragraph({ children: [run] }),
  ] }] }))
}
const exportFile = (format: Format, content: string) => format === 'docx' ? artifactWordFile(artifact(content)) : artifactHwpxFile(artifact(content))
const importFile = (format: Format, data: ArrayBuffer | Uint8Array) => format === 'docx' ? importArtifactDocx(data) : importArtifactHwpx(data)
async function inspectNative(data: ArrayBuffer, format: Format, kind: Kind, firstValue: string) {
  const zip = await JSZip.loadAsync(data), chartPath = format === 'docx' ? 'word/charts/chart1.xml' : 'Chart/chart1.xml'
  const xml = await xmlPart(zip, chartPath), caches = elements(xml, chart, 'numCache')
  const type = kind === 'column' || kind === 'bar' ? 'barChart' : `${kind}Chart`
  expect(elements(xml, chart, type)).toHaveLength(1)
  if (kind === 'column' || kind === 'bar') expect(elements(xml, chart, 'barDir')[0]!.getAttribute('val')).toBe(kind === 'column' ? 'col' : 'bar')
  expect(elements(caches[0]!, chart, 'ptCount')[0]!.getAttribute('val')).toBe('4')
  expect(elements(caches[0]!, chart, 'pt').map(point => [point.getAttribute('idx'), elements(point, chart, 'v')[0]!.textContent]))
    .toEqual([['0', firstValue], ['2', '0'], ['3', kind === 'pie' ? '3' : '-3']])
  expect(Object.keys(zip.files).filter(path => path.endsWith('.xlsx'))).toHaveLength(1)
  if (format === 'docx') {
    const body = await xmlPart(zip, 'word/document.xml')
    expect(elements(body, word, 'tbl')).toHaveLength(1)
    expect(elements(body, word, 'gridSpan').some(span => span.getAttributeNS(word, 'val') === '2')).toBe(true)
    expect(elements(body, word, 'vMerge').some(merge => merge.getAttributeNS(word, 'val') === 'restart')).toBe(true)
  } else {
    const body = await xmlPart(zip, 'Contents/section0.xml')
    expect(elements(body, paragraph, 'tbl')).toHaveLength(1)
    expect(elements(body, paragraph, 'chart')).toHaveLength(1)
    expect(elements(body, paragraph, 'cellSpan').some(span => span.getAttribute('colSpan') === '2')).toBe(true)
    expect(elements(body, paragraph, 'cellSpan').some(span => span.getAttribute('rowSpan') === '2')).toBe(true)
  }
  return zip
}

for (const format of formats) for (const kind of kinds) it(`${format} keeps native ${kind} data and merged cells through editing and re-export`, async () => {
  const imported = await importArtifactDocx(await independentDocx(kind)), first = await exportFile(format, imported.content)
  await inspectNative(first.data, format, kind, '2')
  const again = await importFile(format, first.data)
  expect(tableCells(again.content)).toEqual(expectedCells)
  expect(figures(again.content)[0]).toEqual({ kind, categories, names: kind === 'pie' ? ['실적'] : ['실적', '예산'],
    values: kind === 'pie' ? [[2, null, 0, 3]] : [[2, null, 0, -3], [10, 20, null, 40]] })
  const part = artifactHtmlTextEditor(again.content).parts.find(part => part.text === '2')!
  expect(part).toBeDefined()
  const shared = seedSharedDocument(again.content)
  try {
    replaceSharedSelection(shared, selectSharedTextRange(shared, { anchor: part.start, head: part.end }), part.raw, '7.5')
    const edited = await exportFile(format, sharedSource(shared))
    await inspectNative(edited.data, format, kind, '7.5')
    expect(figures((await importFile(format, edited.data)).content)[0]!.values[0]).toEqual([7.5, null, 0, kind === 'pie' ? 3 : -3])
  } finally { shared.destroy() }
})

async function mutateChart(change: (xml: XmlDocument) => void): Promise<Uint8Array> {
  const zip = await JSZip.loadAsync(await independentDocx()), path = 'word/charts/chart1.xml', xml = await xmlPart(zip, path)
  change(xml); zip.file(path, serializer.serializeToString(xml)); return zip.generateAsync({ type: 'uint8array' })
}
it('rejects cache values that disagree with the embedded workbook', async () => {
  const zip = await JSZip.loadAsync(await independentDocx()), path = Object.keys(zip.files).find(path => path.endsWith('.xlsx'))!
  const book = await JSZip.loadAsync(await zip.file(path)!.async('uint8array')), xml = await xmlPart(book, 'xl/worksheets/sheet1.xml')
  const cell = elements(xml, sheet, 'c').find(cell => cell.getAttribute('r') === 'B2')!
  elements(cell, sheet, 'v')[0]!.textContent = '99'
  book.file('xl/worksheets/sheet1.xml', serializer.serializeToString(xml)); zip.file(path, await book.generateAsync({ type: 'uint8array' }))
  await expect(importArtifactDocx(await zip.generateAsync({ type: 'uint8array' }))).rejects.toThrow()
})
it('rejects duplicate chart point indices without substituting a value', async () => {
  const file = await mutateChart(xml => { const cache = elements(xml, chart, 'numCache')[0]!; cache.appendChild(elements(cache, chart, 'pt')[0]!.cloneNode(true)) })
  await expect(importArtifactDocx(file)).rejects.toThrow()
})
it('refuses stacked charts and unsupported native chart kinds', async () => {
  await expect(importArtifactDocx(await independentDocx('column', 'stacked'))).rejects.toThrow()
  await expect(importArtifactDocx(await independentDocx('area'))).rejects.toThrow()
})

for (const wrapper of ['sdt', 'sdtContent', 'customXml', 'ins', 'unknownWrapper']) for (const element of ['tr', 'tc']) {
  it(`keeps ${element} content in ${wrapper}, or refuses an unknown table structure`, async () => {
    const zip = await JSZip.loadAsync(await independentDocx()), path = 'word/document.xml', xml = await xmlPart(zip, path)
    const entry = elements(xml, word, element)[0]!, container = xml.createElementNS(word, `w:${wrapper}`)
    entry.parentNode!.insertBefore(container, entry)
    if (wrapper === 'sdt') { const content = xml.createElementNS(word, 'w:sdtContent'); container.appendChild(content); content.appendChild(entry) } else container.appendChild(entry)
    zip.file(path, serializer.serializeToString(xml)); const file = await zip.generateAsync({ type: 'uint8array' })
    if (wrapper === 'unknownWrapper') await expect(importArtifactDocx(file)).rejects.toThrow()
    else expect(tableCells((await importArtifactDocx(file)).content)).toEqual(expectedCells)
  })
}
it('fills a real blank imported DOCX cell through a shared text selection and exports the new value', async () => {
  const imported = await importArtifactDocx(await independentDocx()), part = artifactHtmlTextEditor(imported.content).parts.find(part => part.text === '')!
  expect(part).toBeDefined()
  const shared = seedSharedDocument(imported.content)
  try {
    const selection = selectSharedTextRange(shared, { anchor: part.start, head: part.end })
    replaceSharedSelection(shared, selection, part.raw, '37')
    const file = await artifactWordFile(artifact(sharedSource(shared))), result = await importArtifactDocx(file.data)
    expect(tableCells(result.content)[1]![1]).toEqual({ value: '37', rows: 1, columns: 1 })
    expect(() => replaceSharedSelection(shared, selection, '', '48')).toThrow()
  } finally { shared.destroy() }
})
it('refuses an over-limit ZIP entry while decompressing its bytes', async () => {
  const input = new JSZip().file('part.xml', 'x'.repeat(officeImportLimits.partBytes + 1))
  const zip = await loadOfficeArchive(await input.generateAsync({ type: 'uint8array', compression: 'DEFLATE' }))
  await expect(readOfficeBytes(zip, 'part.xml')).rejects.toThrow()
})

for (const format of formats) for (const empty of ['zero', 'connect'] as const) it(`${format} preserves ${empty} gaps and percentage formats in native XML and workbook cells`, async () => {
  const source = html((await importArtifactDocx(await independentDocx('line'))).content), figure = source.querySelector('figure')!
  figure.setAttribute('data-masc-empty-values', empty); figure.setAttribute('data-masc-value-format', '0.00%')
  figure.querySelectorAll('th')[1]!.setAttribute('data-masc-number-format', '0.0%')
  const file = await exportFile(format, source.innerHTML), zip = await JSZip.loadAsync(file.data)
  const xml = await xmlPart(zip, format === 'docx' ? 'word/charts/chart1.xml' : 'Chart/chart1.xml')
  expect(elements(xml, chart, 'dispBlanksAs')[0]!.getAttribute('val')).toBe(empty === 'connect' ? 'span' : 'zero')
  expect(elements(elements(xml, chart, 'valAx')[0]!, chart, 'numFmt')[0]!.getAttribute('formatCode')).toBe('0.00%')
  expect(elements(elements(xml, chart, 'numCache')[0]!, chart, 'formatCode')[0]!.textContent).toBe('0.0%')
  const bookPath = Object.keys(zip.files).find(path => path.endsWith('.xlsx'))!, book = await JSZip.loadAsync(await zip.file(bookPath)!.async('uint8array'))
  const styles = await xmlPart(book, 'xl/styles.xml'), cells = await xmlPart(book, 'xl/worksheets/sheet1.xml')
  const formats = elements(styles, sheet, 'numFmt'), definitions = elements(elements(styles, sheet, 'cellXfs')[0]!, sheet, 'xf')
  for (const address of ['B2', 'B3']) {
    const cell = elements(cells, sheet, 'c').find(cell => cell.getAttribute('r') === address)!, style = cell.getAttribute('s')
    expect(style).not.toBeNull()
    const formatId = definitions[Number(style)]!.getAttribute('numFmtId')
    expect(formats.find(format => format.getAttribute('numFmtId') === formatId)!.getAttribute('formatCode')).toBe('0.0%')
  }
  const round = html((await importFile(format, file.data)).content).querySelector('figure')!
  expect(round.getAttribute('data-masc-empty-values')).toBe(empty)
  expect(round.getAttribute('data-masc-value-format')).toBe('0.00%')
  expect(round.querySelectorAll('th')[1]!.getAttribute('data-masc-number-format')).toBe('0.0%')
})

for (const invalid of ['\u0001', '\u0000', '\uD800', '\uDC00', '&#x1;', '&#1;', '&#xD800;', '&#x110000;']) {
  it(`refuses XML 1.0 forbidden literal or reference ${JSON.stringify(invalid)}`, () => {
    expect(() => parseOfficeXml(`<x a="${invalid}">${invalid}</x>`, 'fixture.xml')).toThrow()
  })
}
it('accepts XML whitespace and Unicode, with inert references in comments, CDATA and processing instructions', () => {
  const xml = parseOfficeXml('<x a="&#9;&#10;&#13;한글😀">\t\n\r한글😀<!-- &#x1; --><![CDATA[&#1;]]><?keep &#x1;?></x>', 'valid.xml')
  expect(xml.documentElement!.getAttribute('a')).toBe('\t\n\r한글😀')
  expect(xml.documentElement!.textContent).toContain('한글😀')
})
it('accepts literal and referenced replacement characters in XML text and quoted attributes', () => {
  const xml = parseOfficeXml('<x a="A�B">A�B&#xFFFD;</x>', 'replacement.xml')
  expect(xml.documentElement!.getAttribute('a')).toBe('A�B'); expect(xml.documentElement!.textContent).toBe('A�B�')
})
for (const invalid of ['<x a=ok>A�B</x>', '<x a=ok b=no>A�B</x>', '<x>A�B</y>', '<!DOCTYPE x><x>A�B</x>']) {
  it(`still refuses malformed XML or DTD after the replacement-character warning: ${invalid}`, () => {
    expect(() => parseOfficeXml(invalid, 'malformed-replacement.xml')).toThrow()
  })
}
for (const format of formats) for (const character of ['�', '\u0001']) it(`${format} keeps ${JSON.stringify(character)} after Word replacement, import and repeated export`, async () => {
  const wordFile = await artifactWordFile(artifact(`<p>A${character}B</p>`))
  if (character === '\u0001') expect(wordFile.notices).toContain('Word에서 표현할 수 없는 문자는 대체 문자로 바꿨습니다.')
  let content = (await importArtifactDocx(wordFile.data)).content
  for (let pass = 0; pass < 2; pass++) {
    content = (await importFile(format, (await exportFile(format, content)).data)).content
    expect(html(content).textContent).toBe('A�B')
  }
})
for (const format of formats) it(`${format} accepts replacement characters in title and author metadata`, async () => {
  const source = artifact('<p>A�B</p>'), doc = { ...source, artifact: { ...source.artifact, title: '제목�', author: '작성자�' } }
  const file = await (format === 'docx' ? artifactWordFile : artifactHwpxFile)(doc), zip = await JSZip.loadAsync(file.data)
  const path = format === 'docx' ? 'docProps/core.xml' : 'Contents/content.hpf', metadata = parseOfficeXml(await zip.file(path)!.async('string'), path)
  expect(metadata.documentElement!.textContent).toContain('제목�'); expect(metadata.documentElement!.textContent).toContain('작성자�')
  expect(html((await importFile(format, file.data)).content).textContent).toBe('A�B')
})
for (const field of ['title', 'author'] as const) it(`refuses invalid HWPX ${field} metadata and reports DOCX replacement`, async () => {
  const source = artifact('<p>문서</p>'), doc = { ...source, artifact: { ...source.artifact, [field]: '앞\u0001뒤' } }
  await expect(artifactHwpxFile(doc)).rejects.toThrow()
  const file = await artifactWordFile(doc), zip = await JSZip.loadAsync(file.data), core = await xmlPart(zip, 'docProps/core.xml')
  expect(elements(core, 'http://purl.org/dc/elements/1.1/', field === 'title' ? 'title' : 'creator')[0]!.textContent).toBe('앞\uFFFD뒤')
  expect(file.notices).toContain('Word에서 표현할 수 없는 문자는 대체 문자로 바꿨습니다.')
})
for (const format of formats) for (const field of ['title', 'category', 'series', 'valueFormat', 'numberFormat']) {
  it(`${format} refuses an XML control character in chart ${field}`, async () => {
    const source = html((await importArtifactDocx(await independentDocx('line'))).content), figure = source.querySelector('figure')!
    if (field === 'valueFormat') figure.setAttribute('data-masc-value-format', '0\u0001%')
    else if (field === 'numberFormat') figure.querySelectorAll('th')[1]!.setAttribute('data-masc-number-format', '0\u0001%')
    else (field === 'title' ? figure.querySelector('figcaption')! : field === 'category' ? figure.querySelectorAll('tr')[1]!.cells[0]! : figure.querySelectorAll('th')[1]!).textContent = '앞\u0001뒤'
    await expect(exportFile(format, source.innerHTML)).rejects.toThrow()
  })
}
for (const format of formats) it(`${format} permits valid XML whitespace and astral metadata and chart text`, async () => {
  const source = html((await importArtifactDocx(await independentDocx('line'))).content), text = '한글\t\n\r😀'
  source.querySelector('figcaption')!.textContent = text; source.querySelectorAll('th')[1]!.textContent = text
  const doc = artifact(source.innerHTML), file = await (format === 'docx' ? artifactWordFile : artifactHwpxFile)({ ...doc, artifact: { ...doc.artifact, title: text, author: text } })
  expect(figures((await importFile(format, file.data)).content)[0]!.names[0]).toContain('😀')
})
it('refuses a real HWPX metadata part containing the formerly emitted U+0001 byte', async () => {
  const zip = await JSZip.loadAsync((await artifactHwpxFile(artifact('<p>문서</p>'))).data), path = 'Contents/content.hpf'
  zip.file(path, (await zip.file(path)!.async('string')).replace('<opf:title>', '<opf:title>\u0001'))
  expect((await zip.file(path)!.async('uint8array')).includes(1)).toBe(true)
  await expect(importArtifactHwpx(await zip.generateAsync({ type: 'uint8array' }))).rejects.toThrow()
})

let hwpxObjects: Promise<ArrayBuffer> | undefined
async function mutateHwpx(change: (xml: XmlDocument) => void): Promise<Uint8Array> {
  hwpxObjects ??= independentDocx().then(importArtifactDocx).then(result => artifactHwpxFile(artifact(result.content
      + '<p><img alt="그림" src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="></p>'))).then(file => file.data)
  const zip = await JSZip.loadAsync(await hwpxObjects), path = 'Contents/section0.xml', xml = await xmlPart(zip, path)
  change(xml); zip.file(path, serializer.serializeToString(xml)); return zip.generateAsync({ type: 'uint8array' })
}
function addCaption(xml: XmlDocument, object: string, side: string | undefined): XmlElement {
  const caption = xml.createElementNS(paragraph, 'hp:caption'); if (side !== undefined) caption.setAttribute('side', side)
  let parent = caption
  for (const tag of ['subList', 'p', 'run', 't']) { const child = xml.createElementNS(paragraph, `hp:${tag}`); parent.appendChild(child); parent = child; if (tag === 'run') child.setAttribute('charPrIDRef', '0') }
  parent.textContent = '개체 설명'; elements(xml, paragraph, object)[0]!.appendChild(caption); return caption
}
for (const object of ['tbl', 'pic', 'chart']) for (const side of ['TOP', 'BOTTOM', 'LEFT', 'RIGHT', undefined]) {
  it(`keeps ${object} caption order for ${side ?? 'default LEFT'} outside the object`, async () => {
    const result = await importArtifactHwpx(await mutateHwpx(xml => { addCaption(xml, object, side) })), source = html(result.content)
    const target = source.querySelector(object === 'tbl' ? 'table' : object === 'pic' ? 'img' : 'figure')!
    const caption = Array.from(source.querySelectorAll('p')).find(p => p.textContent === '개체 설명')!
    expect(target).not.toBeNull(); expect(caption).toBeDefined(); expect(caption.closest('figure,table')).toBeNull()
    expect(Boolean(caption.compareDocumentPosition(target) & Node.DOCUMENT_POSITION_FOLLOWING)).toBe(side === 'TOP' || side === 'LEFT' || side === undefined)
    expect(result.notices.some(notice => notice.includes('캡션'))).toBe(true)
  })
}
for (const fault of ['side', 'subList', 'paragraph', 'duplicate']) it(`refuses a malformed HWPX caption ${fault}`, async () => {
  const file = await mutateHwpx(xml => {
    const caption = addCaption(xml, 'tbl', fault === 'side' ? 'MIDDLE' : 'TOP')
    if (fault === 'subList') caption.removeChild(caption.firstChild!)
    else if (fault === 'paragraph') caption.firstChild!.removeChild(caption.firstChild!.firstChild!)
    else if (fault === 'duplicate') caption.parentNode!.appendChild(caption.cloneNode(true))
  })
  await expect(importArtifactHwpx(file)).rejects.toThrow()
})
function addAutoNumber(xml: XmlDocument, num: string | undefined): { number: XmlElement; format: XmlElement } {
  const node = new DOMParser().parseFromString(`<hp:p xmlns:hp="${paragraph}"><hp:run charPrIDRef="0"><hp:t>[그림 </hp:t><hp:ctrl><hp:autoNum numType="PICTURE"><hp:autoNumFormat type="DIGIT" prefixChar="" suffixChar=""/></hp:autoNum></hp:ctrl><hp:t>] 출처</hp:t></hp:run></hp:p>`, 'application/xml').documentElement!
  const imported = xml.importNode(node, true), number = elements(imported, paragraph, 'autoNum')[0]!, format = elements(number, paragraph, 'autoNumFormat')[0]!
  if (num !== undefined) number.setAttribute('num', num)
  xml.documentElement!.appendChild(imported); return { number, format }
}
for (const [num, expected] of [[undefined, '1'], ['+00012', '12'], ['-0', '0'], ['9007199254740993', '9007199254740993']] as const) {
  it(`displays stored HWPX automatic numbering ${num ?? 'default 1'} without numeric rounding`, async () => {
    const result = await importArtifactHwpx(await mutateHwpx(xml => { addAutoNumber(xml, num).format.removeAttribute('type') }))
    expect(Array.from(html(result.content).querySelectorAll('p')).some(p => p.textContent === `[그림 ${expected}] 출처`)).toBe(true)
    expect(result.notices).toContain('자동 번호는 저장된 숫자를 본문 글자로 옮겼습니다.')
  })
}
it('escapes automatic-number decorations and preserves their superscript display', async () => {
  const result = await importArtifactHwpx(await mutateHwpx(xml => { const { format } = addAutoNumber(xml, '1'); format.setAttribute('prefixChar', '<&'); format.setAttribute('suffixChar', '>'); format.setAttribute('supscript', 'true') }))
  const source = html(result.content); expect(source.querySelector('sup')!.textContent).toBe('<&1>'); expect(source.querySelector('script')).toBeNull()
})
for (const fault of ['type', 'numType', 'number', 'supscript', 'missing', 'duplicate']) it(`refuses an unsupported automatic-number ${fault}`, async () => {
  const file = await mutateHwpx(xml => {
    const { number, format } = addAutoNumber(xml, fault === 'number' ? '1.5' : '1')
    if (fault === 'type') format.setAttribute('type', 'ROMAN_SMALL')
    if (fault === 'numType') number.setAttribute('numType', 'UNKNOWN')
    if (fault === 'supscript') format.setAttribute('supscript', 'maybe')
    if (fault === 'missing') number.removeChild(format)
    if (fault === 'duplicate') number.appendChild(format.cloneNode(true))
  })
  await expect(importArtifactHwpx(file)).rejects.toThrow()
})
