import { expect, it } from 'vitest'
import JSZip from 'jszip'
import type { ArtifactDocument } from '../api/published-artifacts'
import { officeChartFigure } from './artifact-office-chart'
import { artifactWordFile } from './artifact-word-export'
import { importArtifactDocx } from './artifact-docx-import'
import { artifactHwpxFile } from './artifact-hwpx-export'
import { importArtifactHwpx } from './artifact-hwpx-import'
import { officeNs, parseOfficeXml, xmlDescendants } from './artifact-office-xml'

for (const format of ['docx', 'hwpx'] as const) for (const type of ['column', 'bar', 'line', 'pie'] as const) for (const title of ['', '월별 실적']) {
  it(`exports ${format} ${type} with ${title === '' ? 'no automatic title' : 'its explicit title'}`, async () => {
    const content = officeChartFigure({ type, title, categories: ['서울'], series: [{ name: '실적', values: [42] }] })
    const input: ArtifactDocument = { content, revisions: [], artifact: {
      id: `artifact-${'a'.repeat(32)}`, revision: 1, title: '보고서', summary: '제목 대조', format: 'html',
      author: 'fixture', created_at: '2026-11-16T00:00:00Z', task_id: null, goal_id: null, url: '/',
      body: { _blob: { sha256: 'b'.repeat(64) } },
    } }
    const file = await (format === 'docx' ? artifactWordFile : artifactHwpxFile)(input), zip = await JSZip.loadAsync(file.data)
    const path = format === 'docx' ? 'word/charts/chart1.xml' : 'Chart/chart1.xml', part = zip.file(path)
    expect(part).not.toBeNull()
    const xml = parseOfficeXml(await part!.async('string'), path)
    const automatic = xmlDescendants(xml, officeNs.chart, 'autoTitleDeleted')
    expect(automatic).toHaveLength(1)
    expect(automatic[0]!.getAttribute('val')).toBe(title === '' ? '1' : '0')
    expect(xmlDescendants(xml, officeNs.chart, 'title')).toHaveLength(title === '' ? 0 : 1)
    const imported = await (format === 'docx' ? importArtifactDocx : importArtifactHwpx)(file.data)
    expect(imported.content).toContain(`<figcaption>${title}</figcaption>`)
    expect(imported.content).toContain('<td>42</td>')
  })
}
