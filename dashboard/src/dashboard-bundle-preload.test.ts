import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { build } from 'vite'
import { afterEach, describe, expect, it } from 'vitest'

type ManifestEntry = {
  file?: string
  imports?: string[]
  isEntry?: boolean
  name?: string
}

const outDirs: string[] = []

function modulePreloads(html: string): string[] {
  return [...html.matchAll(/<link[^>]+rel=["']modulepreload["'][^>]+href=["']([^"']+)["'][^>]*>/gi)]
    .flatMap(match => match[1] ? [match[1]] : [])
}

function manifestEntriesByName(
  manifest: Record<string, ManifestEntry>,
  name: string,
): Array<[string, ManifestEntry]> {
  return Object.entries(manifest).filter(([, entry]) => entry.name === name)
}

function dashboardHrefForManifestEntry(entry: ManifestEntry): string {
  if (!entry.file) throw new Error('manifest entry has no file')
  return `/dashboard/${entry.file}`
}

describe('dashboard production bundle preloads', () => {
  afterEach(() => {
    while (outDirs.length > 0) {
      const dir = outDirs.pop()
      if (dir) rmSync(dir, { recursive: true, force: true })
    }
  })

  it('keeps only the vendor runtime chunk in the initial preload list', async () => {
    const outDir = mkdtempSync(join(tmpdir(), 'masc-dashboard-preload-'))
    outDirs.push(outDir)

    await build({
      configFile: resolve(__dirname, '../vite.config.ts'),
      logLevel: 'silent',
      build: {
        outDir,
        emptyOutDir: true,
        manifest: true,
        sourcemap: false,
      },
    })

    const html = readFileSync(join(outDir, 'index.html'), 'utf8')
    const manifest = JSON.parse(
      readFileSync(join(outDir, '.vite/manifest.json'), 'utf8'),
    ) as Record<string, ManifestEntry>
    const entry = manifest['index.html']

    expect(entry?.isEntry).toBe(true)
    const vendorEntries = manifestEntriesByName(manifest, 'vendor')
    expect(vendorEntries).toHaveLength(1)
    const vendorEntryPair = vendorEntries[0]
    if (!vendorEntryPair) throw new Error('vendor manifest entry missing')
    const [vendorKey, vendorEntry] = vendorEntryPair
    expect((entry?.imports ?? []).filter(id => manifest[id]?.name === 'vendor')).toEqual([vendorKey])

    const preloads = modulePreloads(html)
    expect(preloads).toEqual([dashboardHrefForManifestEntry(vendorEntry)])
  }, 120_000)
})
