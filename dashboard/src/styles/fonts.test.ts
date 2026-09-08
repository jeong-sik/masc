import { describe, expect, it } from 'vitest'
import { createHash } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'

const __filename = fileURLToPath(import.meta.url)
const __dirname = dirname(__filename)

describe('keeper-v2 brand assets', () => {
  const css = readFileSync(resolve(__dirname, 'fonts.css'), 'utf8')

  it('declares the Cinzel font family', () => {
    expect(css).toContain("font-family: 'Cinzel'")
    expect(css).toContain("url('/dashboard/assets/fonts/Cinzel-Regular.ttf')")
  })

  it('declares the serif and mono faces the skin names first in its stacks', () => {
    // --font-body leads with EB Garamond, --font-mono with JetBrains Mono.
    // Without these the dashboard renders Georgia/Menlo fallbacks while the
    // prototype renders the real faces (see docs/DESIGN-PARITY.md).
    for (const face of ['EB Garamond', 'JetBrains Mono']) {
      expect(css).toContain(`font-family: '${face}'`)
    }
    // Every latin subset entry must point at a vendored file, not a CDN.
    expect(css).not.toMatch(/url\((?!'\/dashboard)/)
  })

  // The EB Garamond and JetBrains Mono upright files are variable fonts (an
  // fvar table; one file per subset carries the whole weight axis), so the
  // face is declared once with a weight range and the browser draws 600 from
  // the same bytes it draws 400 from. #33209 read the identical 400/600 and
  // 400/500/700 files as faces that lie; the lie was the single-weight
  // descriptor repeated over one file, which this file no longer does.
  it('declares each upright variable face once, with its weight range', () => {
    const faces = [...css.matchAll(/@font-face\s*\{([^}]*)\}/g)]
      .map(m => m[1])
      .filter((body): body is string => body !== undefined)
    const upright = faces.filter(
      face => /font-style:\s*normal/.test(face) && /font-family:\s*'(EB Garamond|JetBrains Mono)'/.test(face),
    )
    expect(upright).toHaveLength(4)
    for (const face of upright) {
      expect(face).toMatch(/font-weight:\s*[1-9]00\s+[1-9]00;/)
    }
  })

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

describe('keeper-v2 Korean face', () => {
  const css = readFileSync(resolve(__dirname, 'fonts-noto-sans-kr.css'), 'utf8')

  it('declares Noto Sans KR as split local woff2 slices', () => {
    expect(css).toContain("font-family: 'Noto Sans KR'")
    expect(css).toContain("url('/dashboard/assets/fonts/NotoSansKR-")
    expect(css).not.toContain('fonts.gstatic.com')
  })

  it('declares the AC00 syllable block so visible Korean text resolves locally', () => {
    // The Hangul syllables range starts at U+AC00; a slice must claim it or
    // every Korean label falls through to the system stack.
    expect(css).toMatch(/U\+ac00/)
  })
})
