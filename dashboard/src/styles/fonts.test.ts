import { describe, expect, it } from 'vitest'
import { createHash } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'

const __filename = fileURLToPath(import.meta.url)
const __dirname = dirname(__filename)

describe('keeper-v2 brand assets', () => {
  const css = readFileSync(resolve(__dirname, 'fonts.css'), 'utf8')

  // Two faces of different weights pointing at the same bytes would be a face
  // that lies: the browser trusts the declaration and draws whatever the file
  // holds. With the ranged declarations above no such pair may remain.
  it('gives each declared weight its own outlines', () => {
    const known = new Set<string>()
    const faces = [...css.matchAll(/@font-face\s*\{([^}]*)\}/g)]
      .map(m => m[1])
      .filter((body): body is string => body !== undefined)
    const byFile = new Map<string, { file: string; weight: string; family: string }[]>()
    for (const face of faces) {
      const href = /url\('([^']*\/([^'/]+))'\)/.exec(face)?.slice(1)
      const weight = /font-weight:\s*([^;]+);/.exec(face)?.[1]
      const family = /font-family:\s*'([^']+)'/.exec(face)?.[1]
      const [src, file] = href ?? []
      if (!src || !file || !weight || !family) continue
      const path = resolve(__dirname, '../../public', src.replace('/dashboard/', ''))
      const digest = createHash('sha256').update(readFileSync(path)).digest('hex')
      const seen = byFile.get(digest) ?? []
      seen.push({ file, weight: weight.trim(), family })
      byFile.set(digest, seen)
    }
    const shared: string[] = []
    for (const faces of byFile.values()) {
      const weights = new Set(faces.map(f => `${f.family}/${f.weight}`))
      if (faces.length > 1 && weights.size > 1) {
        const key = faces.map(f => f.file).sort().join('=')
        if (!known.has(key)) shared.push(key)
      }
    }
    expect(shared).toEqual([])
  })
})
