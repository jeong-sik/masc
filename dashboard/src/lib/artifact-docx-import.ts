import { fromByteArray } from 'base64-js'
import { officeImageDimensions } from './artifact-office-image'
import { officeChartFigure } from './artifact-office-chart'
import { officeHtmlText } from './artifact-office-text'
import { readOfficeChart } from './artifact-office-chart-read'
import { officeTableFixedLayout, officeTableHtmlStyle, officeTableWidthStyle, parseOfficeTableWidth, type OfficeTableWidth, type OfficeTableWidthCell } from './artifact-office-table-width'
import { loadOfficeArchive, officeNs as ns, readOfficeBytes, readOfficeRelationships, readOfficeXml, resolveOfficePart,
  xmlChild, xmlChildren, xmlDescendants, type OfficeXmlElement as Element } from './artifact-office-xml'

type Segment = { readonly kind: 'inline' | 'block'; readonly html: string }
type Cell = { readonly start: number; span: number; rowSpan: number; readonly html: string; readonly header: boolean; readonly width: OfficeTableWidth }
const wordDrawing = 'http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing'
const extendedChart = 'http://schemas.microsoft.com/office/drawing/2014/chartex'
const htmlMaxColspan = 1000, htmlMaxRowspan = 65534
const relationshipType = (name: string) => `${ns.relationships}/${name}`
function wordValue(node: Element): string | null { return node.getAttributeNS(ns.word, 'val') }
function integer(value: string | null, allowZero = false): number {
  if (value === null || !/^\d+$/.test(value) || !Number.isSafeInteger(Number(value)) || Number(value) < (allowZero ? 0 : 1)) throw new Error('Word 표 또는 목록의 숫자 속성이 올바르지 않습니다.')
  return Number(value)
}
function propertyNumber(node: Element | undefined, name: string, absent: number, allowZero = false): number {
  const property = node && xmlChild(node, ns.word, name)
  return property ? integer(wordValue(property), allowZero) : absent
}
function tableWidth(node: Element | undefined, grid = false): OfficeTableWidth {
  if (!node) return { kind: 'absent' }
  const stored = node.getAttributeNS(ns.word, 'w')
  if (grid && stored === null) return { kind: 'absent' }
  // OOXML defines an omitted w:w as zero, rather than an invalid measurement.
  const value = stored ?? '0'
  switch (grid ? 'dxa' : node.getAttributeNS(ns.word, 'type') ?? 'dxa') {
    case 'auto': return { kind: 'auto' }
    case 'nil': return { kind: 'auto' }
    case 'pct': {
      if (value?.endsWith('%')) {
        const width = parseOfficeTableWidth(`width:${value}`)
        if (width.kind !== 'percent') throw new Error('지원하지 않는 Word 표의 백분율 너비입니다.')
        return width
      }
      return { kind: 'percent', value: integer(value, true) / 50 }
    }
    case 'dxa': {
      if (value !== null && !/^\d+$/.test(value)) return parseOfficeTableWidth(`width:${value}`)
      const hwpUnits = integer(value, true) * 5
      if (!Number.isSafeInteger(hwpUnits)) throw new Error('Word 표 너비를 정확히 표현할 수 없습니다.')
      // A zero default grid track supplies no positive layout measurement.
      // Keep it automatic rather than claiming a fixed zero-width column.
      if (grid && hwpUnits === 0) return { kind: 'auto' }
      return { kind: 'absolute', hwpUnits }
    }
    default: throw new Error('지원하지 않는 Word 표의 너비 형식입니다.')
  }
}
function tableStyle(width: OfficeTableWidth): string {
  const css = officeTableWidthStyle(width)
  return css ? ` style="${officeHtmlText(css)}"` : ''
}
function enabled(node: Element | undefined): boolean {
  if (!node) return false
  switch (wordValue(node)) {
    case null: case '': case '1': case 'true': case 'on': return true
    case '0': case 'false': case 'off': return false
    default: throw new Error('Word 서식의 참·거짓 속성이 올바르지 않습니다.')
  }
}
function rejectUntranslatedChart(node: Element): void {
  if ((node.namespaceURI === ns.chart && node.localName === 'chart') || node.namespaceURI === extendedChart
    || xmlDescendants(node, ns.chart, 'chart').length || xmlDescendants(node, extendedChart, '*').length) {
    throw new Error('지원하지 않는 Word 개체 안에 차트가 있어 가져올 수 없습니다.')
  }
}
function tableEntries(node: Element, name: 'tr' | 'tc', metadata: readonly string[]): Element[] {
  const entries: Element[] = []
  for (const child of xmlChildren(node)) {
    if (child.namespaceURI !== ns.word || child.localName === null) throw new Error('지원하지 않는 Word 표 구조입니다.')
    if (child.localName === name) { entries.push(child); continue }
    switch (child.localName) {
      case 'sdt': {
        if (xmlChildren(child).some(entry => entry.namespaceURI !== ns.word || !['sdtPr', 'sdtEndPr', 'sdtContent'].includes(entry.localName ?? ''))) throw new Error('Word 표의 콘텐츠 컨트롤 구조를 읽을 수 없습니다.')
        const content = xmlChild(child, ns.word, 'sdtContent')
        if (!content) throw new Error('Word 표의 콘텐츠 컨트롤 본문이 없습니다.')
        entries.push(...tableEntries(content, name, metadata)); break
      }
      case 'sdtContent': case 'ins': entries.push(...tableEntries(child, name, metadata)); break
      case 'customXml': entries.push(...tableEntries(child, name, [...metadata, 'customXmlPr'])); break
      default: if (!metadata.includes(child.localName)) throw new Error(`지원하지 않는 Word 표 구조입니다: ${child.localName}`)
    }
  }
  return entries
}

export async function importArtifactDocx(data: ArrayBuffer | Uint8Array): Promise<{ content: string; notices: readonly string[] }> {
  const zip = await loadOfficeArchive(data), roots = [...(await readOfficeRelationships(zip, '')).values()].filter(relation => relation.type === relationshipType('officeDocument'))
  if (roots.length !== 1 || roots[0]!.external) throw new Error('DOCX 본문 파일을 확인할 수 없습니다.')
  const path = resolveOfficePart('', roots[0]!.target), document = await readOfficeXml(zip, path), root = document.documentElement!
  if (root.namespaceURI !== ns.word || root.localName !== 'document') throw new Error('표준 DOCX 문서가 아닙니다.')
  const bodies = xmlChildren(root, ns.word, 'body')
  if (bodies.length !== 1) throw new Error('DOCX 본문이 없거나 겹칩니다.')
  const relationships = await readOfficeRelationships(zip, path), notices = new Set<string>(['본문·표·차트를 가져왔습니다. 원본의 페이지 배치·글꼴·도형 서식은 그대로 옮기지 않습니다.'])
  if ([...relationships.values()].some(relation => relation.type === relationshipType('header') || relation.type === relationshipType('footer'))) notices.add('머리글·바닥글은 가져오지 않았습니다. 원본 파일에서 내용을 확인해 주세요.')
  if ([...relationships.values()].some(relation => relation.type === relationshipType('comments'))) notices.add('Word 검토 메모는 가져오지 않았습니다.')
  const listNumbers = new Map<string, number>()
  const numberingRelation = [...relationships.values()].find(relation => relation.type === relationshipType('numbering'))
  if (numberingRelation?.external) throw new Error('외부 목록 정의를 읽을 수 없습니다.')
  const numbering = numberingRelation ? await readOfficeXml(zip, resolveOfficePart(path, numberingRelation.target)) : undefined
  const inline = (html: string): Segment => ({ kind: 'inline', html })

  async function drawing(node: Element): Promise<Segment[]> {
    const charts = xmlDescendants(node, ns.chart, 'chart'), graphics = xmlDescendants(node, ns.drawing, 'graphicData')
    if (graphics.some(graphic => graphic.getAttribute('uri') === extendedChart)) throw new Error('확장 형식의 차트는 가져올 수 없습니다.')
    if (charts.length > 1) throw new Error('한 그림 안에 여러 차트가 있어 가져올 수 없습니다.')
    if (charts[0]) {
      const relation = relationships.get(charts[0].getAttributeNS(ns.relationships, 'id') ?? '')
      if (!relation || relation.external || relation.type !== relationshipType('chart')) throw new Error('차트 원본 파일의 내부 참조를 확인할 수 없습니다.')
      return [{ kind: 'block', html: officeChartFigure(await readOfficeChart(zip, resolveOfficePart(path, relation.target))) }]
    }
    if (graphics.some(graphic => graphic.getAttribute('uri') === ns.chart)) throw new Error('차트 파일 참조가 없습니다.')
    const image = xmlDescendants(node, ns.drawing, 'blip'), description = xmlDescendants(node, wordDrawing, 'docPr')[0]
    const alt = description?.getAttribute('descr') || description?.getAttribute('title') || '그림'
    if (image.length === 1) {
      const relation = relationships.get(image[0]!.getAttributeNS(ns.relationships, 'embed') ?? '')
      if (relation && !relation.external && relation.type === relationshipType('image')) {
        const bytes = await readOfficeBytes(zip, resolveOfficePart(path, relation.target)), size = officeImageDimensions(bytes)
        if (size) return [inline(`<img src="data:image/${size.type};base64,${fromByteArray(bytes)}" alt="${officeHtmlText(alt)}">`)]
      }
      notices.add('외부 그림과 PNG·JPEG·BMP 이외의 그림은 설명으로 옮겼습니다.')
    } else notices.add('도형의 배치는 옮기지 않고 도형 안의 글자와 설명만 옮겼습니다.')
    const boxes = xmlDescendants(node, ns.word, 'txbxContent')
    if (boxes.length) return [{ kind: 'block', html: (await Promise.all(boxes.map(box => blocks(box)))).join('') }]
    return [inline(`[그림: ${officeHtmlText(alt)}]`)]
  }
  async function runs(node: Element): Promise<Segment[]> {
    const output: Segment[] = []
    for (const child of xmlChildren(node)) {
      if (child.namespaceURI !== ns.word) { rejectUntranslatedChart(child); notices.add('Word 본문에서 지원하지 않는 개체는 옮기지 않았습니다.'); continue }
      switch (child.localName) {
        case 't': output.push(inline(officeHtmlText(child.textContent ?? ''))); break
        case 'br': case 'cr': output.push(inline('<br>')); break
        case 'tab': output.push(inline('&#9;')); break
        case 'drawing': case 'pict': output.push(...await drawing(child)); break
        case 'object': throw new Error('OLE 개체가 포함된 Word 문서는 가져올 수 없습니다.')
        case 'r': {
          const properties = xmlChild(child, ns.word, 'rPr'), wrappers: string[] = []
          for (const [property, tag] of [['b', 'strong'], ['i', 'em'], ['strike', 's']] as const) if (properties && enabled(xmlChild(properties, ns.word, property))) wrappers.push(tag)
          const underline = properties && xmlChild(properties, ns.word, 'u')
          if (underline && wordValue(underline) !== 'none') wrappers.push('u')
          const alignment = properties && xmlChild(properties, ns.word, 'vertAlign')
          if (alignment && wordValue(alignment) === 'superscript') wrappers.push('sup')
          if (alignment && wordValue(alignment) === 'subscript') wrappers.push('sub')
          for (const segment of await runs(child)) output.push(segment.kind === 'block' ? segment : inline(wrappers.reduce((text, tag) => `<${tag}>${text}</${tag}>`, segment.html)))
          break
        }
        case 'hyperlink': {
          const segments = await runs(child), relation = relationships.get(child.getAttributeNS(ns.relationships, 'id') ?? '')
          let href: string | undefined
          if (relation?.type === relationshipType('hyperlink') && relation.external) {
            try { const url = new URL(relation.target); if (['http:', 'https:', 'mailto:', 'tel:'].includes(url.protocol)) href = url.href } catch { /* Invalid links remain text. */ }
          }
          if (!href) notices.add('읽을 수 없는 링크와 문서 내부 링크는 글자로 옮겼습니다.')
          output.push(...segments.map(segment => href && segment.kind === 'inline' ? inline(`<a href="${officeHtmlText(href)}">${segment.html}</a>`) : segment)); break
        }
        case 'ins': case 'moveTo': case 'sdt': case 'sdtContent': case 'smartTag': case 'customXml': case 'fldSimple': output.push(...await runs(child)); break
        case 'del': case 'moveFrom': notices.add('변경 추적은 삭제된 내용을 제외한 현재 본문으로 옮겼습니다.'); break
        case 'footnoteReference': case 'endnoteReference':
          notices.add('각주·미주는 번호만 옮겼습니다. 원본 파일에서 각주·미주 내용을 확인해 주세요.')
          output.push(inline(`<sup>[${child.localName === 'footnoteReference' ? '각주' : '미주'} ${officeHtmlText(child.getAttributeNS(ns.word, 'id') ?? '')}]</sup>`)); break
        case 'rPr': case 'pPr': case 'sdtPr': case 'bookmarkStart': case 'bookmarkEnd': case 'commentRangeStart': case 'commentRangeEnd': case 'commentReference': case 'proofErr': case 'lastRenderedPageBreak': break
        case 'instrText': case 'fldChar': notices.add('Word 필드는 저장된 표시 내용으로 옮겼습니다.'); break
        default: rejectUntranslatedChart(child); notices.add('Word 본문에서 지원하지 않는 개체는 옮기지 않았습니다.'); break
      }
    }
    return output
  }
  function list(node: Element, body: string): string {
    const num = xmlChild(xmlChild(node, ns.word, 'pPr') ?? node, ns.word, 'numPr')
    if (!num) return body
    if (!numbering) throw new Error('Word 목록의 번호 정의가 없습니다.')
    const id = wordValue(xmlChild(num, ns.word, 'numId') ?? num), level = propertyNumber(num, 'ilvl', 0, true)
    const definition = xmlDescendants(numbering, ns.word, 'num').find(entry => entry.getAttributeNS(ns.word, 'numId') === id)
    const abstractId = definition && xmlChild(definition, ns.word, 'abstractNumId')
    const abstract = abstractId && xmlDescendants(numbering, ns.word, 'abstractNum').find(entry => entry.getAttributeNS(ns.word, 'abstractNumId') === wordValue(abstractId))
    const override = definition && xmlChildren(definition, ns.word, 'lvlOverride').find(entry => entry.getAttributeNS(ns.word, 'ilvl') === String(level))
    const settings = (override && xmlChild(override, ns.word, 'lvl')) ?? (abstract && xmlChildren(abstract, ns.word, 'lvl').find(entry => entry.getAttributeNS(ns.word, 'ilvl') === String(level)))
    const format = settings && xmlChild(settings, ns.word, 'numFmt'), formatName = format && wordValue(format)
    if (formatName !== 'bullet' && formatName !== 'decimal') throw new Error('지원하지 않는 Word 목록 번호 형식입니다.')
    if (level > 0) notices.add('중첩 목록은 항목 순서를 유지한 개별 목록으로 옮겼습니다.')
    if (formatName === 'bullet') return `<ul><li>${body}</li></ul>`
    const key = `${id}:${level}`, start = listNumbers.get(key) ?? propertyNumber(override, 'startOverride', propertyNumber(settings, 'start', 1))
    listNumbers.set(key, start + 1)
    return `<ol start="${start}"><li>${body}</li></ol>`
  }
  async function paragraph(node: Element): Promise<string> {
    const style = xmlChild(xmlChild(node, ns.word, 'pPr') ?? node, ns.word, 'pStyle')
    const headings: Record<string, string> = { Heading1: 'h1', Heading2: 'h2', Heading3: 'h3', Heading4: 'h4', Heading5: 'h5', Heading6: 'h6' }
    const name = style && wordValue(style), tag = name && Object.hasOwn(headings, name) ? headings[name]! : 'p'
    const output: string[] = []
    let pending = ''
    const flush = () => { if (pending) { output.push(`<${tag}>${pending}</${tag}>`); pending = '' } }
    for (const segment of await runs(node)) { if (segment.kind === 'inline') pending += segment.html; else { flush(); output.push(segment.html) } }
    flush()
    return list(node, output.length ? output.join('') : '<p></p>')
  }
  async function table(node: Element): Promise<string> {
    const rows = tableEntries(node, 'tr', ['tblPr', 'tblGrid']), output: Cell[][] = [], sources: OfficeTableWidthCell[] = []
    const grid = xmlChild(node, ns.word, 'tblGrid'), properties = xmlChild(node, ns.word, 'tblPr')
    const preferred = tableWidth(properties && xmlChild(properties, ns.word, 'tblW'))
    const columns = grid ? xmlChildren(grid, ns.word, 'gridCol').map(column => tableWidth(column, true)) : []
    if (rows.length === 0) throw new Error('가져올 수 있는 Word 표 행이 없습니다.')
    let active = new Map<number, Cell>(), width = columns.length
    for (const row of rows) {
      const rowProperties = xmlChild(row, ns.word, 'trPr'), cells: Cell[] = [], next = new Map<number, Cell>()
      let column = propertyNumber(rowProperties, 'gridBefore', 0, true)
      const rowCells = tableEntries(row, 'tc', ['trPr', 'tblPrEx'])
      if (rowCells.length === 0) throw new Error('가져올 수 있는 Word 표 셀이 없습니다.')
      for (const element of rowCells) {
        const properties = xmlChild(element, ns.word, 'tcPr'), span = propertyNumber(properties, 'gridSpan', 1)
        if (span > htmlMaxColspan || !Number.isSafeInteger(column + span)) throw new Error('HTML로 보존할 수 없는 Word 표 열 병합입니다.')
        const cellWidth = tableWidth(properties && xmlChild(properties, ns.word, 'tcW'))
        sources.push({ column, columns: span, width: cellWidth })
        if (properties && xmlChild(properties, ns.word, 'hMerge')) throw new Error('이전 방식의 Word 가로 병합은 가져올 수 없습니다.')
        const merge = properties && xmlChild(properties, ns.word, 'vMerge'), mode = merge && wordValue(merge)
        if (merge && mode !== null && mode !== '' && mode !== 'restart' && mode !== 'continue') throw new Error('Word 표의 세로 병합 상태를 읽을 수 없습니다.')
        if (merge && mode !== 'restart') {
          const previous = active.get(column)
          if (!previous || previous.span !== span || previous.rowSpan >= htmlMaxRowspan) throw new Error('Word 표의 세로 병합이 앞 행과 맞지 않습니다.')
          if (xmlDescendants(element, ns.word, 't').some(text => text.textContent?.trim()) || xmlDescendants(element, ns.word, 'drawing').length) throw new Error('Word 표의 병합된 숨김 셀에 내용이 있습니다.')
          previous.rowSpan++; next.set(column, previous)
        } else {
          const cell: Cell = { start: column, span, rowSpan: 1, html: await blocks(element), width: cellWidth, header: enabled(rowProperties && xmlChild(rowProperties, ns.word, 'tblHeader')) }
          cells.push(cell); if (merge) next.set(column, cell)
        }
        column += span
      }
      width = Math.max(width, column + propertyNumber(rowProperties, 'gridAfter', 0, true)); active = next; output.push(cells)
    }
    const merged = new Map<number, { readonly end: number; readonly until: number }>()
    const body = output.map((cells, row) => {
      for (const [start, range] of merged) if (range.until <= row) merged.delete(start)
      const intervals = [...cells.map(cell => ({ start: cell.start, end: cell.start + cell.span, cell })), ...Array.from(merged, ([start, range]) => ({ start, end: range.end, cell: null }))]
        .sort((a, b) => a.start - b.start)
      let column = 0, html = ''
      const gap = (span: number) => { if (span > htmlMaxColspan) throw new Error('HTML로 보존할 수 없는 Word 표의 빈 열 범위입니다.'); return `<td${span > 1 ? ` colspan="${span}"` : ''}></td>` }
      for (const interval of intervals) {
        if (interval.start < column) throw new Error('Word 표의 병합 셀이 겹칩니다.')
        if (interval.start > column) html += gap(interval.start - column)
        const cell = interval.cell
        if (cell) {
          const tag = cell.header ? 'th' : 'td'
          html += `<${tag}${cell.span > 1 ? ` colspan="${cell.span}"` : ''}${cell.rowSpan > 1 ? ` rowspan="${cell.rowSpan}"` : ''}${tableStyle(cell.width)}>${cell.html}</${tag}>`
          if (cell.rowSpan > 1) merged.set(cell.start, { end: cell.start + cell.span, until: row + cell.rowSpan })
        }
        column = interval.end
      }
      if (column < width) html += gap(width - column)
      return `<tr>${html}</tr>`
    }).join('')
    const fixedLayout = officeTableFixedLayout(width, sources, { table: preferred, columns })
    const css = officeTableHtmlStyle(preferred, fixedLayout)
    const hints: readonly OfficeTableWidth[] = fixedLayout ? fixedLayout.widths.map(hwpUnits => ({ kind: 'absolute', hwpUnits })) : columns
    return `<table${css ? ` style="${officeHtmlText(css)}"` : ''}>${hints.length ? `<colgroup>${hints.map(width => `<col${tableStyle(width)}>`).join('')}</colgroup>` : ''}<tbody>${body}</tbody></table>`
  }
  async function blocks(node: Element): Promise<string> {
    const output: string[] = []
    for (const child of xmlChildren(node)) {
      if (child.namespaceURI !== ns.word) { rejectUntranslatedChart(child); notices.add('Word 본문에서 지원하지 않는 개체는 옮기지 않았습니다.'); continue }
      switch (child.localName) {
        case 'p': output.push(await paragraph(child)); break
        case 'tbl': output.push(await table(child)); break
        case 'sdt': case 'sdtContent': case 'customXml': case 'ins': output.push(await blocks(child)); break
        case 'del': notices.add('변경 추적은 삭제된 내용을 제외한 현재 본문으로 옮겼습니다.'); break
        case 'sectPr': case 'tcPr': case 'sdtPr': case 'bookmarkStart': case 'bookmarkEnd': case 'proofErr': break
        default: throw new Error(`지원하지 않는 Word 본문 구조입니다: ${child.localName}`)
      }
    }
    return output.join('')
  }
  const content = await blocks(bodies[0]!)
  if (!content) throw new Error('가져올 수 있는 Word 본문이 없습니다.')
  return { content, notices: [...notices] }
}
