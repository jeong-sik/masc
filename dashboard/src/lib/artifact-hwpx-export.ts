import JSZip from 'jszip'
import { XMLSerializer } from '@xmldom/xmldom'
import type { ArtifactDocument } from '../api/published-artifacts'
import { officeXmlText } from './artifact-office-text'
import { artifactWordFile } from './artifact-word-export'
import type { PreparedOfficeBlock, PreparedOfficeCell, PreparedOfficeTable } from './artifact-office-prepared'
import { loadOfficeArchive, officeNs, readOfficeBytes, readOfficeRelationships, readOfficeXml, resolveOfficePart, xmlChild, xmlChildren, xmlDescendants, type OfficeXmlElement } from './artifact-office-xml'
import { hwpxGeometry, hwpxHeader, hwpxManifest, hwpxTableLimits, maximumHwpxWidth, hwpxNs, hwpxObjectAttributes, hwpxPage, hwpxParagraph, hwpxPicture, hwpxSection, hwpxXmlDeclaration, type HwpxCharacterStyle, type HwpxManifestItem } from './artifact-hwpx-template'

const word = officeNs.word, emuPerHwpUnit = 127, hwpUnitsPerTwip = 5, hwpUnitsPerHalfPoint = 50
const wordprocessingDrawing = 'http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing'
const embeddedPackageRelation = `${officeNs.relationships}/package`
const minimumCellPadding = 150
type TableCell = { readonly node: OfficeXmlElement; readonly row: number; readonly col: number; readonly cols: number; rows: number; readonly header: boolean; readonly source: PreparedOfficeCell }
function value(node: OfficeXmlElement | undefined): string | null { return node?.getAttributeNS(word, 'val') ?? null }
function positive(value: string | null, description: string): number {
  if (!value || !/^\d+$/.test(value) || !Number.isSafeInteger(Number(value)) || Number(value) <= 0) throw new Error(`${description} 값이 올바르지 않습니다.`)
  return Number(value)
}
function tableWidth(width: number): number {
  if (!Number.isSafeInteger(width) || width < 0 || width > maximumHwpxWidth) throw new Error('표 너비가 HWPX를 읽는 변환기의 32비트 범위를 벗어납니다.')
  return width
}
function flag(node: OfficeXmlElement | undefined): boolean {
  if (!node) return false
  const val = value(node)
  if (val === null || val === '1' || val === 'true' || val === 'on') return true
  if (val === '0' || val === 'false' || val === 'off') return false
  throw new Error('Word 문자 서식 값이 올바르지 않습니다.')
}
function relationshipPath(part: string): string {
  const segments = part.split('/'), name = segments.pop()!
  return [...segments, '_rels', `${name}.rels`].join('/')
}
function relativePart(source: string, target: string): string {
  const sourceSegments = source.split('/').slice(0, -1), targetSegments = target.split('/')
  while (sourceSegments.length && targetSegments.length && sourceSegments[0] === targetSegments[0]) { sourceSegments.shift(); targetSegments.shift() }
  return [...sourceSegments.map(() => '..'), ...targetSegments].join('/')
}

/** Map the existing DOCX producer's native elements; reuse its chart XML and embedded workbook bytes. */
export async function artifactHwpxFile(doc: ArtifactDocument): Promise<{ data: ArrayBuffer; notices: readonly string[] }> {
  const file = await artifactWordFile(doc, 'hwpx'), source = await loadOfficeArchive(file.data), zip = new JSZip()
  // OCF requires the MIME entry first and uncompressed, before adding chart/image parts.
  zip.file('mimetype', 'application/hwp+zip', { compression: 'STORE' })
  const sourcePath = 'word/document.xml', document = await readOfficeXml(source, sourcePath), body = xmlChild(document.documentElement!, word, 'body')
  if (!body) throw new Error('Word 변환 결과에 본문이 없습니다.')
  const relationships = await readOfficeRelationships(source, sourcePath), notices = new Set(file.notices)
  const styles: HwpxCharacterStyle[] = [{ bold: false, italic: false, height: hwpxPage.fontHeight }]
  const manifest: HwpxManifestItem[] = [{ id: 'header', path: 'Contents/header.xml', mime: 'application/xml' }, { id: 'section0', path: 'Contents/section0.xml', mime: 'application/xml' }]
  let paragraphId = 1, objectId = 1, chartId = 0, pictureId = 0, workbookId = 0
  const paragraph = (content: string) => hwpxParagraph(content, paragraphId++)
  const listCounters = new Map<string, number>()
  const numbering = source.file('word/numbering.xml') ? await readOfficeXml(source, 'word/numbering.xml') : null

  function characterStyle(node: OfficeXmlElement): number {
    const properties = xmlChild(node, word, 'rPr'), size = properties && value(xmlChild(properties, word, 'sz'))
    const style: HwpxCharacterStyle = { bold: !!properties && flag(xmlChild(properties, word, 'b')), italic: !!properties && flag(xmlChild(properties, word, 'i')),
      height: size ? positive(size, '글자 크기') * hwpUnitsPerHalfPoint : hwpxPage.fontHeight }
    const previous = styles.findIndex(item => item.bold === style.bold && item.italic === style.italic && item.height === style.height)
    if (previous !== -1) return previous
    styles.push(style); return styles.length - 1
  }
  function listLabel(node: OfficeXmlElement): string {
    const properties = xmlChild(node, word, 'pPr'), number = properties && xmlChild(properties, word, 'numPr')
    if (!number) return ''
    if (!numbering) throw new Error('Word 목록의 번호 정의가 없습니다.')
    const id = value(xmlChild(number, word, 'numId')), level = value(xmlChild(number, word, 'ilvl')) ?? '0'
    const num = xmlDescendants(numbering, word, 'num').find(item => item.getAttributeNS(word, 'numId') === id)
    const abstractId = num && value(xmlChild(num, word, 'abstractNumId'))
    const abstract = xmlDescendants(numbering, word, 'abstractNum').find(item => item.getAttributeNS(word, 'abstractNumId') === abstractId)
    const definition = abstract && xmlChildren(abstract, word, 'lvl').find(item => item.getAttributeNS(word, 'ilvl') === level)
    if (!definition) throw new Error('Word 목록의 항목 번호를 확인할 수 없습니다.')
    const format = value(xmlChild(definition, word, 'numFmt')), label = value(xmlChild(definition, word, 'lvlText'))
    if (format === 'bullet') return `${label ?? '•'} `
    if (format !== 'decimal') throw new Error('지원하지 않는 Word 목록 번호 형식입니다.')
    const override = num && xmlChildren(num, word, 'lvlOverride').find(item => item.getAttributeNS(word, 'ilvl') === level)
    const first = (override && value(xmlChild(override, word, 'startOverride'))) ?? value(xmlChild(definition, word, 'start')) ?? '1'
    if (!/^[+-]?\d+$/.test(first) || !Number.isSafeInteger(Number(first))) throw new Error('Word 목록의 시작 번호가 올바르지 않습니다.')
    const key = `${id}:${level}`, current = listCounters.get(key) ?? Number(first)
    listCounters.set(key, current + 1)
    notices.add('목록 번호와 글머리표는 본문 글자로 옮겼습니다.')
    return `${current}. `
  }
  async function drawing(node: OfficeXmlElement): Promise<string> {
    const charts = xmlDescendants(node, officeNs.chart, 'chart'), blips = xmlDescendants(node, officeNs.drawing, 'blip')
    const extent = xmlDescendants(node, wordprocessingDrawing, 'extent')[0]
    if (!extent) throw new Error('문서 개체의 크기가 없습니다.')
    const width = Math.round(positive(extent.getAttribute('cx'), '개체 너비') / emuPerHwpUnit), height = Math.round(positive(extent.getAttribute('cy'), '개체 높이') / emuPerHwpUnit)
    if (width <= 0 || height <= 0) throw new Error('문서 개체의 크기가 너무 작습니다.')
    if (charts.length === 1 && blips.length === 0) {
      const id = charts[0]!.getAttributeNS(officeNs.relationships, 'id'), relation = id && relationships.get(id)
      if (!relation || relation.external || relation.type !== `${officeNs.relationships}/chart`) throw new Error('차트 파일의 내부 참조가 올바르지 않습니다.')
      const chartPath = resolveOfficePart(sourcePath, relation.target), destination = `Chart/chart${++chartId}.xml`
      const chart = await readOfficeXml(source, chartPath), chartRelations = await readOfficeRelationships(source, chartPath)
      const mapped: { id: string; target: string; type: string }[] = []
      for (const relationship of chartRelations.values()) {
        if (relationship.external || relationship.type !== embeddedPackageRelation) throw new Error('지원하지 않는 차트 내부 파일 참조입니다.')
        const target = resolveOfficePart(chartPath, relationship.target), path = `BinData/workbook${++workbookId}.xlsx`
        zip.file(path, await readOfficeBytes(source, target))
        manifest.push({ id: `workbook${workbookId}`, path, mime: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' })
        mapped.push({ id: relationship.id, target: relativePart(destination, path), type: relationship.type })
      }
      zip.file(destination, new XMLSerializer().serializeToString(chart))
      if (mapped.length) zip.file(relationshipPath(destination), `${hwpxXmlDeclaration}<Relationships xmlns="${officeNs.packageRelationships}">${mapped.map(item => `<Relationship Id="${officeXmlText(item.id)}" Type="${officeXmlText(item.type)}" Target="${officeXmlText(item.target)}"/>`).join('')}</Relationships>`)
      return `<hp:chart ${hwpxObjectAttributes(objectId++)} chartIDRef="${destination}">${hwpxGeometry(width, height)}</hp:chart>`
    }
    if (blips.length === 1 && charts.length === 0) {
      const id = blips[0]!.getAttributeNS(officeNs.relationships, 'embed'), relation = id && relationships.get(id)
      if (!relation || relation.external || relation.type !== `${officeNs.relationships}/image`) throw new Error('그림 파일의 내부 참조가 올바르지 않습니다.')
      const path = resolveOfficePart(sourcePath, relation.target), extension = path.split('.').at(-1)?.toLowerCase()
      if (extension !== 'png' && extension !== 'jpg' && extension !== 'jpeg' && extension !== 'bmp') throw new Error('PNG·JPEG·BMP 그림만 HWPX로 내보낼 수 있습니다.')
      const reference = `image${++pictureId}`, destination = `BinData/${reference}.${extension}`
      zip.file(destination, await readOfficeBytes(source, path)); manifest.push({ id: reference, path: destination, mime: extension === 'png' ? 'image/png' : extension === 'bmp' ? 'image/bmp' : 'image/jpeg' })
      const description = xmlDescendants(node, wordprocessingDrawing, 'docPr')[0]?.getAttribute('descr') ?? ''
      return hwpxPicture(objectId++, reference, width, height, description)
    }
    throw new Error('지원하지 않는 문서 그림 또는 차트 구조입니다.')
  }
  async function runs(owner: OfficeXmlElement): Promise<string> {
    const output: string[] = []
    for (const node of xmlChildren(owner)) {
      if (node.namespaceURI !== word) throw new Error('Word 변환 결과에 알 수 없는 본문 요소가 있습니다.')
      switch (node.localName) {
        case 'r': output.push(`<hp:run charPrIDRef="${characterStyle(node)}">${await runs(node)}</hp:run>`); break
        case 't': output.push(`<hp:t>${officeXmlText(node.textContent ?? '')}</hp:t>`); break
        case 'br': case 'cr': output.push('<hp:t><hp:lineBreak/></hp:t>'); break
        case 'tab': output.push('<hp:t>\t</hp:t>'); break
        case 'drawing': output.push(await drawing(node)); break
        case 'hyperlink': notices.add('링크의 표시 글자를 본문으로 옮겼습니다.'); output.push(await runs(node)); break
        case 'pPr': case 'rPr': case 'bookmarkStart': case 'bookmarkEnd': break
        default: throw new Error(`지원하지 않는 Word 변환 요소입니다: ${node.localName}`)
      }
    }
    return output.join('')
  }
  async function table(node: OfficeXmlElement, prepared: PreparedOfficeTable): Promise<string> {
    const grid = xmlChild(node, word, 'tblGrid'), rows = xmlChildren(node, word, 'tr')
    if (!grid || !rows.length) throw new Error('Word 표의 격자가 없습니다.')
    const widths = xmlChildren(grid, word, 'gridCol').map(item => positive(item.getAttributeNS(word, 'w'), '표 열 너비') * hwpUnitsPerTwip)
    if (!widths.length) throw new Error('Word 표의 열이 없습니다.')
    if (widths.length > hwpxTableLimits.columns || rows.length > hwpxTableLimits.rows) throw new Error('표의 행 또는 열 수를 HWPX와 HTML 양쪽에 옮길 수 없습니다.')
    if (prepared.columns !== widths.length || prepared.rows.length !== rows.length) throw new Error('생성한 표의 격자가 원본 너비 구조와 다릅니다.')
    const cells: TableCell[] = []
    const cellsByRow: TableCell[][] = []
    let active = new Map<number, TableCell>()
    for (const [rowIndex, row] of rows.entries()) {
      let col = 0
      const owned: TableCell[] = []
      cellsByRow.push(owned)
      const nextActive = new Map<number, TableCell>(), rowProperties = xmlChild(row, word, 'trPr'), header = !!rowProperties && flag(xmlChild(rowProperties, word, 'tblHeader'))
      for (const cell of xmlChildren(row, word, 'tc')) {
        const properties = xmlChild(cell, word, 'tcPr'), span = properties && xmlChild(properties, word, 'gridSpan'), merge = properties && xmlChild(properties, word, 'vMerge')
        const cols = span ? positive(value(span), '표 열 병합') : 1
        if (col + cols > widths.length) throw new Error('Word 표의 병합 셀이 격자를 벗어납니다.')
        if (merge && value(merge) !== 'restart') {
          const previous = active.get(col)
          if (!previous || previous.cols !== cols || (value(merge) !== null && value(merge) !== 'continue')) throw new Error('Word 표의 세로 병합이 이어지지 않습니다.')
          previous.rows++; nextActive.set(col, previous)
        } else {
          const source = prepared.rows[rowIndex]![owned.length]
          if (!source || source.column !== col || source.columns !== cols) throw new Error('생성한 표 셀의 위치가 원본 너비 구조와 다릅니다.')
          const item = { node: cell, row: rowIndex, col, cols, rows: 1, header, source }
          owned.push(item)
          cells.push(item); if (merge) nextActive.set(col, item)
        }
        col += cols
      }
      if (col !== widths.length) throw new Error('Word 표의 행 너비가 격자와 다릅니다.')
      if (owned.length !== prepared.rows[rowIndex]!.length) throw new Error('생성한 표의 셀 수가 원본 너비 구조와 다릅니다.')
      active = nextActive
    }
    const rowXml: string[] = []
    for (const owned of cellsByRow) {
      const cellXml: string[] = []
      for (const cell of owned) {
        if (cell.rows !== cell.source.rows) throw new Error('생성한 표의 세로 병합이 원본 너비 구조와 다릅니다.')
        const width = tableWidth(cell.source.width ?? widths.slice(cell.col, cell.col + cell.cols).reduce((sum, value) => sum + value, 0)), height = cell.rows * hwpxPage.cellHeight
        cellXml.push(`<hp:tc name="" header="${cell.header ? '1' : '0'}" hasMargin="1" protect="0" editable="1" dirty="0" borderFillIDRef="2"><hp:subList id="" textDirection="HORIZONTAL" lineWrap="BREAK" vertAlign="TOP" linkListIDRef="0" linkListNextIDRef="0" textWidth="0" textHeight="0" hasTextRef="0" hasNumRef="0">${await blocks(cell.node, cell.source.children) || paragraph('')}</hp:subList><hp:cellAddr colAddr="${cell.col}" rowAddr="${cell.row}"/><hp:cellSpan colSpan="${cell.cols}" rowSpan="${cell.rows}"/><hp:cellSz width="${width}" height="${height}"/><hp:cellMargin left="${minimumCellPadding}" right="${minimumCellPadding}" top="${minimumCellPadding}" bottom="${minimumCellPadding}"/></hp:tc>`)
      }
      rowXml.push(`<hp:tr>${cellXml.join('')}</hp:tr>`)
    }
    const width = tableWidth(prepared.width ?? widths.reduce((sum, item) => sum + item, 0)), height = rows.length * hwpxPage.cellHeight
    const contents = `<hp:tbl ${hwpxObjectAttributes(objectId++)} pageBreak="CELL" repeatHeader="${cells.some(cell => cell.row === 0 && cell.header) ? '1' : '0'}" rowCnt="${rows.length}" colCnt="${widths.length}" cellSpacing="0" borderFillIDRef="2" noAdjust="0">${hwpxGeometry(width, height)}<hp:inMargin left="${minimumCellPadding}" right="${minimumCellPadding}" top="${minimumCellPadding}" bottom="${minimumCellPadding}"/>${rowXml.join('')}</hp:tbl>`
    return paragraph(`<hp:run charPrIDRef="0">${contents}</hp:run>`)
  }
  async function blocks(owner: OfficeXmlElement, prepared: readonly PreparedOfficeBlock[]): Promise<string> {
    const output: string[] = []
    let index = 0
    for (const child of xmlChildren(owner)) {
      if (child.namespaceURI !== word) throw new Error('Word 변환 결과에 알 수 없는 본문 요소가 있습니다.')
      if (child.localName === 'sectPr' || child.localName === 'tcPr') continue
      const block = prepared[index++]
      if (!block) throw new Error('생성한 문서의 블록 수가 원본 구조와 다릅니다.')
      switch (child.localName) {
        case 'p': {
          if (block.kind !== 'paragraph') throw new Error('생성한 문단이 원본 구조와 다릅니다.')
          const label = listLabel(child), content = await runs(child)
          output.push(paragraph(`${label ? `<hp:run charPrIDRef="0"><hp:t>${officeXmlText(label)}</hp:t></hp:run>` : ''}${content}`)); break
        }
        case 'tbl': {
          if (block.kind !== 'table') throw new Error('생성한 표가 원본 구조와 다릅니다.')
          output.push(await table(child, block)); break
        }
        default: throw new Error(`지원하지 않는 Word 본문 요소입니다: ${child.localName}`)
      }
    }
    if (index !== prepared.length) throw new Error('생성한 문서의 블록 수가 원본 구조와 다릅니다.')
    return output.join('')
  }
  const content = await blocks(body, file.blocks)
  zip.file('META-INF/container.xml', `${hwpxXmlDeclaration}<ocf:container xmlns:ocf="${hwpxNs.container}"><ocf:rootfiles><ocf:rootfile full-path="Contents/content.hpf" media-type="application/hwpml-package+xml"/></ocf:rootfiles></ocf:container>`)
  zip.file('version.xml', `${hwpxXmlDeclaration}<hv:HCFVersion xmlns:hv="http://www.hancom.co.kr/hwpml/2011/version" tagetApplication="WORDPROCESSOR" major="5" minor="1" micro="1" buildNumber="0" os="0" xmlVersion="1.5" application="MASC" appVersion="1.0"/>`)
  zip.file('Contents/header.xml', hwpxHeader(styles)); zip.file('Contents/section0.xml', hwpxSection(content))
  zip.file('Contents/content.hpf', hwpxManifest(manifest, doc.artifact.title, doc.artifact.author))
  notices.add('HWPX는 A4와 기본 글꼴로 다시 배치합니다. 원본의 페이지·링크·일부 서식은 다를 수 있습니다.')
  return { data: await zip.generateAsync({ type: 'arraybuffer', compression: 'DEFLATE' }), notices: [...notices] }
}
