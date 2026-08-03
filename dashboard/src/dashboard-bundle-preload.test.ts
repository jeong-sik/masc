import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { build, type Rollup } from 'vite'
import { afterEach, describe, expect, it } from 'vitest'

type ManifestEntry = {
  file?: string
  imports?: string[]
  isEntry?: boolean
  name?: string
}

const outDirs: string[] = []

function modulePreloads(html: string): string[] {
  const template = document.createElement('template')
  template.innerHTML = html
  return [...template.content.querySelectorAll('link[rel~="modulepreload"]')].flatMap(link => {
    const href = link.getAttribute('href')
    return href ? [href] : []
  })
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

function staticChunkClosure(
  chunks: Rollup.OutputChunk[],
  entry: Rollup.OutputChunk,
): Rollup.OutputChunk[] {
  const byFileName = new Map(chunks.map(chunk => [chunk.fileName, chunk]))
  const seen = new Set<string>()
  const pending = [entry.fileName]

  while (pending.length > 0) {
    const fileName = pending.pop()
    if (!fileName || seen.has(fileName)) continue
    seen.add(fileName)
    const chunk = byFileName.get(fileName)
    if (chunk) pending.push(...chunk.imports)
  }

  return [...seen].flatMap(fileName => {
    const chunk = byFileName.get(fileName)
    return chunk ? [chunk] : []
  })
}

const LAZY_SCHEMA_MODULE_SUFFIXES = [
  '/api/schemas/logs.ts',
  '/api/schemas/provider-logs.ts',
  '/api/schemas/dashboard-config.ts',
  '/api/schemas/agent-timeline.ts',
  '/api/schemas/agent-relations.ts',
  '/api/schemas/runtime-defaults.ts',
  '/api/schemas/runtime-resolved.ts',
  '/api/schemas/keeper-composite.ts',
  '/api/schemas/keeper-chat-history.ts',
  '/api/schemas/keeper-transitions.ts',
] as const

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

    const buildResult = await build({
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

    const outputs = (Array.isArray(buildResult) ? buildResult : [buildResult]) as Rollup.RollupOutput[]
    const chunks = outputs.flatMap(output => output.output)
      .filter((item): item is Rollup.OutputChunk => item.type === 'chunk')
    const entryChunk = chunks.find(chunk => chunk.isEntry && chunk.facadeModuleId?.endsWith('/index.html'))
    if (!entryChunk) throw new Error('dashboard entry chunk missing')
    const initialModuleIds = staticChunkClosure(chunks, entryChunk)
      .flatMap(chunk => Object.keys(chunk.modules))
      .map(moduleId => moduleId.replaceAll('\\', '/'))
    const eagerSchemas = LAZY_SCHEMA_MODULE_SUFFIXES.filter(suffix => (
      initialModuleIds.some(moduleId => moduleId.endsWith(suffix))
    ))
    expect(eagerSchemas).toEqual([])
  }, 120_000)

  it('reads modulepreloads from parsed link attributes', () => {
    const html = [
      '<link href=/dashboard/assets/mermaid.js rel=modulepreload>',
      '<script type="module" src="/dashboard/assets/index.js"></script>',
      '<link rel="stylesheet" href="/dashboard/assets/index.css">',
      '<link crossorigin rel="modulepreload" href="/dashboard/assets/vendor.js">',
    ].join('')

    expect(modulePreloads(html)).toEqual([
      '/dashboard/assets/mermaid.js',
      '/dashboard/assets/vendor.js',
    ])
  })
})
