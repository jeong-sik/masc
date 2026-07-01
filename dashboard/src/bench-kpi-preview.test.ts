import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

function readPreviewFile(file: string): string {
  return readFileSync(resolve(process.cwd(), 'design-system/preview', file), 'utf8')
}

describe('bench KPI design-system preview', () => {
  it('loads the restored local module script', () => {
    const html = readPreviewFile('bench-kpi.html')
    const script = readPreviewFile('bench-kpi.ts')

    expect(html).toContain('<script type="module" src="bench-kpi.ts"></script>')
    expect(script).toContain("from '../../src/components/kpi-strip'")
    expect(script).toContain("from '../../src/components/kpi-strip-island'")
  })

  it('does not reference the removed sync-mount spike wrapper', () => {
    const html = readPreviewFile('bench-kpi.html')
    const script = readPreviewFile('bench-kpi.ts')

    expect(html).not.toContain('run-spike-sync')
    expect(html).not.toContain('sync-host')
    expect(script).not.toContain('kpi-strip-island-sync')
    expect(script).not.toContain('KpiStripIslandSync')
  })
})
