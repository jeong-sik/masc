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

  // A face declares a weight and points at a file. The browser trusts the
  // declaration: asked for 600 it answers "there is a 600 face" and draws
  // whatever outlines that file holds. So two weights pointing at the same
  // bytes is a face that lies, and the CSS text cannot show it -- the two
  // urls differ, only the files behind them do not.
  //
  // Four such runs are here today: EBGaramond 400=600 in both subsets, and
  // JetBrainsMono 400=500=700 in both. Eight files, four distinct blobs,
  // five declared weights. They are listed rather than failed because the
  // repository holds no true 600 or 700 to swap in, and dropping the faces
  // moves the text onto synthetic bold -- a look, not a bug fix. #33209
  // carries the serif and now the mono.
  it('gives each declared weight its own outlines', () => {
    const known = new Set([
      'EBGaramond-400-latin.woff2=EBGaramond-600-latin.woff2', // #33209
      'EBGaramond-400-latinext.woff2=EBGaramond-600-latinext.woff2', // #33209
      // #33209 counted the serif. The mono is worse: three weights, one file,
      // in both subsets. Every weight of the code font draws the same
      // outlines, so bold code is regular code.
      'JetBrainsMono-400-latin.woff2=JetBrainsMono-500-latin.woff2=JetBrainsMono-700-latin.woff2',
      'JetBrainsMono-400-latinext.woff2=JetBrainsMono-500-latinext.woff2=JetBrainsMono-700-latinext.woff2',
    ])
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
