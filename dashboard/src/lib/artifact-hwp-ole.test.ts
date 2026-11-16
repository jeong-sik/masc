import { expect, it } from 'vitest'
import { readHwpOleChart } from './artifact-hwp-ole'
import type { OfficeChartType } from './artifact-office-chart'
import { officeImportLimits } from './artifact-office-xml'
import { writeHwpTestCompound } from './artifact-hwp-test-fixture'

const chartNamespace = 'http://schemas.openxmlformats.org/drawingml/2006/chart'
const drawingNamespace = 'http://schemas.openxmlformats.org/drawingml/2006/main'
const relationshipNamespace = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
const encoder = new TextEncoder()

// This fixture is independent of RHWP and MASC's Office exporters.
function drawingChart(type: OfficeChartType = 'column'): string {
  const kind = type === 'column' || type === 'bar' ? 'barChart' : `${type}Chart`
  const direction = type === 'column' || type === 'bar' ? `<c:barDir val="${type === 'column' ? 'col' : 'bar'}"/>` : ''
  const grouping = type === 'pie' ? '' : `<c:grouping val="${type === 'line' ? 'standard' : 'clustered'}"/>`
  const axisReferences = type === 'pie' ? '' : '<c:axId val="1"/><c:axId val="2"/>'
  const axes = type === 'pie' ? '' : '<c:catAx><c:axId val="1"/></c:catAx><c:valAx><c:axId val="2"/><c:numFmt formatCode="0.00" sourceLinked="0"/></c:valAx>'
  const blanks = type === 'pie' ? '' : '<c:dispBlanksAs val="span"/>'
  return `<?xml version="1.0" encoding="UTF-8"?>
<c:chartSpace xmlns:c="${chartNamespace}" xmlns:a="${drawingNamespace}" xmlns:r="${relationshipNamespace}">
<c:chart><c:title><c:tx><c:rich><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>집행 금액 &amp; 예산</a:t></a:r></a:p></c:rich></c:tx></c:title>
<c:plotArea><c:${kind}>${direction}${grouping}<c:ser><c:idx val="0"/><c:order val="0"/>
<c:tx><c:v>실적</c:v></c:tx><c:cat><c:strLit><c:ptCount val="3"/>
<c:pt idx="0"><c:v>서울</c:v></c:pt><c:pt idx="1"><c:v>부산</c:v></c:pt><c:pt idx="2"><c:v>대전</c:v></c:pt>
</c:strLit></c:cat><c:val><c:numLit><c:formatCode>0.000</c:formatCode><c:ptCount val="3"/>
<c:pt idx="0"><c:v>1.250</c:v></c:pt><c:pt idx="2"><c:v>0</c:v></c:pt></c:numLit></c:val>
</c:ser>${axisReferences}</c:${kind}>${axes}</c:plotArea>${blanks}</c:chart></c:chartSpace>`
}

function compound(entries: readonly (readonly [string, string | Uint8Array])[]): Uint8Array {
  return writeHwpTestCompound(entries.map(([name, content]) => [name, typeof content === 'string' ? encoder.encode(content) : content] as const))
}

function envelope(bytes: Uint8Array): Uint8Array {
  const output = new Uint8Array(bytes.byteLength + 4)
  new DataView(output.buffer).setUint32(0, bytes.byteLength, true)
  output.set(bytes, 4)
  return output
}

for (const type of ['column', 'bar', 'line', 'pie'] as const) for (const prefixed of [false, true]) {
  it(`reads ${prefixed ? 'length-prefixed' : 'unprefixed'} ${type} OLE data and formatting`, async () => {
    const bytes = compound([['OOXMLChartContents', drawingChart(type)], ['Contents', 'legacy fallback is not the editable source']])
    const chart = await readHwpOleChart(prefixed ? envelope(bytes) : bytes)
    expect(chart).toEqual({ type, title: '집행 금액 & 예산', categories: ['서울', '부산', '대전'],
      series: [{ name: '실적', values: [1.25, null, 0], numberFormat: '0.000' }],
      ...(type === 'pie' ? {} : { emptyValues: 'connect', valueFormat: '0.00' }) })
  })
}

it('reads a prefixed OLE subarray without inspecting unrelated backing-buffer bytes', async () => {
  const bytes = envelope(compound([['OOXMLChartContents', drawingChart()]])), backing = new Uint8Array(bytes.length + 11)
  backing.set(bytes, 7)
  expect((await readHwpOleChart(backing.subarray(7, bytes.length + 7))).type).toBe('column')
})

for (const difference of [-1, 1]) it(`rejects a size prefix differing from its CFB bytes by ${difference}`, async () => {
  const bytes = envelope(compound([['OOXMLChartContents', drawingChart()]]))
  new DataView(bytes.buffer).setUint32(0, bytes.length - 4 + difference, true)
  await expect(readHwpOleChart(bytes)).rejects.toThrow('길이 정보')
})

it('rejects truncated prefixes, damaged signatures, and nested envelopes', async () => {
  const valid = envelope(compound([['OOXMLChartContents', drawingChart()]])), damaged = valid.slice()
  damaged[4] = 0
  for (const bytes of [new Uint8Array(), valid.subarray(0, 3), damaged, envelope(valid)]) {
    await expect(readHwpOleChart(bytes)).rejects.toThrow('CFB 서명 또는 길이 정보')
  }
})

it('rejects an OLE part over the shared Office part-size limit before parsing CFB', async () => {
  await expect(readHwpOleChart(new Uint8Array(officeImportLimits.partBytes + 1))).rejects.toThrow('크기 한도')
})

it('resolves the root chart stream using CFB case-insensitive identity', async () => {
  expect(await readHwpOleChart(compound([['ooxmlchartcontents', drawingChart()]])))
    .toEqual(await readHwpOleChart(compound([['OOXMLChartContents', drawingChart()]])))
})

for (const stream of ['Contents', 'Unknown', 'nested/OOXMLChartContents']) {
  it(`rejects ${stream} instead of guessing an editable chart source`, async () => {
    await expect(readHwpOleChart(compound([[stream, drawingChart()]]))).rejects.toThrow('최상위 OOXMLChartContents 하나')
  })
}

it('rejects a second chart source nested below the root chart', async () => {
  await expect(readHwpOleChart(compound([['OOXMLChartContents', drawingChart()], ['nested/OOXMLChartContents', drawingChart('bar')]])))
    .rejects.toThrow('최상위 OOXMLChartContents 하나')
})

it('uses the existing chart reader to reject stacking and unknown chart types', async () => {
  for (const xml of [drawingChart().replace('val="clustered"', 'val="stacked"'), drawingChart().replaceAll('barChart', 'radarChart')]) {
    await expect(readHwpOleChart(compound([['OOXMLChartContents', xml]]))).rejects.toThrow(/누적 차트|지원하지 않는 차트 구조/)
  }
})

it('rejects linked workbook data rather than trusting an unverified chart cache', async () => {
  const xml = drawingChart().replace('</c:chartSpace>', '<c:externalData r:id="external"/></c:chartSpace>')
  await expect(readHwpOleChart(compound([['OOXMLChartContents', xml]]))).rejects.toThrow('차트 외부 원본')
})

it('rejects XML entities and malformed point counts through the shared XML/chart parser', async () => {
  const withEntity = drawingChart().replace('<c:chartSpace', '<!DOCTYPE chart [<!ENTITY secret SYSTEM "file:///private">]><c:chartSpace')
  const wrongCount = drawingChart().replace('<c:ptCount val="3"/>', '<c:ptCount val="4"/>')
  await expect(readHwpOleChart(compound([['OOXMLChartContents', withEntity]]))).rejects.toThrow('DOCTYPE')
  await expect(readHwpOleChart(compound([['OOXMLChartContents', wrongCount]]))).rejects.toThrow('차트 항목 수와 저장된 데이터 수')
})
