import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { join, resolve } from 'node:path'
import { initSync } from '@rhwp/core'
import { parseFragment, defaultTreeAdapter as tree, type DefaultTreeAdapterTypes as Nodes } from 'parse5'
import type { ArtifactDocument } from '../../src/api/published-artifacts'
import { convertArtifactHwp } from '../../src/lib/artifact-hwp-convert'
import { importArtifactHwpx } from '../../src/lib/artifact-hwpx-import'
import { importArtifactDocx } from '../../src/lib/artifact-docx-import'
import { artifactHwpxFile } from '../../src/lib/artifact-hwpx-export'
import { artifactWordFile } from '../../src/lib/artifact-word-export'
import { officeChartFigure, officeChartFromFigure, type OfficeChart } from '../../src/lib/artifact-office-chart'

const [samplesArgument, outputArgument] = process.argv.slice(2)
if (!samplesArgument || !outputArgument) throw new Error('Usage: pnpm exec tsx fixtures/hwp-import/probe.ts <rhwp/samples> <output-directory>')
const samples = resolve(samplesArgument), output = resolve(outputArgument)
mkdirSync(output, { recursive: true })
const require = createRequire(import.meta.url)
const wasm = readFileSync(require.resolve('@rhwp/core/rhwp_bg.wasm'))
initSync({ module: wasm })
const digest = (bytes: Uint8Array) => createHash('sha256').update(bytes).digest('hex')
const cases = [
  { kind: 'column', file: 'chart/세로막대형/묶은세로막대형' },
  { kind: 'bar', file: 'chart/가로막대형/묶은가로막대형' },
  { kind: 'line', file: 'chart/라인/꺽은선형' },
  { kind: 'pie', file: 'chart/원형/2차원원형' },
] as const

function charts(content: string): OfficeChart[] {
  const result: OfficeChart[] = []
  function visit(node: Nodes.ParentNode) {
    for (const child of node.childNodes) if (tree.isElementNode(child)) {
      if (child.tagName === 'figure') {
        const chart = officeChartFromFigure(child)
        if (chart) result.push(chart)
      }
      visit(child)
    }
  }
  visit(parseFragment(content))
  return result
}
function document(content: string): ArtifactDocument {
  const artifact = { id: `artifact-${'c'.repeat(32)}`, revision: 1, title: 'HWP 원데이터 대조', summary: '공개 HWP 변환 확인', format: 'html' as const,
    author: 'fixture', created_at: '2026-11-16T00:00:00Z', task_id: null, goal_id: null, url: '/', body: { _blob: { sha256: 'd'.repeat(64) } } }
  return { content, artifact, revisions: [artifact] }
}

const results: { kind: string; inputSha256: string; pairedHwpxSha256: string; native: OfficeChart; edited: OfficeChart;
  exported: { format: string; sha256: string; chart: OfficeChart }[] }[] = []
for (const fixture of cases) {
  const input = new Uint8Array(readFileSync(join(samples, `${fixture.file}.hwp`)))
  const paired = new Uint8Array(readFileSync(join(samples, `${fixture.file}.hwpx`)))
  const expected = charts((await importArtifactHwpx(paired)).content)
  const actual = await convertArtifactHwp(input)
  assert.equal(expected.length, 1)
  assert.deepEqual(charts(actual.content), expected, `${fixture.kind}: complete native chart data`)
  const original = expected[0]!
  const edited: OfficeChart = { ...original, series: original.series.map((series, index) => index === 0
    ? { ...series, values: series.values.map((value, at) => at === 0 ? 42 : value) } : series) }
  const source = officeChartFigure(original)
  assert.ok(actual.content.includes(source), 'the imported editable chart uses its one canonical data table')
  const content = actual.content.replace(source, officeChartFigure(edited))
  const exported: { format: string; sha256: string; chart: OfficeChart }[] = []
  for (const format of ['hwpx', 'docx'] as const) {
    const file = await (format === 'hwpx' ? artifactHwpxFile : artifactWordFile)(document(content))
    const returned = await (format === 'hwpx' ? importArtifactHwpx : importArtifactDocx)(file.data)
    const values = charts(returned.content)
    assert.deepEqual(values, [edited], `${fixture.kind}: edited chart roundtrip via ${format}`)
    const bytes = new Uint8Array(file.data)
    writeFileSync(join(output, `${fixture.kind}-edited.${format}`), bytes)
    exported.push({ format, sha256: digest(bytes), chart: values[0]! })
  }
  writeFileSync(join(output, `${fixture.kind}-imported.html`), actual.content)
  results.push({ kind: fixture.kind, inputSha256: digest(input), pairedHwpxSha256: digest(paired), native: original, edited, exported })
}
const report = { observedAt: new Date().toISOString(), engine: '@rhwp/core@0.9.0', wasmSha256: digest(wasm),
  chartsCompared: results.length, exportsReimported: results.reduce((count, row) => count + row.exported.length, 0), results,
  scope: 'Actual pinned WASM and existing Office import/export modules. Browser downloads, publication and native Hancom/Word are unverified.' }
writeFileSync(join(output, 'report.json'), JSON.stringify(report, null, 2))
console.log(JSON.stringify({ chartsCompared: report.chartsCompared, exportsReimported: report.exportsReimported, report: join(output, 'report.json') }))
