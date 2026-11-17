import JSZip from 'jszip'
import { XMLSerializer } from '@xmldom/xmldom'
import type { OfficeChart } from './artifact-office-chart'
import { officeNs as ns, parseOfficeXml, readOfficeRelationships, resolveOfficePart, xmlChild, xmlChildren, xmlDescendants } from './artifact-office-xml'

const firstCustomNumberFormat = 164
const serialize = new XMLSerializer()
function columnName(index: number): string {
  let name = ''
  for (let at = index; at > 0; at = Math.floor((at - 1) / 26)) name = String.fromCharCode(65 + (at - 1) % 26) + name
  return name
}

/** docx/charts generates General-format workbooks. Apply each series' format to
 * both its cache and workbook cells, including blank cells that a user may fill. */
export async function formatOfficeChartSeries(data: ArrayBuffer, charts: readonly OfficeChart[]): Promise<ArrayBuffer> {
  if (!charts.some(chart => chart.series.some(series => series.numberFormat !== undefined && series.numberFormat !== 'General'))) return data
  const zip = await JSZip.loadAsync(data)
  for (const [index, chart] of charts.entries()) {
    if (!chart.series.some(series => series.numberFormat !== undefined && series.numberFormat !== 'General')) continue
    // These are paths produced by our new Document, never paths from a template.
    const chartPath = `word/charts/chart${index + 1}.xml`, chartPart = zip.file(chartPath)
    if (!chartPart) throw new Error('생성한 차트 파일이 없습니다.')
    const chartXml = parseOfficeXml(await chartPart.async('string'), chartPath)
    const sources = xmlDescendants(chartXml, ns.chart, 'externalData')
    if (sources.length !== 1) throw new Error('생성한 차트의 Excel 데이터 참조가 없습니다.')
    const relation = (await readOfficeRelationships(zip, chartPath)).get(sources[0]!.getAttributeNS(ns.relationships, 'id') ?? '')
    if (!relation || relation.external || relation.type !== `${ns.relationships}/package`) throw new Error('생성한 차트의 Excel 데이터 연결이 올바르지 않습니다.')
    const bookPath = resolveOfficePart(chartPath, relation.target), bookPart = zip.file(bookPath)
    if (!bookPart) throw new Error('생성한 차트의 Excel 파일이 없습니다.')
    const book = await JSZip.loadAsync(await bookPart.async('uint8array'))
    const stylesPath = 'xl/styles.xml', sheetPath = 'xl/worksheets/sheet1.xml'
    const stylePart = book.file(stylesPath), sheetPart = book.file(sheetPath)
    if (!stylePart || !sheetPart) throw new Error('생성한 Excel 데이터의 서식 또는 셀 파일이 없습니다.')
    const styles = parseOfficeXml(await stylePart.async('string'), stylesPath), sheet = parseOfficeXml(await sheetPart.async('string'), sheetPath)
    const root = styles.documentElement!, xfs = xmlChild(root, ns.spreadsheet, 'cellXfs')
    const baseline = xfs && xmlChild(xfs, ns.spreadsheet, 'xf')
    if (!xfs || !baseline) throw new Error('생성한 Excel 데이터의 기본 숫자 서식이 없습니다.')
    let formats = xmlChild(root, ns.spreadsheet, 'numFmts')
    if (!formats) { formats = styles.createElementNS(ns.spreadsheet, 'numFmts'); root.insertBefore(formats, root.firstChild) }
    const rows = new Map(xmlDescendants(sheet, ns.spreadsheet, 'row').map(row => [row.getAttribute('r'), row])), seriesNodes = xmlDescendants(chartXml, ns.chart, 'ser')
    if (seriesNodes.length !== chart.series.length) throw new Error('생성한 차트의 계열 수가 원본과 다릅니다.')
    for (const [seriesIndex, series] of chart.series.entries()) {
      if (series.numberFormat === undefined || series.numberFormat === 'General') continue
      const cache = xmlDescendants(seriesNodes[seriesIndex]!, ns.chart, 'numCache')
      if (cache.length !== 1) throw new Error('생성한 차트의 계열 데이터가 없습니다.')
      let code = xmlChild(cache[0]!, ns.chart, 'formatCode')
      if (!code) { code = chartXml.createElementNS(ns.chart, 'c:formatCode'); cache[0]!.insertBefore(code, cache[0]!.firstChild) }
      code.textContent = series.numberFormat
      const formatId = firstCustomNumberFormat + seriesIndex, format = styles.createElementNS(ns.spreadsheet, 'numFmt')
      format.setAttribute('numFmtId', String(formatId)); format.setAttribute('formatCode', series.numberFormat); formats.appendChild(format)
      const styleIndex = xmlChildren(xfs, ns.spreadsheet, 'xf').length, xf = styles.createElementNS(ns.spreadsheet, 'xf')
      for (const attribute of Array.from(baseline.attributes)) xf.setAttributeNS(attribute.namespaceURI, attribute.name, attribute.value)
      for (const child of Array.from(baseline.childNodes)) xf.appendChild(child.cloneNode(true))
      xf.setAttribute('numFmtId', String(formatId)); xf.setAttribute('applyNumberFormat', '1'); xfs.appendChild(xf)
      const column = columnName(seriesIndex + 2)
      for (const [at] of series.values.entries()) {
        const rowNumber = at + 2, row = rows.get(String(rowNumber))
        if (!row) throw new Error('생성한 Excel 데이터의 행이 없습니다.')
        const address = `${column}${rowNumber}`
        let cell = xmlChildren(row, ns.spreadsheet, 'c').find(cell => cell.getAttribute('r') === address)
        if (!cell) {
          cell = sheet.createElementNS(ns.spreadsheet, 'c'); cell.setAttribute('r', address)
          const after = xmlChildren(row, ns.spreadsheet, 'c').find(other => {
            const letters = /^[A-Z]+/.exec(other.getAttribute('r') ?? '')?.[0]
            if (!letters) throw new Error('생성한 Excel 셀 주소가 올바르지 않습니다.')
            return Array.from(letters).reduce((value, letter) => value * 26 + letter.charCodeAt(0) - 64, 0) > seriesIndex + 2
          })
          row.insertBefore(cell, after ?? null)
        }
        cell.setAttribute('s', String(styleIndex))
      }
    }
    formats.setAttribute('count', String(xmlChildren(formats, ns.spreadsheet, 'numFmt').length))
    xfs.setAttribute('count', String(xmlChildren(xfs, ns.spreadsheet, 'xf').length))
    book.file(stylesPath, serialize.serializeToString(styles)); book.file(sheetPath, serialize.serializeToString(sheet))
    zip.file(chartPath, serialize.serializeToString(chartXml)); zip.file(bookPath, await book.generateAsync({ type: 'uint8array', compression: 'DEFLATE' }))
  }
  return zip.generateAsync({ type: 'arraybuffer', compression: 'DEFLATE' })
}
