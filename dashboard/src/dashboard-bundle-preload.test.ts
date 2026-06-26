import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { build } from 'vite'
import { afterEach, describe, expect, it } from 'vitest'

type ManifestEntry = {
  file?: string
  imports?: string[]
  isEntry?: boolean
}

const outDirs: string[] = []

function modulePreloads(html: string): string[] {
  return [...html.matchAll(/<link[^>]+rel=["']modulepreload["'][^>]+href=["']([^"']+)["'][^>]*>/gi)]
    .flatMap(match => match[1] ? [match[1]] : [])
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
    expect((entry?.imports ?? []).filter(id => id.startsWith('_vendor-'))).toHaveLength(1)
    expect((entry?.imports ?? []).some(id => id.includes('mermaid'))).toBe(false)

    const preloads = modulePreloads(html)
    expect(preloads).toHaveLength(1)
    expect(preloads[0]).toMatch(/\/assets\/vendor-[^/]+\.js$/)
    expect(preloads.some(href => href.includes('mermaid'))).toBe(false)
  }, 120_000)
})
