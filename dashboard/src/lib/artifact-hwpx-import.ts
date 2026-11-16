import { officeChartFigure, type OfficeChart } from './artifact-office-chart'
import { officeHtmlText } from './artifact-office-text'
import { readOfficeChart } from './artifact-office-chart-read'
import { fromByteArray } from 'base64-js'
import { officeImageDimensions } from './artifact-office-image'
import { checkOfficeTableGrid, type OfficeTableCellBounds } from './artifact-office-table-grid'
import { loadOfficeArchive, readOfficeBytes, readOfficeXml, resolveOfficePart, xmlChild, xmlChildren, xmlDescendants, type OfficeXmlElement } from './artifact-office-xml'
import { hwpUnitsPerCssPixel, hwpxTableLimits, hwpxNs } from './artifact-hwpx-template'

type Fragment = { readonly kind: 'inline' | 'block'; readonly content: string }
type ManifestItem = { readonly path: string; readonly mime: string }
type Cell = OfficeTableCellBounds & { readonly element: OfficeXmlElement }
export type HwpxImportSource = { readonly kind: 'hwpx' }
  | { readonly kind: 'hwp5'; readonly readOleChart: (data: Uint8Array) => Promise<OfficeChart> }
const hwpxChartNamespace = 'http://www.hancom.co.kr/hwpml/2016/ooxmlchart'
function cellHeader(element: OfficeXmlElement): boolean {
  switch (element.getAttribute('header')) {
    case '1': case 'true': return true
    case null: case '0': case 'false': return false
    default: throw new Error('HWPX 표의 머리글 속성이 올바르지 않습니다.')
  }
}
function tableInteger(value: string | null, label: string, minimum: number, maximum: number): number {
  if (!value || !/^\d+$/.test(value)) throw new Error(`HWPX 표의 ${label} 값이 없습니다.`)
  const number = Number(value)
  if (!Number.isSafeInteger(number) || number < minimum || number > maximum) throw new Error(`HWPX 표의 ${label} 값이 범위를 벗어납니다.`)
  return number
}
function attr(element: OfficeXmlElement, name: string): string {
  const value = element.getAttribute(name)
  if (value === null || value === '') throw new Error(`HWPX의 ${element.localName}.${name} 값이 없습니다.`)
  return value
}
function automaticNumber(element: OfficeXmlElement): string {
  const format = xmlChild(element, hwpxNs.paragraph, 'autoNumFormat')
  if (!format || xmlChildren(element).length !== 1 || xmlChildren(format).length) throw new Error('HWPX 자동 번호의 표시 형식이 올바르지 않습니다.')
  const type = format.getAttribute('type') ?? 'DIGIT'
  if (type !== 'DIGIT') throw new Error(`지원하지 않는 HWPX 자동 번호 형식입니다: ${type}`)
  if (!['PAGE', 'FOOTNOTE', 'ENDNOTE', 'PICTURE', 'TABLE', 'EQUATION', 'TOTAL_PAGE'].includes(element.getAttribute('numType') ?? 'PAGE')) throw new Error('HWPX 자동 번호의 종류가 올바르지 않습니다.')
  const number = /^([+-]?)(\d+)$/.exec(element.getAttribute('num') ?? '1')
  if (!number) throw new Error('HWPX 자동 번호의 값이 정수가 아닙니다.')
  // Keep the integer as text to avoid rounding long saved numbers through JavaScript Number.
  const digits = number[2]!.replace(/^0+(?=\d)/, ''), signed = number[1] === '-' && digits !== '0' ? `-${digits}` : digits
  const text = officeHtmlText(`${format.getAttribute('prefixChar') ?? ''}${signed}${format.getAttribute('suffixChar') ?? ''}`)
  switch (format.getAttribute('supscript') ?? '0') {
    case '0': case 'false': return text
    case '1': case 'true': return `<sup>${text}</sup>`
    default: throw new Error('HWPX 자동 번호의 위첨자 속성이 올바르지 않습니다.')
  }
}

/** Import the HWPX package spine and explicit native table/chart structures without executing its contents. */
export async function importArtifactHwpx(data: ArrayBuffer | Uint8Array, source: HwpxImportSource = { kind: 'hwpx' }): Promise<{ content: string; notices: readonly string[] }> {
  const zip = await loadOfficeArchive(data), notices = new Set<string>()
  let omittedContent = false, supportedContent = false
  if (new TextDecoder('utf-8', { fatal: true }).decode(await readOfficeBytes(zip, 'mimetype')) !== 'application/hwp+zip') throw new Error('HWPX 문서 형식이 아닙니다.')
  const container = await readOfficeXml(zip, 'META-INF/container.xml')
  if (container.documentElement?.namespaceURI !== hwpxNs.container || container.documentElement.localName !== 'container') throw new Error('HWPX 컨테이너 형식이 올바르지 않습니다.')
  const roots = xmlDescendants(container, hwpxNs.container, 'rootfile').filter(root => root.getAttribute('media-type') === 'application/hwpml-package+xml')
  if (roots.length !== 1) throw new Error('HWPX 본문 패키지 참조가 하나여야 합니다.')
  const packagePath = resolveOfficePart('', attr(roots[0]!, 'full-path')), packageXml = await readOfficeXml(zip, packagePath)
  const root = packageXml.documentElement!
  if (root.namespaceURI !== hwpxNs.package || root.localName !== 'package') throw new Error('HWPX 패키지 형식이 올바르지 않습니다.')
  const manifestNode = xmlChild(root, hwpxNs.package, 'manifest'), spine = xmlChild(root, hwpxNs.package, 'spine')
  if (!manifestNode || !spine) throw new Error('HWPX 파일 목록 또는 본문 순서가 없습니다.')
  const manifest = new Map<string, ManifestItem>()
  for (const item of xmlChildren(manifestNode, hwpxNs.package, 'item')) {
    const id = attr(item, 'id')
    if (manifest.has(id)) throw new Error('HWPX 파일 참조 이름이 겹칩니다.')
    // HWPX content.hpf href values are package-root paths, as in Hancom's files.
    manifest.set(id, { path: resolveOfficePart('', attr(item, 'href')), mime: attr(item, 'media-type').split(';')[0]!.trim() })
  }
  const sectionRoots: OfficeXmlElement[] = [], characterStyles = new Map<string, { bold: boolean; italic: boolean }>()
  const seen = new Set<string>()
  for (const reference of xmlChildren(spine, hwpxNs.package, 'itemref')) {
    const id = attr(reference, 'idref'), item = manifest.get(id)
    if (!item || seen.has(id)) throw new Error('HWPX 본문 순서의 참조가 없거나 겹칩니다.')
    seen.add(id)
    if (['application/javascript', 'application/x-javascript', 'text/javascript'].includes(item.mime)) {
      notices.add('문서에 포함된 스크립트는 가져오거나 실행하지 않았습니다.'); continue
    }
    if (item.mime !== 'application/xml' && item.mime !== 'text/xml') throw new Error(`지원하지 않는 HWPX 본문 파일입니다: ${item.path}`)
    const document = await readOfficeXml(zip, item.path), element = document.documentElement!
    if (element.namespaceURI === hwpxNs.head && element.localName === 'head') {
      for (const style of xmlDescendants(element, hwpxNs.head, 'charPr')) {
        const styleId = attr(style, 'id')
        if (characterStyles.has(styleId)) throw new Error('HWPX 문자 서식 참조가 겹칩니다.')
        characterStyles.set(styleId, { bold: !!xmlChild(style, hwpxNs.head, 'bold'), italic: !!xmlChild(style, hwpxNs.head, 'italic') })
      }
    } else if (element.namespaceURI === hwpxNs.section && element.localName === 'sec') sectionRoots.push(element)
    else throw new Error(`지원하지 않는 HWPX 본문 구조입니다: ${item.path}`)
  }
  if (!sectionRoots.length) throw new Error('HWPX 문서에 본문 구역이 없습니다.')
  if (sectionRoots.some(section => !xmlChildren(section, hwpxNs.paragraph, 'p').length)) throw new Error('HWPX 본문 구역에 문단이 없습니다.')
  notices.add('글꼴·페이지 배치·머리말과 일부 서식은 원본과 다를 수 있습니다. 표 셀과 차트 데이터는 편집할 수 있습니다.')

  async function picture(element: OfficeXmlElement): Promise<string> {
    const image = xmlChild(element, hwpxNs.core, 'img')
    if (!image) throw new Error('HWPX 그림의 데이터 참조를 확인할 수 없습니다.')
    const item = manifest.get(attr(image, 'binaryItemIDRef'))
    if (!item) throw new Error('HWPX 그림 파일의 참조가 없습니다.')
    if (item.mime !== 'image/png' && item.mime !== 'image/jpeg' && item.mime !== 'image/bmp') throw new Error(`지원하지 않는 HWPX 그림 형식입니다: ${item.mime}`)
    const bytes = await readOfficeBytes(zip, item.path), measured = officeImageDimensions(bytes), size = xmlChild(element, hwpxNs.paragraph, 'sz')
    if (!measured || measured.width <= 0 || measured.height <= 0 || item.mime !== `image/${measured.type}`) throw new Error('HWPX 그림의 실제 데이터와 파일 형식이 다릅니다.')
    let dimensions = ''
    if (size) {
      const width = attr(size, 'width'), height = attr(size, 'height')
      if (!/^\d+$/.test(width) || !/^\d+$/.test(height) || !Number.isSafeInteger(Number(width)) || !Number.isSafeInteger(Number(height)) || Number(width) <= 0 || Number(height) <= 0) throw new Error('HWPX 그림의 크기가 올바르지 않습니다.')
      dimensions = ` width="${Number(width) / hwpUnitsPerCssPixel}" height="${Number(height) / hwpUnitsPerCssPixel}"`
    }
    const description = xmlChild(element, hwpxNs.paragraph, 'shapeComment')?.textContent ?? '그림'
    return `<img src="data:${item.mime};base64,${fromByteArray(bytes)}" alt="${officeHtmlText(description)}"${dimensions}>`
  }

  async function table(element: OfficeXmlElement): Promise<string> {
    const rows = tableInteger(element.getAttribute('rowCnt'), '행 수', 1, hwpxTableLimits.rows), columns = tableInteger(element.getAttribute('colCnt'), '열 수', 1, hwpxTableLimits.columns)
    const rowElements = xmlChildren(element, hwpxNs.paragraph, 'tr')
    if (rowElements.length !== rows) throw new Error('HWPX 표의 행 수가 본문과 다릅니다.')
    const cellsByRow: Cell[][] = rowElements.map((row, rowIndex) => xmlChildren(row, hwpxNs.paragraph, 'tc').map(cell => {
      const address = xmlChild(cell, hwpxNs.paragraph, 'cellAddr'), span = xmlChild(cell, hwpxNs.paragraph, 'cellSpan')
      if (!address || !span) throw new Error('HWPX 표의 셀 주소 또는 병합 정보가 없습니다.')
      const item = { element: cell, row: tableInteger(address.getAttribute('rowAddr'), '셀 행', 0, rows - 1), column: tableInteger(address.getAttribute('colAddr'), '셀 열', 0, columns - 1),
        rows: tableInteger(span.getAttribute('rowSpan'), '행 병합', 1, rows), columns: tableInteger(span.getAttribute('colSpan'), '열 병합', 1, columns) }
      if (item.row !== rowIndex || item.row + item.rows > rows || item.column + item.columns > columns) throw new Error('HWPX 표의 셀 범위가 올바르지 않습니다.')
      return item
    }))
    checkOfficeTableGrid(rows, columns, cellsByRow.flat(), 'HWPX 표')
    const output: string[] = []
    for (const cells of cellsByRow) {
      const row: string[] = []
      for (const cell of [...cells].sort((a, b) => a.column - b.column)) {
        const list = xmlChild(cell.element, hwpxNs.paragraph, 'subList')
        if (!list) throw new Error('HWPX 표 셀의 본문이 없습니다.')
        const contents = await paragraphs(list), tag = cellHeader(cell.element) ? 'th' : 'td'
        row.push(`<${tag} rowspan="${cell.rows}" colspan="${cell.columns}">${contents}</${tag}>`)
      }
      output.push(`<tr>${row.join('')}</tr>`)
    }
    return `<table><tbody>${output.join('')}</tbody></table>`
  }

  async function withCaption(element: OfficeXmlElement, object: Fragment): Promise<Fragment[]> {
    const caption = xmlChild(element, hwpxNs.paragraph, 'caption')
    if (!caption) return [object]
    const list = xmlChild(caption, hwpxNs.paragraph, 'subList')
    if (!list || !xmlChildren(list, hwpxNs.paragraph, 'p').length) throw new Error('HWPX 캡션의 문단 목록이 없습니다.')
    const text: Fragment = { kind: 'block', content: await paragraphs(list) }
    notices.add('캡션은 개체와 별도의 본문 문단으로 옮겼습니다.')
    // Hancom's caption model defaults side to LEFT; a caption is its own paragraph list.
    switch (caption.getAttribute('side') ?? 'LEFT') {
      case 'TOP': return [text, object]
      case 'BOTTOM': return [object, text]
      case 'LEFT':
        notices.add('왼쪽 캡션을 개체 앞의 문단으로 옮겼습니다. 가로 배치는 유지하지 않습니다.')
        return [text, object]
      case 'RIGHT':
        notices.add('오른쪽 캡션을 개체 뒤의 문단으로 옮겼습니다. 가로 배치는 유지하지 않습니다.')
        return [object, text]
      default: throw new Error('HWPX 캡션의 위치가 올바르지 않습니다.')
    }
  }

  async function fragments(element: OfficeXmlElement): Promise<Fragment[]> {
    if (element.namespaceURI !== hwpxNs.paragraph) {
      if (source.kind === 'hwp5') throw new Error(`HWP에서 가져올 수 없는 문서 개체입니다: ${element.localName}`)
      omittedContent = true
      notices.add('지원하지 않는 문서 개체의 배치는 옮기지 않았습니다.')
      return (await Promise.all(xmlChildren(element).map(fragments))).flat()
    }
    switch (element.localName) {
      case 't': {
        const content: string[] = []
        for (const child of Array.from(element.childNodes)) {
          if (child.nodeType === 3 || child.nodeType === 4) content.push(officeHtmlText(child.textContent ?? ''))
          else if (child.nodeType === 1) {
            const parts = await fragments(child as OfficeXmlElement)
            if (parts.some(part => part.kind === 'block')) throw new Error('HWPX 글자 안에 표 또는 차트가 들어 있습니다.')
            content.push(...parts.map(part => part.content))
          }
        }
        const text = content.join('')
        if (text.trim()) supportedContent = true
        return [{ kind: 'inline', content: text }]
      }
      case 'lineBreak': return [{ kind: 'inline', content: '<br>' }]
      case 'tab': return [{ kind: 'inline', content: '\t' }]
      case 'nbSpace': return [{ kind: 'inline', content: '\u00a0' }]
      case 'fwSpace': return [{ kind: 'inline', content: '\u2007' }]
      case 'autoNum':
        supportedContent = true
        notices.add('자동 번호는 저장된 숫자를 본문 글자로 옮겼습니다.')
        return [{ kind: 'inline', content: automaticNumber(element) }]
      case 'tbl': supportedContent = true; return withCaption(element, { kind: 'block', content: await table(element) })
      case 'pic': supportedContent = true; return withCaption(element, { kind: 'inline', content: await picture(element) })
      case 'chart': supportedContent = true; return withCaption(element, { kind: 'block', content: officeChartFigure(await readOfficeChart(zip, resolveOfficePart('', attr(element, 'chartIDRef')))) })
      case 'run': {
        const style = characterStyles.get(attr(element, 'charPrIDRef'))
        if (!style) throw new Error('HWPX 문자 서식의 참조가 없습니다.')
        return (await Promise.all(xmlChildren(element).map(fragments))).flat().map(part => part.kind === 'block' ? part : { ...part,
          content: `${style.bold ? '<strong>' : ''}${style.italic ? '<em>' : ''}${part.content}${style.italic ? '</em>' : ''}${style.bold ? '</strong>' : ''}` })
      }
      case 'switch': {
        const cases = xmlChildren(element, hwpxNs.paragraph, 'case')
        const chartCases = cases.filter(item => xmlDescendants(item, hwpxNs.paragraph, 'chart').length > 0)
        const native = chartCases.filter(item => item.getAttributeNS(hwpxNs.paragraph, 'required-namespace') === hwpxChartNamespace)
        if (native.length > 1 || (chartCases.length > 0 && native.length !== 1)) throw new Error('HWPX 차트 대체 개체의 namespace가 올바르지 않습니다.')
        const selected = native[0] ?? xmlChild(element, hwpxNs.paragraph, 'default')
        if (!selected) throw new Error('HWPX 대체 개체의 지원 형식을 확인할 수 없습니다.')
        return (await Promise.all(xmlChildren(selected).map(fragments))).flat()
      }
      case 'ctrl': case 'subList': return (await Promise.all(xmlChildren(element).map(fragments))).flat()
      case 'secPr': case 'colPr': case 'linesegarray': case 'shapeComment': return []
      case 'ole': {
        if (source.kind === 'hwpx') throw new Error('OLE 개체의 차트 데이터는 가져올 수 없습니다. native HWPX 차트가 필요합니다.')
        const item = manifest.get(attr(element, 'binaryItemIDRef'))
        if (!item) throw new Error('HWP 차트 개체의 파일 참조가 없습니다.')
        const chart = await source.readOleChart(await readOfficeBytes(zip, item.path))
        supportedContent = true
        return withCaption(element, { kind: 'block', content: officeChartFigure(chart) })
      }
      default:
        if (source.kind === 'hwp5') throw new Error(`HWP에서 가져올 수 없는 문서 개체입니다: ${element.localName}`)
        omittedContent = true
        notices.add(`HWPX ${element.localName} 개체의 서식은 옮기지 않았습니다.`)
        return (await Promise.all(xmlChildren(element).map(fragments))).flat()
    }
  }
  async function paragraphs(owner: OfficeXmlElement): Promise<string> {
    const result: string[] = []
    for (const paragraph of xmlChildren(owner, hwpxNs.paragraph, 'p')) {
      const parts = (await Promise.all(xmlChildren(paragraph).map(fragments))).flat()
      let inline = ''
      for (const part of parts) {
        if (part.kind === 'inline') inline += part.content
        else { if (inline) result.push(`<p>${inline}</p>`); inline = ''; result.push(part.content) }
      }
      if (inline) result.push(`<p>${inline}</p>`)
      else if (!parts.some(part => part.kind === 'block') && !xmlDescendants(paragraph, hwpxNs.paragraph, 'secPr').length
        && !xmlDescendants(paragraph, hwpxNs.paragraph, 'colPr').length) result.push('<p></p>')
    }
    return result.join('')
  }
  const content: string[] = []
  for (const section of sectionRoots) content.push(await paragraphs(section))
  if (!supportedContent && omittedContent) throw new Error('이 HWPX 문서에는 가져올 수 있는 본문·표·차트가 없습니다.')
  return { content: content.join('') || '<p></p>', notices: [...notices] }
}
