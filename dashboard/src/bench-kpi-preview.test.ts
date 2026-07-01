import { readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

// Resolve relative to this test file's own location, not process.cwd() —
// cwd varies with how Vitest is invoked (repo root vs dashboard package
// root), but this file's path relative to design-system/preview/ is fixed.
const PREVIEW_DIR = resolve(dirname(fileURLToPath(import.meta.url)), '../design-system/preview')

function readPreviewFile(file: string): string {
  return readFileSync(resolve(PREVIEW_DIR, file), 'utf8')
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

  it('keeps cells/strip bounded to the preview data shape', () => {
    const html = readPreviewFile('bench-kpi.html')
    const script = readPreviewFile('bench-kpi.ts')

    expect(html).toContain('id="cells" type="number" value="6" min="1" max="6"')
    expect(script).toContain('const MAX_CELLS_PER_STRIP = 6')
    expect(script).toContain('function readCellsPerStrip')
  })

  it('uses row-scoped update sentinels instead of global text matches', () => {
    const script = readPreviewFile('bench-kpi.ts')

    expect(script).toContain('data-bench-row')
    expect(script).toContain('expectedRows.every')
    expect(script).toContain('host.querySelector(`[data-bench-row="${row.id}"]`)')
    expect(script).not.toContain('expectedTexts.every((t) => text.includes(t))')
  })
})
